// v0.4.7 §user — engine resolution on the Android connect path.
//
// Device evidence (2026-09-17, CDN-UK node): a vless+ws+TLS link carrying
// `encryption=mlkem768x25519plus…` (post-quantum VLESS) was imported with
// core=unknown; only the DESKTOP ConnectionController ran CoreDetector —
// and on its own in-memory copy. The Android VpnSession never resolved the
// engine, so every gate (androidExclusionReason, the front config builder,
// the xhttp/mKCP upstream gate) saw `unknown` and the node was served as a
// NATIVE sing-box outbound. sing-box 1.14 has no `encryption` outbound
// field: it silently negotiated encryption 'none', the server rejected the
// handshake, and every probe died with `outbound/vless[…]: EOF` — exactly
// the reported "CDN nodes won't connect" signature.
//
// Contract: VpnSession._connectProfile resolves the engine via
// [CoreDetector.resolve] BEFORE any gate runs, and the resolution is
// visible to the whole connect path (post-quantum VLESS → CoreKind.xray,
// matching the detector's engine-capability matrix).
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/android_node_support.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/engine_availability.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';

ProxyProfile _cdnMlkemNode() => ProxyProfile(
      id: 'cdn-uk',
      name: 'CDN-UK',
      server: 'medium.com',
      port: 2087,
      protocol: ProxyProtocol.vless,
      transport: Transport.ws,
      security: Security.tls,
      uuid: 'f819b00b-1799-45de-af58-c657a1b7f187',
      // exactly what the parser extracts from the user's link
      encryption: 'mlkem768x25519plus.native.0rtt.6YuJzseSjwtf58A9',
      host: 'cdnuk.hixyz.ir',
      sni: 'cdnuk.hixyz.ir',
      path: '/?ed=2560',
      alpn: const ['h2', 'http/1.1', 'h3'],
      fingerprint: 'chrome',
      rawParams: {
        'type': 'ws',
        'security': 'tls',
        'encryption': 'mlkem768x25519plus.native.0rtt.6YuJzseSjwtf58A9',
      },
      // what a subscription import persists (profile_codec writes core.name)
      core: CoreKind.unknown,
    );

void main() {
  final detector = CoreDetector();
  group('Engine resolution (v0.4.7 §user)', () {
    test('post-quantum VLESS node resolves to the Xray core', () {
      final p = _cdnMlkemNode();
      expect(p.effectiveCore, CoreKind.unknown,
          reason: 'imports persist core=unknown');
      final decision = detector.resolve(p);
      expect(decision.core, CoreKind.xray,
          reason: 'sing-box 1.14 cannot negotiate mlkem VLESS encryption');
    });

    test('after resolution the sing-box builder refuses the node natively',
        () {
      final p = _cdnMlkemNode();
      p.core = detector.resolve(p).core;
      // outbound_builders.singBoxOutbound returns null for Xray-owned
      // profiles → the generator falls through to the socksUpstreams map
      // (the :xray stub) instead of building a broken native outbound.
      expect(p.effectiveCore, CoreKind.xray);
    });

    test('AndroidNodeSupport gates a resolved Xray node on runtime state', () {
      final p = _cdnMlkemNode();
      p.core = detector.resolve(p).core;
      addTearDown(() => XrayCoreState.instance.setRuntimeLoaded(false));
      XrayCoreState.instance.setRuntimeLoaded(false);
      expect(AndroidNodeSupport.isRunnable(p), isFalse);
      XrayCoreState.instance.setRuntimeLoaded(true);
      expect(AndroidNodeSupport.isRunnable(p), isTrue);
      expect(AndroidNodeSupport.androidExclusionReason(p), isNull);
    });

    test('plain ws+TLS node (no PQ encryption) stays on sing-box', () {
      final p = ProxyProfile(
        id: 'plain-ws',
        name: 'plain',
        server: 's.example.com',
        port: 443,
        protocol: ProxyProtocol.vless,
        transport: Transport.ws,
        security: Security.tls,
        uuid: 'u',
        path: '/ws',
        core: CoreKind.unknown,
      );
      expect(detector.resolve(p).core, CoreKind.singbox);
    });
  });
}
