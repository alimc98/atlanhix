import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/dependencies.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/health/test_scheduler.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/settings/app_settings.dart';
import 'package:nexus/settings/vpn_session.dart';

/// Pins the v0.5.3 §user-fix ("دستی انتخاب کردم، دوباره اسمارت‌سوییچ شد"):
/// a MANUAL node pick is sticky across disconnects — the next connect dials
/// the SAME node; only turning the Smart Switch back on releases the hold.
void main() {
  late AppDependencies deps;

  setUpAll(() async {
    deps = await AppDependencies.bootstrapForTest();
    // The SmartSwitch singleton reads these at construction time.
    deps.tester = LatencyTester();
    deps.healthStore = HealthStore();
    deps.scheduler =
        TestScheduler(tester: deps.tester, store: deps.healthStore);
    await deps.store.load();
    deps.appSettingsRepo = AppSettingsRepository(deps.store);
    deps.appSettings = deps.appSettingsRepo.current;
  });

  ProxyProfile node(String id) => ProxyProfile(
        id: id,
        name: 'Node $id',
        server: '203.0.113.10',
        port: 443,
        protocol: ProxyProtocol.shadowsocks,
        ssMethod: 'aes-128-gcm',
        password: 'ss-pass-1',
      );

  VpnSession session() => VpnSession(deps: deps);

  test('selectNode sets the manual hold; persistState records it', () async {
    final s = session();
    s.selectNode(node('n1'));
    expect(s.selectedNode?.id, 'n1');
    expect(s.isSmartSwitchActive, isFalse);
    // The hold is private; its PERSISTED trace is observable in the
    // sessionState section (putSection is synchronous in-memory).
    final section = deps.store.section('sessionState');
    expect(section['selectedNodeId'], 'n1');
    expect(section['manualSelectionHold'], isTrue);
  });

  test('enableSmartSwitch releases the hold (explicit hand-back to auto)',
      () {
    final s = session();
    s.selectNode(node('n1'));
    s.enableSmartSwitch();
    expect(s.isSmartSwitchActive, isTrue);
    // Simulate a disconnect-clear: the selection must now DROP (no hold).
    s.clearDisconnectedStateForTest();
    expect(s.selectedNode, isNull);
  });

  test('manual pick SURVIVES clearDisconnectedState (the bug fix)', () {
    final s = session();
    s.selectNode(node('n2'));
    s.clearDisconnectedStateForTest();
    // THE FIX: without the hold this was null → the next connect re-ran
    // the ladder over the user's head.
    expect(s.selectedNode?.id, 'n2');
    // And the live switch flag STAYS OFF while the hold is active — the
    // old code re-converged to the preference (default ON) and re-armed
    // the ladder behind the user's back.
    expect(s.isSmartSwitchActive, isFalse);
  });

  test('auto mode still drops the selection after disconnect', () {
    final s = session();
    s.enableSmartSwitch(); // auto mode, no manual hold
    s.selectedNode = node('n9'); // ladder pick (not a user tap)
    s.clearDisconnectedStateForTest();
    expect(s.selectedNode, isNull,
        reason: 'auto mode keeps the old clear-on-disconnect behavior');
  });
}
