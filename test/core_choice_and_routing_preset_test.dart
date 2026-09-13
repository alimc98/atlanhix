import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/android_node_support.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/node_core_choice.dart';
import 'package:nexus/data/profile_codec_write.dart';
import 'package:nexus/data/secure_vault.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/settings/routing_settings.dart';

/// Regression for the v0.4.1 user rules:
///   1. per-node core choice (Auto / sing-box / Xray) with Auto as the
///      default, and Xray OFFERED ONLY where it can actually run —
///      hysteria/tuic are sing-box-only (user: "hysteria روي xray
///      فکر کنم نباشه" — correct);
///   2. NO pre-defined routing — builtin packs are library data applied
///      only by explicit user action; a fresh model starts disabled.
void main() {
  ProxyProfile p(ProxyProtocol k) => ProxyProfile(
        id: 'n-${k.name}',
        name: k.name,
        server: 'example.invalid',
        port: 443,
        protocol: k,
      );

  group('per-node core choice', () {
    test('default profile has NO pinned core (== Auto badge)', () {
      final prof = p(ProxyProtocol.hysteria2);
      expect(prof.userPinnedCore, isNull);
      expect(NodeCoreChoice.labelFor(prof, onAndroid: true), 'auto');
    });

    test('Auto badge is honest about the engine per platform', () {
      final sing = p(ProxyProtocol.vless)
          .copyWith(userPinnedCore: CoreKind.singbox);
      expect(NodeCoreChoice.labelFor(sing, onAndroid: true), 'sing-box');
      final xray = p(ProxyProtocol.vless)
          .copyWith(userPinnedCore: CoreKind.xray);
      // On Android the Xray badge must tell the truth (desktop only);
      // on desktop it is a plain Xray.
      expect(NodeCoreChoice.labelFor(xray, onAndroid: true),
          'Xray · desktop only');
      expect(NodeCoreChoice.labelFor(xray, onAndroid: false), 'Xray');
    });

    test('Hysteria/TUIC/naive never run on Xray (sing-box-only)', () {
      for (final k in [
        ProxyProtocol.hysteria,
        ProxyProtocol.hysteria2,
        ProxyProtocol.tuic,
        ProxyProtocol.naive,
      ]) {
        expect(NodeCoreChoice.xrayCanRun(p(k)), isFalse, reason: k.name);
        expect(NodeCoreChoice.xrayWarning(p(k), onAndroid: false),
            isNotNull,
            reason: '${k.name} must show why Xray is disabled');
      }
    });

    test('Xray-capable protocols offer Xray on desktop without warning',
        () {
      for (final k in [
        ProxyProtocol.vless,
        ProxyProtocol.vmess,
        ProxyProtocol.trojan,
      ]) {
        expect(NodeCoreChoice.xrayCanRun(p(k)), isTrue, reason: k.name);
        expect(NodeCoreChoice.xrayWarning(p(k), onAndroid: false), isNull);
      }
    });

    test('on Android, Xray-capable protocols still warn honestly', () {
      final w =
          NodeCoreChoice.xrayWarning(p(ProxyProtocol.vless), onAndroid: true);
      expect(w, isNotNull);
      expect(w, contains('Android'));
    });

    test('pinning survives the storage codec roundtrip', () {
      final prof = p(ProxyProtocol.vless)
          .copyWith(userPinnedCore: CoreKind.xray);
      expect(prof.effectiveCore, CoreKind.xray);
      final json = profileToStorable(prof, InMemoryVault(), 'salt');
      expect(json['userPinnedCore'], 'xray');
    });
  });

group('engine capability matrix (device bug: reality nodes were locked out)', () {
    test('vless+reality+vision over grpc/wS/tcp is sing-box on Android', () {
      for (final tp in [Transport.grpc, Transport.ws, Transport.tcp]) {
        final prof = ProxyProfile(
          id: 'r-$tp', name: 'r', server: 'example.invalid', port: 443,
          protocol: ProxyProtocol.vless, transport: tp,
          security: Security.reality, flow: 'xtls-rprx-vision',
          uuid: 'u', realityPublicKey: 'k',
        );
        final d = CoreDetector().detect(prof);
        expect(d.core, CoreKind.singbox,
            reason: 'sing-box 1.14 implements reality + vision + $tp');
        expect(AndroidNodeSupport.notRunnableReason(prof), isNull,
            reason: 'auto-classified nodes run on-device ($tp)');
      }
    });

    test('xhttp transport stays Xray-only (honest lock)', () {
      final prof = ProxyProfile(
        id: 'x', name: 'x', server: 'example.invalid', port: 443,
        protocol: ProxyProtocol.vless, transport: Transport.xhttp,
        security: Security.tls, uuid: 'u',
      );
      expect(CoreDetector().detect(prof).core, CoreKind.xray);
      expect(AndroidNodeSupport.isRunnable(prof), isFalse);
      expect(AndroidNodeSupport.notRunnableReason(prof),
          'Xray-only transport');
    });

    test('USER-PINNED Xray keeps its honest Android lock', () {
      final prof = ProxyProfile(
        id: 'pin', name: 'pin', server: 'example.invalid', port: 443,
        protocol: ProxyProtocol.trojan, transport: Transport.tcp,
        password: 'p',
      ).copyWith(userPinnedCore: CoreKind.xray);
      expect(AndroidNodeSupport.isRunnable(prof), isFalse,
          reason: 'a pin is an explicit choice — never swapped silently');
      expect(AndroidNodeSupport.notRunnableReason(prof),
          'Xray (desktop only)');
      expect(AndroidNodeSupport.androidExclusionReason(prof),
          contains('xray_pinned'));
    });
  });

  group('routing is never pre-applied', () {
    test('a fresh RoutingSettings is disabled and carries no user rules', () {
      final r = RoutingSettings();
      expect(r.enabled, isFalse);
      expect(r.directApps, isEmpty);
      expect(r.proxyApps, isEmpty);
      expect(r.directDomains, isEmpty);
      expect(r.proxyDomains, isEmpty);
      expect(r.directCidrs, isEmpty);
      expect(r.proxyCidrs, isEmpty);
      expect(r.customRules, isEmpty);
    });

    test('legacy persisted JSON without an enabled key loads as OFF', () {
      final r = RoutingSettings.fromJson({
        'mode': 'rule',
        'directApps': ['some.pkg'],
      });
      expect(r.enabled, isFalse);
    });

    test('builtin packs exist as selectable data only', () {
      final packs = BuiltinRoutingProfiles.all();
      expect(packs, isNotEmpty);
      expect(packs.every((e) => e.isBuiltin), isTrue);
      // Applying a pack is a user action in the editor UI; the model never
      // applies it automatically (fresh profile above is empty & OFF).
    });
  });
}
