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

    test('v0.6.5 §fix: preference mihomo FALLS BACK when the runtime is '
        'not loaded on this device', () {
      // The user report this pins: with Engine=mihomo on a device that has
      // no mihomo binary (Android), every connect died with binary-missing
      // while the same configs connected after changing the engine. The
      // detector must fall back to the capability decision instead.
      MihomoCoreState.instance.setRuntimeLoaded(false);
      // A trojan node: mihomo-runnable by protocol, but the capability
      // matrix alone picks sing-box.
      final p = ProxyProfile(
        id: 'trojan',
        name: 'Trojan',
        server: '203.0.113.20',
        port: 443,
        protocol: ProxyProtocol.trojan,
      );
      final d = CoreDetector().resolve(p, preference: CorePreference.mihomo);
      expect(d.core, isNot(CoreKind.mihomo),
          reason: 'unavailable engine must not capture the connect');
      expect(d.core, CoreKind.singbox,
          reason: 'fallback = capability-matrix decision');
      expect(d.reasons.join(' '), contains('not available on this device'),
          reason: 'the reason trail must say WHY the preference was ignored');
      // And the engine steering still works once the runtime IS loaded.
      MihomoCoreState.instance.setRuntimeLoaded(true);
      final d2 = CoreDetector().resolve(p, preference: CorePreference.mihomo);
      expect(d2.core, CoreKind.mihomo);
    });

    test('a per-node PIN beats the app preference', () {
      final p = _xhttp()..userPinnedCore = CoreKind.xray;
      final d = CoreDetector().resolve(p, preference: CorePreference.mihomo);
      expect(d.core, CoreKind.xray,
          reason: 'userPinnedCore wins over CorePreference');
    });
  });

  group('v0.6.7 §sub-engine: Clash-origin auto steering', () {
    test('a Clash-origin node steers to mihomo even with Engine=auto', () {
      // The user scenario: subscription content is Clash.Meta; the global
      // engine preference stays whatever it was — the CONTENT decides.
      final p = ProxyProfile(
        id: 'clash-node',
        name: 'Clash node',
        server: '203.0.113.30',
        port: 443,
        protocol: ProxyProtocol.vless,
        metadata: {'origin': 'clash'},
      );
      final d = CoreDetector().resolve(p, preference: CorePreference.auto);
      expect(d.core, CoreKind.mihomo,
          reason: 'Clash payload IS the format mihomo runs natively');
    });

    test('a Clash-origin node steers to mihomo even while the runtime '
        'probe is unset', () {
      // The exact report: «ساب کلش وصل میشه، ساب معمولی با انجین mihomo
      // نمیشه» — a plain sub + Engine=mihomo used to die on the binary gate.
      // The fix lets the CONTENT-proven Clash sub steer regardless.
      MihomoCoreState.instance.setRuntimeLoaded(false);
      final p = ProxyProfile(
        id: 'clash-node-2',
        name: 'Clash node 2',
        server: '203.0.113.31',
        port: 443,
        protocol: ProxyProtocol.trojan,
        metadata: {'origin': 'clash'},
      );
      final d = CoreDetector().resolve(p, preference: CorePreference.mihomo);
      expect(d.core, CoreKind.mihomo,
          reason: 'content-proven Clash node skips the probe gate');
    });

    test('a plain (non-Clash) sub node NEVER steers to mihomo on auto', () {
      // The other half of the report: plain subscription + Engine auto →
      // the capability matrix decides (no mihomo capture).
      final p = ProxyProfile(
        id: 'plain-node',
        name: 'Plain node',
        server: '203.0.113.32',
        port: 443,
        protocol: ProxyProtocol.trojan,
      );
      final d = CoreDetector().resolve(p, preference: CorePreference.auto);
      expect(d.core, CoreKind.singbox,
          reason: 'plain subscriptions keep the per-node matrix (auto)');
    });

    test('Android gate admits a Clash-origin mihomo node while the probe '
        'is unsettled', () {
      MihomoCoreState.instance.setRuntimeLoaded(false);
      final p = ProxyProfile(
        id: 'clash-node-3',
        name: 'Clash node 3',
        server: '203.0.113.33',
        port: 443,
        protocol: ProxyProtocol.trojan,
        metadata: {'origin': 'clash'},
      )..core = CoreKind.mihomo;
      expect(AndroidNodeSupport.coreAllowedOnAndroid(CoreKind.mihomo,
          profile: p), isTrue);
      // A NON-Clash mihomo node stays gated on the probe.
      final q = _xhttp()..core = CoreKind.mihomo;
      expect(AndroidNodeSupport.coreAllowedOnAndroid(CoreKind.mihomo,
          profile: q), isFalse);
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
