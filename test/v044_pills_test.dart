import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/fragmentation/fragment_profiles.dart';
import 'package:nexus/settings/app_settings.dart';
import 'package:nexus/settings/runtime_config_bridge.dart';
import 'package:nexus/settings/routing_settings.dart';

/// v0.4.4 mockup pills: QUICK SETTINGS must be explicit opt-ins that flow
/// into the compiled profile, and localPort/proxyMode must round-trip.
void main() {
  test('pills default all OFF (no predefined routing)', () {
    final s = AppSettings();
    expect(s.iranAppsDirect, isFalse);
    expect(s.adsBlock, isFalse);
    expect(s.tlsFragment, isFalse);
    expect(s.proxyMode, isFalse);
    expect(s.localPort, 2080);
  });

  test('json round-trip keeps pill + port + mode values', () {
    final s = AppSettings()
      ..iranAppsDirect = true
      ..adsBlock = true
      ..tlsFragment = true
      ..fragmentPreset = FragmentPreset.aggressive
      ..proxyMode = true
      ..localPort = 2087;
    final r = AppSettings.fromJson(s.toJson());
    expect(r.iranAppsDirect, isTrue);
    expect(r.adsBlock, isTrue);
    expect(r.tlsFragment, isTrue);
    expect(r.fragmentPreset, FragmentPreset.aggressive);
    expect(r.proxyMode, isTrue);
    expect(r.localPort, 2087);
  });

  test('fragmentPreset defaults to conservative and survives unknown json',
      () {
    expect(AppSettings().fragmentPreset, FragmentPreset.conservative);
    // Legacy store section without the new key → safe fallback, not a crash.
    final r = AppSettings.fromJson({
      'tlsFragment': true,
    });
    expect(r.fragmentPreset, FragmentPreset.conservative);
    // Garbage value → safe fallback too.
    final r2 = AppSettings.fromJson({'fragmentPreset': 'turbo'});
    expect(r2.fragmentPreset, FragmentPreset.conservative);
  });

  test('FragmentPreset maps 1:1 onto the FragmentPresets profiles', () {
    expect(FragmentPresets.profileFor(FragmentPreset.conservative).id,
        'conservative');
    expect(FragmentPresets.profileFor(FragmentPreset.defaultPreset).id,
        'default');
    expect(FragmentPresets.profileFor(FragmentPreset.aggressive).id,
        'aggressive');
  });

  test('Iran Apps pill prepends direct rules; off adds none', () {
    final settings = AppSettings();
    final bridge = RuntimeConfigBridge(
        settings: settings, routing: RoutingSettings());
    final baseCount = bridge.routingProfile().rules.length;
    settings.iranAppsDirect = true;
    final withPill = bridge.routingProfile();
    expect(withPill.rules.length, greaterThan(baseCount));
    expect(withPill.rules.first.id, startsWith('pill-ir'));
    expect(withPill.rules.first.action.name, 'direct');
  });

  test('Ads pill yields block rules', () {
    final bridge = RuntimeConfigBridge(
        settings: AppSettings()..adsBlock = true,
        routing: RoutingSettings());
    final ads = bridge.routingProfile().rules.where((r) => r.id.startsWith('pill-ads'));
    expect(ads, isNotEmpty);
    expect(ads.first.action.name, 'block');
  });
}
