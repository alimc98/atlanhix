import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/logger.dart';
import 'mihomo_bridge.dart';
import 'xray_bridge.dart';

/// v0.6.3 §notify-fix (\"برنامه بسته هم باشه باز توي نوتيفيكشن بار Atlanhix core
/// مياد\") — boot-time orphan sweep for the child cores.
///
/// `:xray` and `:mihomo` are separate foreground services with their own
/// \"Atlanhix core\" notification. `AtlanhixVpnService` now stops them on
/// EVERY tunnel teardown (stop, revoke, swipe-away, service destroy), but a
/// FORCE-kill (app killed by the OS/low memory, `am force-stop`, or a crash
/// in the main process) can leave the child process running with nobody left
/// to ask it to stop — the notification then stays in the shade until the
/// user reboots. This sweep runs once at app boot: if the native VPN state
/// has NO live session, any child that still reports itself alive is
/// orphaned and is stopped.
///
/// Safe by construction: it never touches a session the user is in (the
/// live-state check runs first) and it is a no-op on desktop/test hosts,
/// where the channel does not exist.
Future<void> sweepOrphanedCores() async {
  var native = 'IDLE';
  try {
    final raw = await const MethodChannel('dev.atlanhix/vpn')
        .invokeMethod<String>('state');
    native = ((jsonDecode(raw ?? '{}') as Map)['state'] as String? ?? 'IDLE')
        .toUpperCase();
  } on MissingPluginException {
    return; // desktop / tests: the cores are managed by CoreManager
  } catch (e) {
    Logger.instance.info('core-sweep', 'state read failed: $e');
    return;
  }
  // A live (or mid-flight) tunnel OWNS its children — hands off.
  const live = {
    'CONNECTED',
    'VALIDATING',
    'STARTING',
    'PREPARING',
    'RECONNECTING',
  };
  if (live.contains(native)) return;
  try {
    await XrayBridge.instance.probe();
    await MihomoBridge.instance.probe();
    if (XrayBridge.instance.running) {
      Logger.instance.warn('core-sweep',
          'orphaned :xray child (no live session, native=$native) — stopping');
      await XrayBridge.instance.stop();
    }
    if (MihomoBridge.instance.running) {
      Logger.instance.warn('core-sweep',
          'orphaned :mihomo child (no live session, native=$native) — stopping');
      await MihomoBridge.instance.stop();
    }
  } catch (e) {
    Logger.instance.info('core-sweep', 'sweep failed: $e');
  }
}
