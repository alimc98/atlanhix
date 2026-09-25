import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/core/fragmentation/fragment_profiles.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

ProxyProfile _vlessXhttpReality() => ProxyProfile(
      id: '1',
      name: 'xhttp',
      server: 'cdn.example.com',
      port: 443,
      protocol: ProxyProtocol.vless,
      transport: Transport.xhttp,
      security: Security.reality,
      uuid: 'u1',
      flow: 'xtls-rprx-vision',
      realityPublicKey: 'pk',
      rawParams: {'mode': 'auto'},
    );

ProxyProfile _hysteria2() => ProxyProfile(
      id: '2',
      name: 'hy2',
      server: 'hy.example.com',
      port: 443,
      protocol: ProxyProtocol.hysteria2,
      security: Security.tls,
      password: 'pw',
    );

ProxyProfile _wgProfile({AmneziaParams? awg}) => ProxyProfile(
      id: '3',
      name: 'wg',
      server: '5.6.7.8',
      port: 51820,
      protocol: ProxyProtocol.wireguard,
      wireguard: WireGuardConfig(
        privateKey: 'priv=',
        peerPublicKey: 'peer=',
        endpointHost: '5.6.7.8',
        endpointPort: 51820,
      ),
      amnezia: awg,
    );

void main() {
  group('CoreDetector', () {
    final detector = CoreDetector();

    test('VLESS xhttp reality → xray with high confidence', () {
      final d = detector.detect(_vlessXhttpReality());
      expect(d.core, CoreKind.xray);
      expect(d.confidence, greaterThanOrEqualTo(0.9));
      expect(d.reasons, anyElement(contains('XHTTP')));
    });

    test('Hysteria2 → sing-box', () {
      final d = detector.detect(_hysteria2());
      expect(d.core, CoreKind.singbox);
      expect(d.confidence, greaterThanOrEqualTo(0.95));
    });

    test('AmneziaWG params → amneziawg engine', () {
      final p = _wgProfile(
        awg: AmneziaParams(jc: 4, jmin: 40, jmax: 70, s1: 86, s2: 142),
      );
      expect(detector.detect(p).core, CoreKind.amneziaWg);
    });

    test('plain WireGuard → sing-box endpoint', () {
      expect(detector.detect(_wgProfile()).core, CoreKind.wireguardSingbox);
    });

    test('user pin overrides detection', () {
      final p = _hysteria2()..userPinnedCore = CoreKind.singbox;
      final d = detector.resolve(p);
      expect(d.confidence, 1.0);
      expect(d.reasons, anyElement(contains('pinned')));
    });
  });

  group('sing-box config generator', () {
    final gen = SingBoxConfigGenerator();

    test('generates runnable client config with selector + mixed inbound',
        () {
      final cfg = gen.generate(
        runnableProfiles: [_hysteria2(), _vlessXhttpReality()],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:2',
        socksUpstreams: {'1': (host: '127.0.0.1', port: 2081)},
      );
      final outbounds = cfg['outbounds'] as List;
      final selector = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      expect(selector['type'], 'selector');
      // v0.4.9 §connect-fix: a LIVE upstream port (real :xray child) still
      // emits the socks stub — removing it unconditionally broke every
      // Xray-owned connect. Only the stub-less probe case drops the node.
      expect((selector['outbounds'] as List).length, 2);
      expect(
          (selector['outbounds'] as List).contains('node:1'), isTrue);
      final stub =
          outbounds.firstWhere((o) => o['tag'] == 'node:1') as Map;
      expect(stub['type'], 'socks');
      expect(stub['server_port'], 2081);
      final inbounds = cfg['inbounds'] as List;
      expect(inbounds.any((i) => i['type'] == 'mixed'), isTrue);
      final experimental = cfg['experimental'] as Map;
      expect((experimental['clash_api'] as Map)['external_controller'],
          contains('127.0.0.1'));
    });

    test('Xray node with NO upstream port is dropped (probe shape)', () {
      final cfg = gen.generate(
        runnableProfiles: [_hysteria2(), _vlessXhttpReality()],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:2',
      );
      final outbounds = cfg['outbounds'] as List;
      final selector = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      expect((selector['outbounds'] as List).length, 1);
      expect(
          (selector['outbounds'] as List).contains('node:1'), isFalse);
    });

    test('emits wireguard endpoint for wg profiles', () {
      final cfg = gen.generate(
        runnableProfiles: [_wgProfile()],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:3',
      );
      expect(cfg.containsKey('endpoints'), isTrue);
      final ep = (cfg['endpoints'] as List).first as Map;
      expect(ep['type'], 'wireguard');
      expect(((ep['peers'] as List).first as Map)['public_key'], 'peer=');
    });

    test('fakeip dns mode adds fakeip object', () {
      final cfg = gen.generate(
        runnableProfiles: const [],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.fakeip),
        selectedTag: '',
      );
      expect(((cfg['dns'] as Map)['fakeip'] as Map)['enabled'], isTrue);
    });
  });

  group('Xray config generator', () {
    final gen = XrayConfigGenerator();

    test('vless reality outbound with streamSettings', () {
      final cfg = gen.generate(
        profile: _vlessXhttpReality(),
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
      );
      final outbounds = cfg['outbounds'] as List;
      final proxy = outbounds.firstWhere((o) => o['tag'] == 'proxy-out') as Map;
      expect(proxy['protocol'], 'vless');
      final stream = proxy['streamSettings'] as Map;
      expect(stream['security'], 'reality');
      expect((stream['realitySettings'] as Map)['publicKey'], 'pk');
      final inbounds = cfg['inbounds'] as List;
      expect((inbounds.first as Map)['port'], 2081);
    });

    test('fragment injection only for eligible profiles', () {
      final p = _vlessXhttpReality()..transport = Transport.ws;
      final cfg = gen.generate(
        profile: p,
        localSocksPort: 2081,
        routing: BuiltinRoutingProfiles.all().first,
        fragment: FragmentPresets.conservative,
      );
      expect(
        (cfg['outbounds'] as List).any((o) => o['tag'] == 'fragment-out'),
        isTrue,
      );
    });

    test('fragmentation engine rejects sing-box and udp transports', () {
      final engine = FragmentationEngine();
      expect(engine.isEligible(_vlessXhttpReality()), isTrue);
      expect(engine.isEligible(_hysteria2()), isFalse);
      final quicNode = _vlessXhttpReality()..transport = Transport.quic;
      expect(engine.isEligible(quicNode), isFalse);
    });
  });
}

