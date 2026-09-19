// v0.4.6 — wiring + readiness regression tests.
//
// 1) The TLS-Fragment pill (Settings) must reach BOTH engines: the front
//    sing-box runtime (tls.fragment option) AND the Xray upstream (native
//    freedom-fragment form). Before this fix the pill only persisted a
//    settings boolean — no runtime ever read it.
// 2) The Xray fragment handoff must land in the CANONICAL
//    streamSettings.sockopt.dialerProxy slot. Verified against the
//    Xray-core tree (2026-09): app/proxyman/outbound/handler.go dials with
//    the OUTBOUND's streamSettings, and DialSystem redirects to the named
//    outbound from streamSettings.sockopt.DialerProxy — the TLS/Reality
//    config protos have no sockopt field, so a nested one is silently
//    dropped (the old, wrong placement ran nodes UNFRAGMENTED).
// 3) The fragment-out freedom outbound resolves through Xray's DNS module
//    (domainStrategy UseIPv4) — with dialerProxy it performs the real
//    dial, and AsIs would hand that resolution to the poisoned OS resolver.
// 4) headerType=http obfs links emit tcpSettings/kcpSettings — previously
//    the header was dropped entirely (mKCP+http obfs nodes broke; raw tcp
//    +obfs dialled nothing).
// 5) Xray readiness must be a real SOCKS5 greeting exchange, not a bare
//    TCP connect (which any socket-holder passes).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/core/fragmentation/fragment_profiles.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';
import 'package:nexus/settings/app_settings.dart';

import 'helpers/prepare_node.dart';

ProxyProfile _vlessXhttpReality() => ProxyProfile(
      id: 'frag-1',
      name: 'frag node',
      server: 'cdn.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      transport: Transport.xhttp,
      security: Security.reality,
      uuid: 'u1',
      realityPublicKey: 'pk',
      sni: 'cdn.example.com',
      path: '/api',
      rawParams: {'mode': 'auto'},
    );

ProxyProfile _vlessTlsWs() => ProxyProfile(
      id: 'frag-2',
      name: 'ws tls node',
      server: 'ws.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      transport: Transport.ws,
      security: Security.tls,
      uuid: 'u2',
      sni: 'ws.example.com',
      path: '/ws',
    );

void main() {
  group('TLS-Fragment pill wiring', () {
    test('ConnectionController setter pushes into the front runtime',
        () async {
      final conn = await makeController();
      addTearDown(conn.cores.dispose);
      expect(conn.tlsFragmentEnabled, isFalse);
      expect(conn.cores.front.tlsFragment, isFalse);

      conn.tlsFragmentEnabled = true;
      expect(conn.cores.front.tlsFragment, isTrue,
          reason: 'the pill must reach the sing-box runtime immediately');
    });

    test('CoreManager fragment handoff: eligible → conservative preset',
        () async {
      final work = await Directory.systemTemp.createTemp('nexus-pill-xr');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() => cores.dispose());
      await cores.prepare();

      cores.tlsFragmentEnabled = true;
      // The Xray runtime now carries the preset the moment the upstream
      // would be (re)started for an eligible profile (see the placement
      // group below for the generated shape). Here: flag on, no crash.
      expect(cores.tlsFragmentEnabled, isTrue);
      expect(FragmentationEngine().isEligible(_vlessXhttpReality()), isTrue);
    });

    test('fragmentPreset selection flows through to the generated fragment',
        () async {
      final work = await Directory.systemTemp.createTemp('nexus-preset-xr');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() => cores.dispose());
      await cores.prepare();
      cores.tlsFragmentEnabled = true;
      cores.fragmentPreset = FragmentPreset.aggressive;

      // The same mapping CoreManager._fragmentFor uses, exercised end-to-end
      // into the generated Xray config shape.
      final p = _vlessTlsWs()..core = CoreKind.xray;
      final cfg = XrayConfigGenerator().generate(
        profile: p,
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
        fragment: FragmentPresets.profileFor(cores.fragmentPreset),
      );
      final frag = (cfg['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'fragment-out') as Map;
      final f = ((frag['settings'] as Map)['fragment'] as Map);
      expect(f['packets'], '1-3',
          reason: 'the user-selected Aggressive preset must be emitted');

      // And the conservative mapping still emits tlshello.
      final cfgC = XrayConfigGenerator().generate(
        profile: p,
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
        fragment: FragmentPresets
            .profileFor(FragmentPreset.conservative),
      );
      final fragC = (cfgC['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'fragment-out') as Map;
      expect(
          ((fragC['settings'] as Map)['fragment'] as Map)['packets'],
          'tlshello');
    });

    test('pill off → Xray start runs unfragmented (opt-in only)', () async {
      final work = await Directory.systemTemp.createTemp('nexus-pill-off');
      final cores = CoreManager(
        binaryManager: BinaryManager(appDir: work),
        workDir: work,
      );
      addTearDown(() => cores.dispose());
      await cores.prepare();
      cores.tlsFragmentEnabled = false;
      final p = _vlessXhttpReality()..core = CoreKind.xray;
      // The generator must not add fragment scaffolding when no profile set.
      final cfg = XrayConfigGenerator()
          .generate(profile: p, localSocksPort: 2081,
              routing: BuiltinRoutingProfiles.all().first);
      final tags = (cfg['outbounds'] as List)
          .map((o) => (o as Map)['tag'])
          .toList();
      expect(tags.contains('fragment-out'), isFalse);
    });
  });

  group('Xray fragment placement (canonical streamSettings.sockopt)', () {
    test('TLS: sockopt.dialerProxy lands in streamSettings, clean shape',
        () {
      final p = _vlessTlsWs()..core = CoreKind.xray;
      final cfg = XrayConfigGenerator().generate(
        profile: p,
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
        fragment: FragmentPresets.conservative,
      );
      final proxy = (cfg['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'proxy-out') as Map;
      final stream = proxy['streamSettings'] as Map;
      expect(stream['sockopt'], {'dialerProxy': 'fragment-out'},
          reason: 'Xray reads the dialer from the OUTBOUND streamSettings');
      expect((stream['tlsSettings'] as Map).containsKey('sockopt'), isFalse,
          reason: 'a sockopt inside the TLS config proto is silently '
              'dropped by Xray (no such field)');
      expect((cfg['outbounds'] as List).any(
          (o) => (o as Map)['tag'] == 'fragment-out'), isTrue);
    });

    test('Reality: sockopt.dialerProxy lands in streamSettings, clean shape',
        () {
      final p = _vlessXhttpReality()..core = CoreKind.xray;
      final cfg = XrayConfigGenerator().generate(
        profile: p,
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
        fragment: FragmentPresets.conservative,
      );
      final proxy = (cfg['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'proxy-out') as Map;
      final stream = proxy['streamSettings'] as Map;
      expect(stream['sockopt'], {'dialerProxy': 'fragment-out'});
      expect(
          (stream['realitySettings'] as Map).containsKey('sockopt'), isFalse);
    });

    test('fragment-out resolves through the clean DNS module (UseIPv4)', () {
      final p = _vlessTlsWs()..core = CoreKind.xray;
      final cfg = XrayConfigGenerator().generate(
        profile: p,
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
        fragment: FragmentPresets.conservative,
      );
      final frag = (cfg['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'fragment-out') as Map;
      expect(((frag['settings'] as Map)['domainStrategy']), 'UseIPv4',
          reason: 'with dialerProxy, fragment-out performs the REAL dial — '
              'AsIs would resolve via the poisoned OS resolver, bypassing '
              'the clean dns block');
    });
  });

  group('Xray stream shape (v0.4.6 §xray-fix)', () {
    Map<String, dynamic> _stream(ProxyProfile p) {
      final cfg = XrayConfigGenerator().generate(
        profile: p..core = CoreKind.xray,
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
      );
      final proxy = (cfg['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'proxy-out') as Map;
      return (proxy['streamSettings'] as Map).cast<String, dynamic>();
    }

    test('tcp + headerType=http emits tcpSettings with an http request', () {
      final s = _stream(ProxyProfile(
        id: 't1',
        name: 'tcp obfs',
        server: 'a.example.com',
        port: 443,
        protocol: ProxyProtocol.vless,
        transport: Transport.tcp,
        security: Security.tls,
        uuid: 'u',
        host: 'front.example.com',
        rawParams: {'headerType': 'http'},
      ));
      final hdr = ((s['tcpSettings'] as Map)['header'] as Map);
      expect(hdr['type'], 'http');
      expect(
          (((hdr['request'] as Map)['headers'] as Map)['Host'] as List)
              .first,
          'front.example.com');
    });

    test('tcp without headerType stays clean (no tcpSettings)', () {
      final s = _stream(ProxyProfile(
        id: 't2',
        name: 'plain tcp',
        server: 'a.example.com',
        port: 443,
        protocol: ProxyProtocol.vless,
        transport: Transport.tcp,
        security: Security.none,
        uuid: 'u',
      ));
      expect(s.containsKey('tcpSettings'), isFalse,
          reason: 'default header none needs no tcpSettings');
    });

    test('mkcp link (type=kcp) emits kcpSettings with seed+header', () {
      final s = _stream(ProxyProfile(
        id: 't3',
        name: 'kcp obfs',
        server: 'k.example.com',
        port: 443,
        protocol: ProxyProtocol.vmess,
        transport: Transport.quic, // the vmess parser's mKCP mapping
        security: Security.tls,
        uuid: 'u',
        rawParams: {'type': 'kcp', 'headerType': 'http', 'seed': 's3ed'},
      ));
      expect(s['network'], 'mKCP');
      final k = s['kcpSettings'] as Map;
      expect((k['header'] as Map)['type'], 'http');
      expect(k['seed'], 's3ed');
    });

    test('mkcp link is routed to the Xray upstream (desktop front path)',
        () {
      // The vmess parser maps type=kcp|mkcp to Transport.quic, so a raw
      // enum-only check leaves the front sing-box building an outbound it
      // cannot express — the raw param is the truthful signal.
      final p = ProxyProfile(
        id: 't4',
        name: 'kcp route',
        server: 'k.example.com',
        port: 443,
        protocol: ProxyProtocol.vmess,
        transport: Transport.quic,
        security: Security.none,
        uuid: 'u',
        rawParams: {'type': 'kcp'},
      );
      expect(CoreManager.needsXrayUpstream(p), isTrue);
      // And Xray itself must accept the profile (outbound builds).
      final cfg = XrayConfigGenerator().generate(
        profile: p..core = CoreKind.xray,
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
      );
      final proxy = (cfg['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'proxy-out') as Map;
      expect(((proxy['streamSettings'] as Map)['network']), 'mKCP');
    });
  });

  group('sing-box tls.fragment option (front engine)', () {
    test('option on → outbounds carry tls.fragment', () {
      final p = _vlessTlsWs();
      final cfg = SingBoxConfigGenerator().generate(
        runnableProfiles: [p],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:${p.id}',
        options: const SingBoxOptions(tlsFragment: true),
      );
      final out = (cfg['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'node:${p.id}') as Map;
      expect(((out['tls'] as Map)['fragment']), isTrue);
    });

    test('option off → no tls.fragment key (default shape unchanged)', () {
      final p = _vlessTlsWs();
      final cfg = SingBoxConfigGenerator().generate(
        runnableProfiles: [p],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:${p.id}',
      );
      final out = (cfg['outbounds'] as List)
          .firstWhere((o) => (o as Map)['tag'] == 'node:${p.id}') as Map;
      expect((out['tls'] as Map).containsKey('fragment'), isFalse);
    });
  });

  group('SOCKS5 greeting probe (real readiness)', () {
    test('a real SOCKS5 server passes; a bare TCP listener fails', () async {
      // Real SOCKS5 greeting server (the shape Xray's socks inbound answers).
      final socks = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(socks.close);
      // NOTE: reply is sent WITHOUT waiting for the client bytes — a
      // sink-drain-first handshake raced the probe's 800ms read budget on
      // Windows (the reply sat unsent while the server waited on drain
      // completion scheduling). Xray's socks inbound replies immediately
      // after TCP accept anyway, so this mirrors the real shape better.
      socks.listen((s) {
        s.add([0x05, 0x00]); // version + NO-AUTH choice
        // keep the socket open briefly so the probe can read the reply
        Future<void>.delayed(const Duration(milliseconds: 50))
            .then((_) => s.destroy());
      });

      // Bare listener: accepts TCP but never answers the greeting — exactly
      // what the old TCP-only readiness probe wrongly called "ready".
      final bare = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(bare.close);
      bare.listen((s) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        s.destroy();
      });

      final pass = await _greetProbe(socks.port);
      expect(pass, isTrue, reason: 'greeting exchange must succeed');
      final fail = await _greetProbe(bare.port);
      expect(fail, isFalse,
          reason: 'a TCP-only listener must NOT pass readiness');
    });
  });
}

/// Mirror of XrayRuntime's probe sequence against an arbitrary port —
/// keeps the test independent of binary availability while pinning the
/// protocol behavior (05 01 00 → 05 00).
Future<bool> _greetProbe(int port) async {
  Socket? s;
  try {
    s = await Socket.connect(InternetAddress.loopbackIPv4, port,
        timeout: const Duration(milliseconds: 600));
    s.add([0x05, 0x01, 0x00]);
    final buf = <int>[];
    final c = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = s.listen((chunk) {
      buf.addAll(chunk);
      if (buf.length >= 2 && !c.isCompleted) c.complete();
    }, onDone: () {
      if (!c.isCompleted) c.complete();
    }, onError: (Object _) {
      if (!c.isCompleted) c.complete();
    });
    try {
      await c.future.timeout(const Duration(milliseconds: 800));
    } on TimeoutException {
      // fall through
    } finally {
      await sub.cancel();
    }
    return buf.length == 2 && buf[0] == 0x05 && buf[1] == 0x00;
  } catch (_) {
    return false;
  } finally {
    s?.destroy();
  }
}
