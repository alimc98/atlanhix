import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/configgen/outbound_builders.dart';
import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';
import 'package:nexus/warp/warp_registrar.dart';

/// v0.4.9 §user — WARP = AmneziaWG 3.1 wiring contract:
///  * the dial endpoint never leaks the WARP API's raw `host:0`,
///  * register() ships the LIVE-PROVEN Cloudflare set (jc/jmin/jmax +
///    masquerade id/ip/ib + random trailers) and never the handshake-
///    breaking s1/s2/h1..h4,
///  * masquerade sugar rides the wireguard endpoint as `id`/`ip`/`ib`,
///    with NO null-valued h-keys on the wire,
///  * warp-first: a WireGuard NODE dials THROUGH the warp endpoint, while
///    the loopback Xray SOCKS stub must never be wrapped in the tunnel.

WarpAccount _acct({
  String endpointV4 = '162.159.192.6:2408',
  String? endpointOverride,
  int? awgJc,
  int? awgJmin,
  int? awgJmax,
  String? masqId,
  String? masqIp,
  String? masqIb,
  bool? randomTrailers,
}) =>
    WarpAccount(
      deviceId: 'test-device',
      token: 'tok',
      privateKey: 'kJ3xXyQ7Wm9pR5tN2vB8sL4cH6dF1aG0eIuO9qZw8kA=',
      peerPublicKey: 'qF2FiW09KjRWd7pF5bEy9XU9pHc4uTMvE1S0aZnQVXM=',
      endpointV4: endpointV4,
      addressV4: '172.16.0.2/32',
      clientId: 'AQIDBAUGBw==',
      endpointOverride: endpointOverride,
      awgJc: awgJc,
      awgJmin: awgJmin,
      awgJmax: awgJmax,
      awgMasqId: masqId,
      awgMasqIp: masqIp,
      awgMasqIb: masqIb,
      awgRandomTrailers: randomTrailers,
    );

class _FakeWarpHttp implements WarpHttp {
  _FakeWarpHttp(this.response);
  final Map<String, dynamic> response;

  @override
  Future<Map<String, dynamic>> post(
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  }) async =>
      response;

  @override
  Future<Map<String, dynamic>> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async =>
      response;

  @override
  Future<Map<String, dynamic>> patch(
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  }) async =>
      response;
}

Map<String, dynamic> _registrationResponse() => {
      'id': 'device-1',
      'token': 'token-1',
      'license': 'lic-1',
      'config': {
        'peers': [
          {
            'public_key': 'qF2FiW09KjRWd7pF5bEy9XU9pHc4uTMvE1S0aZnQVXM=',
            'endpoint': {'v4': '162.159.192.6:0'},
          }
        ],
        'interface': {
          'addresses': {'v4': '172.16.0.2/32', 'v6': 'fd01:5ca1::1/128'},
        },
        'client_id': 'AQIDBAUGBw==',
      },
    };

void main() {
  group('WARP dial endpoint parsing (raw :0 never reaches the engine)', () {
    test('API "host:0" → host + WireGuard default port 2408', () {
      final a = _acct(endpointV4: '162.159.192.6:0');
      expect(a.dialHost, '162.159.192.6');
      expect(a.dialPort, 2408);
    });

    test('bare host keeps the default port; host:port is explicit', () {
      final bare = _acct(endpointV4: '162.159.193.10');
      expect(bare.dialHost, '162.159.193.10');
      expect(bare.dialPort, 2408);
      final withPort = _acct(endpointV4: '188.114.96.1:1701');
      expect(withPort.dialHost, '188.114.96.1');
      expect(withPort.dialPort, 1701);
    });

    test('bracketed IPv6 splits host and port correctly', () {
      final a = _acct(endpointV4: '[2606:4700:d0::a29f:c001]:500');
      expect(a.dialHost, '2606:4700:d0::a29f:c001');
      expect(a.dialPort, 500);
      final noPort = _acct(endpointV4: '[2606:4700:d0::1]');
      expect(noPort.dialHost, '2606:4700:d0::1');
      expect(noPort.dialPort, 2408);
    });

    test('naked IPv6 (several colons) is not mistaken for host:port', () {
      final a = _acct(endpointV4: '2606:4700:d0::1');
      expect(a.dialHost, '2606:4700:d0::1');
      expect(a.dialPort, 2408);
    });

    test('scanned endpointOverride wins over the API default', () {
      final a = _acct(
          endpointV4: '162.159.192.6:2408', endpointOverride: '188.114.97.1:8443');
      expect(a.dialHost, '188.114.97.1');
      expect(a.dialPort, 8443);
    });

    test('zero, garbage and out-of-range ports fall back to 2408', () {
      expect(_acct(endpointV4: 'h.example:0').dialPort, 2408);
      expect(_acct(endpointV4: 'h.example:abc').dialPort, 2408);
      expect(_acct(endpointV4: 'h.example:70000').dialPort, 2408);
    });

    test('materialized profile carries the parsed host/port', () {
      final p = WarpRegistrar.profileFor(_acct(endpointV4: '162.159.192.6:0'));
      expect(p.wireguard!.endpointHost, '162.159.192.6');
      expect(p.wireguard!.endpointPort, 2408);
      expect(p.port, 2408);
      expect(p.tags, contains('warp'));
    });
  });

  group('WARP registers as AmneziaWG 3.1 by default', () {
    test('register() applies the live-proven Cloudflare set', () async {
      final acct = await WarpRegistrar(http: _FakeWarpHttp(_registrationResponse()))
          .register();
      expect(acct.hasAmneziaParams, isTrue);
      expect(acct.awgJc, 4);
      expect(acct.awgJmin, 64);
      expect(acct.awgJmax, 96);
      expect(acct.awgMasqId, 'www.google.com');
      expect(acct.awgMasqIp, 'quic');
      expect(acct.awgMasqIb, 'chrome');
      expect(acct.awgRandomTrailers, true);
      // The handshake-reshaping set that Cloudflare's vanilla parser drops
      // must stay OFF — live-proven to break the WARP handshake.
      expect(acct.awgS1, isNull);
      expect(acct.awgS2, isNull);
      expect(acct.awgH1, isNull);
      expect(acct.awgDisableCookies, isNull);
      // The API's `:0` endpoint never reaches the engine.
      expect(acct.dialHost, '162.159.192.6');
      expect(acct.dialPort, 2408);
      // Materialized profile is tagged and carries the set on the wire.
      final p = WarpRegistrar.profileFor(acct);
      expect(p.tags, contains('awg-3.1'));
      expect(p.amnezia!.jc, 4);
      expect(p.amnezia!.masqId, 'www.google.com');
    });
  });

  group('masquerade sugar (id/ip/ib) rides the wireguard endpoint', () {
    final builders = OutboundBuilders();

    test('emitted when set; h/s keys omitted (no nulls on the wire)', () {
      final ep = builders.singBoxWireguardEndpoint(
        WarpRegistrar.profileFor(_acct(
          awgJc: 4,
          awgJmin: 64,
          awgJmax: 96,
          masqId: 'www.google.com',
          masqIp: 'quic',
          masqIb: 'chrome',
          randomTrailers: true,
        )),
        tag: 'warp',
      );
      expect(ep, isNotNull);
      expect(ep!['jc'], 4);
      expect(ep['jmin'], 64);
      expect(ep['jmax'], 96);
      expect(ep['id'], 'www.google.com');
      expect(ep['ip'], 'quic');
      expect(ep['ib'], 'chrome');
      expect(ep['random_trailers'], true);
      // No unset-key nulls: sing-box would accept them but the config must
      // stay minimal and readable.
      expect(ep.containsKey('h1'), isFalse);
      expect(ep.containsKey('h2'), isFalse);
      expect(ep.containsKey('s1'), isFalse);
      expect(ep.containsKey('i1'), isFalse);
    });

    test('plain account emits NO awg/masquerade fields', () {
      final ep = builders.singBoxWireguardEndpoint(
        WarpRegistrar.profileFor(_acct()),
        tag: 'warp',
      );
      expect(ep, isNotNull);
      for (final k in ['jc', 'jmin', 'jmax', 'id', 'ip', 'ib', 'h1', 'random_trailers']) {
        expect(ep!.containsKey(k), isFalse, reason: 'unexpected key $k');
      }
    });

    test('set h-keys still emit (int-or-range header values)', () {
      final p = WarpRegistrar.profileFor(_acct(awgJc: 4));
      final withH = ProxyProfile(
        id: p.id,
        name: p.name,
        server: p.server,
        port: p.port,
        protocol: p.protocol,
        wireguard: p.wireguard,
        amnezia: AmneziaParams(jc: 4, h1: '123456', h3: '1000-2000'),
      );
      final ep = builders.singBoxWireguardEndpoint(withH, tag: 'warp');
      expect(ep!['h1'], 123456);
      expect(ep['h3'], '1000-2000');
      expect(ep.containsKey('h2'), isFalse);
    });
  });

  group('warp-first chain shapes (v0.4.9 §user-fix)', () {
    final gen = SingBoxConfigGenerator();
    final routing = BuiltinRoutingProfiles.all().first;
    final dns = DnsSettings(mode: DnsMode.automatic);

    ProxyProfile wgNode() => ProxyProfile(
          id: 'wgnode',
          name: 'wg',
          server: '5.6.7.8',
          port: 2408,
          protocol: ProxyProtocol.wireguard,
          wireguard: WireGuardConfig(
            privateKey: 'priv=',
            peerPublicKey: 'peer=',
            endpointHost: '5.6.7.8',
            endpointPort: 2408,
          ),
        );

    test('WireGuard NODE dials through the warp endpoint', () {
      final cfg = gen.generate(
        runnableProfiles: [wgNode()],
        routing: routing,
        dns: dns,
        selectedTag: 'node:wgnode',
        warpProfile: WarpRegistrar.profileFor(_acct()),
        chainWarpOutside: true,
      );
      final endpoints = (cfg['endpoints'] as List).cast<Map<dynamic, dynamic>>();
      final nodeEp =
          endpoints.firstWhere((e) => e['tag'] == 'node:wgnode');
      expect(nodeEp['detour'], 'warp',
          reason: 'a WG NODE previously dialed straight out — warp-first '
              'was a silent no-op for it');
      // The warp endpoint itself dials DIRECT in warp-first.
      final warpEp = endpoints.firstWhere((e) => e['tag'] == 'warp');
      expect(warpEp.containsKey('detour'), isFalse);
    });

    test('loopback Xray SOCKS stub is never wrapped in the tunnel', () {
      final xrayNode = ProxyProfile(
        id: 'xnode',
        name: 'xhttp',
        server: 'cdn.example.com',
        port: 443,
        protocol: ProxyProtocol.vless,
        transport: Transport.xhttp,
        security: Security.reality,
        uuid: 'u1',
        realityPublicKey: 'pk',
      );
      final cfg = gen.generate(
        runnableProfiles: [xrayNode],
        routing: routing,
        dns: dns,
        selectedTag: 'node:xnode',
        socksUpstreams: {
          'xnode': (host: '127.0.0.1', port: 12345),
        },
        warpProfile: WarpRegistrar.profileFor(_acct()),
        chainWarpOutside: true,
      );
      final outs = (cfg['outbounds'] as List).cast<Map<dynamic, dynamic>>();
      // v0.4.9 §connect-fix: WITH a live upstream port the stub IS emitted
      // (the connect path's real :xray child) — but it stays DIRECT: the
      // child dials the node on its own protected path, and `detour: warp`
      // wrapped loopback dials in the WARP tunnel where 127.0.0.1 is
      // unroutable (every warp-first Xray connect died). A stub-less probe
      // config (no map entry) still drops the node honestly.
      final stub = outs.firstWhere((o) => o['tag'] == 'node:xnode');
      expect(stub['type'], 'socks');
      expect(stub.containsKey('detour'), isFalse,
          reason: 'loopback stub must never ride the WARP tunnel');
    });
  });
}
