import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/android_node_support.dart';
import 'package:nexus/core/engine_availability.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';

ProxyProfile _vless({Transport transport = Transport.ws, CoreKind? pin}) =>
    ProxyProfile(
      id: 'p1',
      name: 'T',
      protocol: ProxyProtocol.vless,
      server: 'h.example',
      port: 443,
      uuid: 'b1a2798c-6d0a-44dd-9d7f-f8a59e6d7f83',
      transport: transport,
      security: Security.tls,
      userPinnedCore: pin,
    );

void main() {
  tearDown(() => XrayCoreState.instance.setRuntimeLoaded(false));

  group('Xray runtime toggles runnability (v0.4.3)', () {
    test('xhttp node: OFF → not runnable, honest reason', () {
      XrayCoreState.instance.setRuntimeLoaded(false);
      final p = _vless(transport: Transport.xhttp);
      expect(AndroidNodeSupport.isRunnable(p), isFalse);
      expect(AndroidNodeSupport.notRunnableReason(p), contains('Xray'));
      expect(AndroidNodeSupport.shortBadge(p), contains('Xray off'));
    });

    test('xhttp node: ON → runnable, badges say Xray', () {
      XrayCoreState.instance.setRuntimeLoaded(true);
      final p = _vless(transport: Transport.xhttp);
      expect(AndroidNodeSupport.isRunnable(p), isTrue);
      expect(AndroidNodeSupport.notRunnableReason(p), isNull);
      expect(AndroidNodeSupport.shortBadge(p), 'Xray');
      expect(AndroidNodeSupport.androidCoreLabel(p), contains('Xray'));
    });

    test('user-pinned Xray node follows runtime state too', () {
      final p = _vless(pin: CoreKind.xray);
      XrayCoreState.instance.setRuntimeLoaded(false);
      expect(AndroidNodeSupport.isRunnable(p), isFalse);
      XrayCoreState.instance.setRuntimeLoaded(true);
      expect(AndroidNodeSupport.isRunnable(p), isTrue);
      expect(AndroidNodeSupport.androidCoreLabel(p), contains('Xray'));
    });

    test('plain sing-box node unaffected by the toggle', () {
      final p = _vless();
      for (final on in [false, true]) {
        XrayCoreState.instance.setRuntimeLoaded(on);
        expect(AndroidNodeSupport.isRunnable(p), isTrue);
        expect(AndroidNodeSupport.shortBadge(p), 'sing-box');
      }
    });

    test('mkcp (rawParams type) counts as xray-only transport', () {
      final kcp = ProxyProfile(
        id: 'p2',
        name: 'K',
        protocol: ProxyProtocol.vless,
        server: 'h.example',
        port: 443,
        uuid: 'b1a2798c-6d0a-44dd-9d7f-f8a59e6d7f83',
        transport: Transport.none,
        security: Security.tls,
        rawParams: const {'type': 'mkcp'},
      );
      XrayCoreState.instance.setRuntimeLoaded(false);
      expect(AndroidNodeSupport.isRunnable(kcp), isFalse);
      XrayCoreState.instance.setRuntimeLoaded(true);
      expect(AndroidNodeSupport.isRunnable(kcp), isTrue);
    });

    test('AmneziaWG is gated on the FORKED engine self-report (v0.4.9)', () {
      final p = ProxyProfile(
        id: 'p3',
        name: 'A',
        protocol: ProxyProtocol.vless,
        server: 'h.example',
        port: 443,
        uuid: 'b1a2798c-6d0a-44dd-9d7f-f8a59e6d7f83',
        amnezia: AmneziaParams(
            jc: 1,
            jmin: 10,
            jmax: 20,
            s1: 1,
            s2: 2,
            h1: '3',
            h2: '4',
            h3: '5',
            h4: '6'),
      );
      addTearDown(() => AmneziaWgCoreState.instance.setRuntime(null));
      // Stock AAR (no `-lx.` marker) or unknown engine → honest lockout.
      AmneziaWgCoreState.instance.setRuntime('1.14.0');
      expect(AndroidNodeSupport.isRunnable(p), isFalse);
      expect(AndroidNodeSupport.shortBadge(p), contains('Amnezia'));
      expect(AndroidNodeSupport.coreAllowedOnAndroid(CoreKind.amneziaWg),
          isFalse);
      // Forked libbox (`with_awg`) self-report → the node runs in-engine.
      AmneziaWgCoreState.instance.setRuntime('v1.14.1-lx.8');
      expect(AndroidNodeSupport.isRunnable(p), isTrue);
      expect(AndroidNodeSupport.notRunnableReason(p), isNull);
      expect(AndroidNodeSupport.androidExclusionReason(p), isNull);
      expect(
          AndroidNodeSupport.coreAllowedOnAndroid(CoreKind.amneziaWg), isTrue);
    });

    test('plain WireGuard nodes (standalone WARP) run on libbox (v0.4.9)', () {
      final wg = ProxyProfile(
        id: 'wg1',
        name: 'WG',
        protocol: ProxyProtocol.wireguard,
        server: 'engage.cloudflareclient.com',
        port: 2408,
        core: CoreKind.wireguardSingbox,
        wireguard: WireGuardConfig(
          privateKey: 'k',
          peerPublicKey: 'pk',
          endpointHost: 'engage.cloudflareclient.com',
          endpointPort: 2408,
          addresses: const ['172.16.0.2/32'],
          mtu: 1280,
        ),
      );
      expect(AndroidNodeSupport.isRunnable(wg), isTrue);
      expect(AndroidNodeSupport.notRunnableReason(wg), isNull);
      expect(AndroidNodeSupport.coreAllowedOnAndroid(CoreKind.wireguardSingbox),
          isTrue);
    });
  });
}
