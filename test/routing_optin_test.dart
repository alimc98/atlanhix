import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/connection_controller.dart';
import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'helpers/prepare_node.dart';

/// Routing is OPT-IN (default OFF) — contract tests.
///
/// The connect pipeline is vpn_session._buildEngineConfig →
/// SingBoxRuntime.buildConfig → SingBoxConfigGenerator.generate. These tests
/// replay that exact chain against RoutingSettings in its three states:
/// default-off, Global on, Rule on — and assert on the FINAL generated JSON
/// (cfg['route']['rules']), not just the compiled profile.
void main() {
  // ---------------------------------------------------------- pipeline util
  /// Replays the REAL Android connect pipeline: bridge → routingProfile() →
  /// CoreManager.front.buildConfig (SingBoxRuntime.buildConfig), the same
  /// call vpn_session.dart makes in _buildEngineConfig, then returns the
  /// generated sing-box config as decoded JSON.
  Map<String, dynamic> buildViaConnectPipeline(RoutingSettingsBridge bridge) {
    final cores = CoreManager(
      binaryManager: _FailingBinaryManager(),
      workDir: Directory.systemTemp,
    );
    return cores.front.buildConfig(
      [makeRunnableNode()],
      selectedProfileId: 'optin-node',
      routing: bridge.routingProfile(),
      dns: bridge.dnsSettings(),
    );
  }

  group('RoutingSettings model — opt-in semantics', () {
    test('default state is OFF with mode reserved as rule', () {
      final s = RoutingSettings();
      expect(s.enabled, isFalse, reason: 'routing must be opt-in');
      expect(s.mode, RoutingMode.rule);
      expect(s.directApps, isEmpty);
      expect(s.proxyApps, isEmpty);
      expect(s.directDomains, isEmpty);
      expect(s.proxyDomains, isEmpty);
      expect(s.customRules, isEmpty);
    });

    test('toRoutingProfile() when OFF returns a profile with ZERO rules', () {
      final s = RoutingSettings()
        // Lists filled in as drafts but routing never enabled — still OFF.
        ..directDomains.add('ir.example.com')
        ..directApps.add('com.digikala');
      final p = s.toRoutingProfile();
      expect(p.rules, isEmpty);
      expect(p.id, 'routing-disabled');
    });

    test('toAndroidAppLists() when OFF returns empty lists', () {
      final s = RoutingSettings()..proxyApps.add('com.foo');
      final lists = s.toAndroidAppLists();
      expect(lists.include, isEmpty);
      expect(lists.exclude, isEmpty);
    });

    test('legacy persisted section without `enabled` loads as OFF', () {
      // Sections persisted by the pre-opt-in build never carried `enabled`.
      final s = RoutingSettings.fromJson({
        'mode': 'rule',
        'directDomains': ['legacy.example'],
        'finalOutbound': 'proxy',
      });
      expect(s.enabled, isFalse);
      expect(s.toRoutingProfile().rules, isEmpty);
    });

    test('round-trip preserves the enabled flag', () {
      final on = RoutingSettings(enabled: true, mode: RoutingMode.global)
        ..directDomains.add('a.example');
      final restored = RoutingSettings.fromJson(
          jsonDecode(jsonEncode(on.toJson())) as Map<String, dynamic>);
      expect(restored.enabled, isTrue);
      expect(restored.mode, RoutingMode.global);
      expect(restored.directDomains, ['a.example']);
    });
  });

  group('connect pipeline (real buildConfig chain) — default connect', () {
    test('default connect → route.rules has NO user rules', () {
      final bridge = RoutingSettingsBridge(RoutingSettings()); // default OFF
      final cfg = buildViaConnectPipeline(bridge);

      final route = cfg['route'] as Map;
      final rules = (route['rules'] as List).cast<Map>();
      // Engine minimum: sniff + DNS hijack + the ALWAYS-ON private→direct
      // safety rule (v0.4.4 device fix: also keeps the `direct` outbound
      // referenced so sing-box 1.14 does not reject the clean-DNS detour).
      expect(rules, hasLength(3));
      expect(rules.any((r) => r['action'] == 'sniff'), isTrue);
      expect(rules.any((r) => r['action'] == 'hijack-dns'), isTrue);
      expect(rules.any((r) => r['ip_is_private'] == true), isTrue);
      // No user rules of any kind.
      expect(rules.where((r) => r.containsKey('domain')), isEmpty);
      expect(rules.where((r) => r.containsKey('ip_cidr')), isEmpty);
      expect(rules.where((r) => r.containsKey('domain_suffix')), isEmpty);
      // Selected node still reachable: final stays the proxy selector.
      expect(route['final'], 'proxy');
      // Android handoff (per-app lists) also empty when off.
      expect(bridge.androidAppLists().include, isEmpty);
      expect(bridge.androidAppLists().exclude, isEmpty);
    });

    test('default connect config has the real outbound topology', () {
      final bridge = RoutingSettingsBridge(RoutingSettings());
      final cfg = buildViaConnectPipeline(bridge);
      final outbounds = (cfg['outbounds'] as List).cast<Map>();
      final selector = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      expect(selector['type'], 'selector');
      expect((selector['outbounds'] as List), contains('node:optin-node'));
      expect(outbounds.any((o) => o['tag'] == 'direct'), isTrue);
      // DNS handling present (minimum the engine needs).
      expect((cfg['dns'] as Map)['servers'], isNotEmpty);
    });
  });

  group('connect pipeline — Global mode enabled', () {
    test('enabling Global → minimal global behavior (private-net DIRECT '
        'safety, no user rule lists)', () {
      final s = RoutingSettings(enabled: true, mode: RoutingMode.global);
      final bridge = RoutingSettingsBridge(s);
      final cfg = buildViaConnectPipeline(bridge);

      final route = cfg['route'] as Map;
      final rules = (route['rules'] as List).cast<Map>();
      // sniff, hijack-dns, private-networks → DIRECT (as ip_is_private rule
      // plus the generator's explicit private-CIDR rule). Nothing else.
      expect(rules, hasLength(4));
      final priv = rules
          .where((r) => r['ip_is_private'] == true)
          .toList();
      expect(priv, hasLength(1));
      expect(priv.single['outbound'], 'direct');
      // Global mode applies NO per-list rules by itself (the only ip_cidr
      // rule is the generator's exhaustive private-CIDR baseline).
      expect(rules.where((r) => r.containsKey('domain')), isEmpty);
      final cidrRules = rules
          .where((r) => r.containsKey('ip_cidr'))
          .cast<Map>()
          .toList();
      final privateCidrs = {'10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
        '127.0.0.0/8', '169.254.0.0/16', '::1/128', 'fc00::/7', 'fe80::/10'};
      expect(cidrRules.every((r) =>
          (r['ip_cidr'] as List).every(privateCidrs.contains)), isTrue,
          reason: 'only the private-CIDR baseline may exist in Global mode');
      expect(route['final'], 'proxy');
    });

    test('Global + user drafts present → still only the global minimum '
        '(lists apply in Rule mode)', () {
      final s = RoutingSettings(enabled: true, mode: RoutingMode.global)
        ..proxyDomains.add('openai.com');
      final bridge = RoutingSettingsBridge(s);
      final rules = ((buildViaConnectPipeline(bridge)['route']
              as Map)['rules'] as List)
          .cast<Map>();
      expect(rules, hasLength(4));
      expect(rules.where((r) => r['domain'] != null), isEmpty,
          reason: 'Global mode must not compile per-domain rules');
    });
  });

  group('connect pipeline — Rule mode enabled with lists', () {
    test('enabling Rule with app/domain/CIDR lists → exact rules present',
        () {
      final s = RoutingSettings(enabled: true, mode: RoutingMode.rule)
        ..directDomains.add('digikala.com')
        ..proxyDomains.add('*.openai.com')
        ..directCidrs.add('10.0.0.0/8')
        ..proxyCidrs.add('1.1.1.1/32');
      final bridge = RoutingSettingsBridge(s);
      final cfg = buildViaConnectPipeline(bridge);

      final route = cfg['route'] as Map;
      final rules = (route['rules'] as List).cast<Map>();
      // sniff + hijack + private (2 rules) + 4 user rules (exact dom,
      // suffix dom, direct cidr, proxy cidr).
      expect(rules, hasLength(8));

      final directDom = rules
          .where((r) => r['domain'] != null &&
              (r['domain'] as List).contains('digikala.com') &&
              r['outbound'] == 'direct')
          .toList();
      expect(directDom, hasLength(1));

      final suffixDom = rules
          .where((r) =>
              r['domain_suffix'] != null &&
              (r['domain_suffix'] as List).contains('openai.com') &&
              r['outbound'] == 'proxy')
          .toList();
      expect(suffixDom, hasLength(1));

      final directCidr = rules
          .where((r) =>
              r['ip_cidr'] != null &&
              (r['ip_cidr'] as List).contains('10.0.0.0/8') &&
              r['outbound'] == 'direct')
          .toList();
      expect(directCidr, isNotEmpty,
          reason: '10.0.0.0/8 → direct must be present');
      expect(directCidr.any((r) => (r['ip_cidr'] as List).length == 1),
          isTrue,
          reason: 'the user 10.0.0.0/8 rule exists alongside the generator '
              'private-CIDR baseline rule');

      final proxyCidr = rules
          .where((r) =>
              r['ip_cidr'] != null &&
              (r['ip_cidr'] as List).contains('1.1.1.1/32') &&
              r['outbound'] == 'proxy')
          .toList();
      expect(proxyCidr, hasLength(1));

      // Private-networks safety rule accompanies enabled routing.
      expect(rules.any((r) => r['ip_is_private'] == true), isTrue);
      expect(route['final'], 'proxy');
    });

    test('Rule mode with EMPTY lists → no user rules beyond the private-net '
        'safety rule (empty lists apply nothing)', () {
      final s = RoutingSettings(enabled: true, mode: RoutingMode.rule);
      final bridge = RoutingSettingsBridge(s);
      final rules = ((buildViaConnectPipeline(bridge)['route'] as Map)['rules']
              as List)
          .cast<Map>();
      expect(rules, hasLength(4)); // sniff, hijack-dns, private → direct ×2
      expect(rules.any((r) => r['ip_is_private'] == true), isTrue);
    });

    test('Rule mode per-app lists reach the Android handoff', () {
      final s = RoutingSettings(enabled: true, mode: RoutingMode.rule)
        ..proxyApps.add('com.allowed.app');
      final bridge = RoutingSettingsBridge(s);
      // Allow-list mode (include wins over exclude by contract).
      expect(bridge.androidAppLists().include, ['com.allowed.app']);
      expect(bridge.androidAppLists().exclude, isEmpty);

      final excl = RoutingSettingsBridge(
          RoutingSettings(enabled: true)..directApps.add('com.bypass.app'));
      expect(excl.androidAppLists().include, isEmpty);
      expect(excl.androidAppLists().exclude, ['com.bypass.app']);
    });

    test('full androidHandoff JSON: includeApps only when opted in', () {
      final off = RoutingSettingsBridge(RoutingSettings()..proxyApps.add('x'));
      final offHandoff = off
          .androidHandoff(singBoxConfigJson: '{}');
      expect(offHandoff['includeApps'], isEmpty);
      expect(offHandoff['excludeApps'], isEmpty);

      final on = RoutingSettingsBridge(
          RoutingSettings(enabled: true)..proxyApps.add('x'));
      final onHandoff =
          on.androidHandoff(singBoxConfigJson: '{}');
      expect(onHandoff['includeApps'], ['x']);
    });
  });

  group('bridge persistence honors opt-in', () {
    test('repository round-trip keeps OFF for a legacy store', () async {
      final dir = await Directory.systemTemp.createTemp('nexus_routing_test');
      addTearDown(() => dir.delete(recursive: true));
      final store = JsonStore(directory: dir, schemaVersion: 1);
      await store.load();
      // Simulate a pre-opt-in store: no `enabled` key at all.
      await store.putSection('routingSettings', {
        'mode': 'global',
        'directDomains': ['old.example'],
      });
      final repo = RoutingSettingsRepository(store);
      await repo.load();
      expect(repo.current.enabled, isFalse);
      expect(repo.current.toRoutingProfile().rules, isEmpty);
    });

    test('repository save keeps enabled=true and it survives reload',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus_routing_test');
      addTearDown(() => dir.delete(recursive: true));
      final store = JsonStore(directory: dir, schemaVersion: 1);
      await store.load();
      final repo = RoutingSettingsRepository(store);
      final s = RoutingSettings(enabled: true, mode: RoutingMode.rule)
        ..directDomains.add('enabled.example');
      expect(await repo.save(s), isEmpty);
      final repo2 = RoutingSettingsRepository(store);
      await repo2.load();
      expect(repo2.current.enabled, isTrue);
      expect(repo2.current.toRoutingProfile().rules, isNotEmpty);
    });
  });

  group('desktop ConnectionController default', () {
    test('starts rule-less (opt-in), not with a builtin profile', () {
      final c = ConnectionController(
        repository: _UnusedProfileRepository(),
        healthStore: HealthStore(),
        tester: LatencyTester(),
        detector: CoreDetector(),
        cores: _coresStub(),
      );
      expect(c.routing.rules, isEmpty,
          reason: 'desktop connect must not force builtin routing rules');
      expect(c.routing.id, 'routing-disabled');
    });
  });

  group('Xray upstream config respects the same gate', () {
    test('rule-less profile → xray routing.rules has only the bittorrent '
        'block + final direct rule', () {
      final vmessNode = ProxyProfile(
        id: 'xray-node',
        name: 'xray test node',
        server: 'node.example.com',
        port: 443,
        protocol: ProxyProtocol.vmess,
        security: Security.tls,
        uuid: '[REDACTED]',
      );
      final cfg = XrayConfigGenerator().generate(
        profile: vmessNode,
        localSocksPort: 2081,
        routing: RoutingSettings().toRoutingProfile(),
      );
      final rules = (cfg['routing'] as Map)['rules'] as List;
      final userRules = rules
          .where((r) => (r as Map)['domain'] != null || r['ip'] != null)
          .toList();
      expect(userRules, isEmpty);
    });
  });
}

// ------------------------------------------------------------------ helpers

/// Bridges RoutingSettings the same way RuntimeConfigBridge does — the real
/// RuntimeConfigBridge requires AppSettings; this standalone adapter reuses
/// RoutingSettings' own compilation (identical methods, identical behavior)
/// so the tests stay unit-scoped without touching app storage.
class RoutingSettingsBridge {
  RoutingSettingsBridge(this.routing);
  final RoutingSettings routing;

  RoutingProfile routingProfile() => routing.toRoutingProfile();
  ({List<String> include, List<String> exclude}) androidAppLists() =>
      routing.toAndroidAppLists();
  DnsSettings dnsSettings() => DnsSettings(mode: DnsMode.automatic);
  Map<String, dynamic> androidHandoff({required String singBoxConfigJson}) => {
        'includeApps': androidAppLists().include,
        'excludeApps': androidAppLists().exclude,
      };
}

/// BinaryManager stub: config generation itself never touches binaries.
class _FailingBinaryManager extends BinaryManager {}

class _UnusedProfileRepository implements ProfileRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unused');
}

CoreManager _coresStub() => CoreManager(
      binaryManager: _FailingBinaryManager(),
      workDir: Directory.systemTemp,
    );
