import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/data/app_storage.dart';
import 'package:nexus/data/profile_repository.dart';
import 'package:nexus/data/secure_vault.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';

void main() {
  test('selection + smartSwitch survive a full store reload (process death)',
      () async {
    final dir =
        await Directory.systemTemp.createTemp('nexus_session_state_test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    // ── Run 1: pick a node, persist, "die". ──
    final store1 = JsonStore(
        directory: Directory('${dir.path}${Platform.pathSeparator}data'),
        schemaVersion: 1);
    await store1.load();
    final vault1 = InMemoryVault();
    final profiles1 = ProfileRepository(store1, vault1);
    await profiles1.load();
    final node = ProxyProfile(
      id: 'node-1',
      name: 'The Node',
      server: '10.0.0.1',
      port: 443,
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm',
      password: 'ss-pass-1',
    );
    await profiles1.upsertMany([node]);

    // Persist exactly the way VpnSession.persistState does.
    await store1.putSection('sessionState', {
      'selectedNodeId': 'node-1',
      'smartSwitch': true,
      'smartSwitchPreferred': true,
    });
    // Force the debounced flush to disk before the "process death".
    await store1.flush();

    // ── Run 2: a FRESH JsonStore over the same directory. ──
    final store2 = JsonStore(
        directory: Directory('${dir.path}${Platform.pathSeparator}data'),
        schemaVersion: 1);
    await store2.load();
    final vault2 = InMemoryVault();
    final profiles2 = ProfileRepository(store2, vault2);
    await profiles2.load();

    // Restore exactly the way VpnSession.restorePersistedState does.
    final s = store2.section('sessionState');
    final restoredSwitch = (s['smartSwitch'] as bool?) ?? false;
    final restoredId = s['selectedNodeId'] as String?;
    final restoredNode =
        restoredId == null ? null : profiles2.byId(restoredId);

    expect(restoredNode?.id, 'node-1',
        reason: 'the picked node must survive the process restart');
    expect(restoredSwitch, isTrue);
  });

  test('a stale node id restores to null (auto-select falls through)', () async {
    final dir =
        await Directory.systemTemp.createTemp('nexus_session_stale_test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final store = JsonStore(
        directory: Directory('${dir.path}${Platform.pathSeparator}data'),
        schemaVersion: 1);
    await store.load();
    await store.putSection('sessionState', {
      'selectedNodeId': 'vanished',
      'smartSwitch': false,
    });
    await store.flush();

    final vault = InMemoryVault();
    final profiles = ProfileRepository(store, vault);
    await profiles.load();

    final s = store.section('sessionState');
    final id = s['selectedNodeId'] as String?;
    expect(id != null && profiles.byId(id) != null, isFalse,
        reason: 'a deleted node must restore as "no selection", not a lie');
  });

  test('disconnect clear: selection nulls out, the switch PREFERENCE survives',
      () async {
    // The store contract of VpnSession._clearDisconnectedState():
    // selectedNodeId → null, smartSwitch re-armed to smartSwitchPreferred,
    // and the user's explicit card choice kept for the next session.
    final dir =
        await Directory.systemTemp.createTemp('nexus_session_clear_test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final store = JsonStore(
        directory: Directory('${dir.path}${Platform.pathSeparator}data'),
        schemaVersion: 1);
    await store.load();

    // Session: manual node picked, user's standing choice was AUTO.
    await store.putSection('sessionState', {
      'selectedNodeId': 'node-1',
      'smartSwitch': false,
      'smartSwitchPreferred': true,
    });
    await store.flush();

    // ── Disconnect clears the live state (same writes persistState makes) ──
    await store.putSection('sessionState', {
      'selectedNodeId': null,
      'smartSwitch': true, // = smartSwitchPreferred
      'smartSwitchPreferred': true,
    });
    await store.flush();

    // ── Fresh process restores it. ──
    final store2 = JsonStore(
        directory: Directory('${dir.path}${Platform.pathSeparator}data'),
        schemaVersion: 1);
    await store2.load();
    final vault = InMemoryVault();
    final profiles = ProfileRepository(store2, vault);
    await profiles.load();

    final s = store2.section('sessionState');
    final id = s['selectedNodeId'] as String?;
    expect(id, isNull, reason: 'disconnect must drop the half-remembered node');
    expect(s['smartSwitch'], true,
        reason: 'the live switch flag re-converges to the user\'s preference');
    expect(s['smartSwitchPreferred'], true,
        reason: 'the explicit card choice survives the disconnect');
  });

  test('legacy section without smartSwitchPreferred still restores', () async {
    final dir =
        await Directory.systemTemp.createTemp('nexus_session_legacy_test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final store = JsonStore(
        directory: Directory('${dir.path}${Platform.pathSeparator}data'),
        schemaVersion: 1);
    await store.load();
    // v0.5.0-early shape: no smartSwitchPreferred key at all.
    await store.putSection('sessionState', {
      'selectedNodeId': null,
      'smartSwitch': true,
    });
    await store.flush();

    final store2 = JsonStore(
        directory: Directory('${dir.path}${Platform.pathSeparator}data'),
        schemaVersion: 1);
    await store2.load();
    final s = store2.section('sessionState');
    // restorePersistedState falls back to the live flag, then the default.
    final preferred = (s['smartSwitchPreferred'] as bool?) ??
        ((s['smartSwitch'] as bool?) ?? true);
    expect(preferred, isTrue, reason: 'no legacy migration cliff');
  });
}
