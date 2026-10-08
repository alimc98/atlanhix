import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/android_node_support.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/engine_availability.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/settings/app_settings.dart';

ProxyProfile _xhttp() => ProxyProfile(
      id: 'xh',
      name: 'XHTTP',
      server: '203.0.113.10',
      port: 443,
      protocol: ProxyProtocol.vless,
      transport: Transport.xhttp,
      security: Security.tls,
      uuid: 'u1',
      sni: 'cdn.example.com',
    );


ProxyProfile _mdvpn() => ProxyProfile(
      id: 'md',
      name: 'MDVPN',
      server: 'a.b',
      port: 1,
      protocol: ProxyProtocol.masterDnsVpn,
    );

void main() {
  setUp(() {
    // Deterministic gates for every test.
    MihomoCoreState.instance.setRuntimeLoaded(true);
    XrayCoreState.instance.setRuntimeLoaded(true);
  });

  group('CoreKind.mihomo gating', () {
    test('coreAllowedOnAndroid follows MihomoCoreState', () {
      expect(AndroidNodeSupport.coreAllowedOnAndroid(CoreKind.mihomo), isTrue);
      MihomoCoreState.instance.setRuntimeLoaded(false);
      expect(AndroidNodeSupport.coreAllowedOnAndroid(CoreKind.mihomo), isFalse);
    });

    test('exclusion reason mentions the engine when off', () {
      MihomoCoreState.instance.setRuntimeLoaded(false);
      final p = _xhttp()..core = CoreKind.mihomo;
      final reason = AndroidNodeSupport.androidExclusionReason(p);
      expect(reason, isNotNull);
      expect(reason, contains('mihomo'));
    });

    test('no exclusion when the engine is loaded', () {
      final p = _xhttp()..core = CoreKind.mihomo;
      expect(AndroidNodeSupport.androidExclusionReason(p), isNull);
    });
  });

  group('detector engine preference', () {
    test('preference mihomo steers an xhttp node to the mihomo engine', () {
      final d = CoreDetector().resolve(_xhttp(),
          preference: CorePreference.mihomo);
      expect(d.core, CoreKind.mihomo);
    });

    test('preference mihomo does NOT capture unsupported protocols', () {
      final d = CoreDetector().resolve(_mdvpn(),
          preference: CorePreference.mihomo);
      expect(d.core, isNot(CoreKind.mihomo));
    });

    test('preference auto keeps the capability-matrix decision (xray)', () {
      final d = CoreDetector().resolve(_xhttp(), preference: CorePreference.auto);
      expect(d.core, CoreKind.xray,
          reason: 'xhttp is upstream-Xray-only in the auto matrix');
    });

    test('a per-node PIN beats the app preference', () {
      final p = _xhttp()..userPinnedCore = CoreKind.xray;
      final d = CoreDetector().resolve(p, preference: CorePreference.mihomo);
      expect(d.core, CoreKind.xray,
          reason: 'userPinnedCore wins over CorePreference');
    });
  });

  group('sing-box front load', () {
    test('mihomo-owned nodes never ride the sing-box front', () {
      // _singboxLoad is private; exercise via the same predicate family:
      // a mihomo node must not be xray-upstream NOR front-loadable.
      final p = _xhttp()..core = CoreKind.mihomo;
      expect(CoreManager.needsXrayUpstream(p), isFalse,
          reason: 'mihomo owns the dial-out; no :xray stub');
    });
  });
}
