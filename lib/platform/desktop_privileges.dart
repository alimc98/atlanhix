import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/logger.dart';

/// v0.6.12 §windows-tun — privilege facts for the desktop TUN gate.
///
/// Why this exists: a Windows TUN inbound (`auto_route`) can only be created
/// by an Administrator. Reproduced on the dev box against the shipped
/// sing-box 1.14.0 while not elevated:
///
///   FATAL[0000] start service: start inbound/tun[tun-in]:
///   configure tun interface: Access is denied.
///
/// (The upstream Windows archive carries no `wintun.dll` either — CI bundles
/// it beside sing-box.exe since v0.6.12.) So the app decides ONCE at boot:
/// elevated → TUN is available; not elevated → the tunnel falls back to the
/// system-proxy mode that already works, and the UI is told why so it can
/// offer a relaunch with a UAC consent prompt.
class DesktopPrivileges {
  DesktopPrivileges._();

  /// Cached — Administrator rights cannot change while the process lives.
  static bool? _elevated;

  /// True when this process already holds Administrator rights.
  ///
  /// Non-Windows platforms return true: the question only exists on Windows
  /// (Linux TUN needs root too, but that path is not shipped yet), and every
  /// caller uses this value as "may I create a TUN device?".
  static Future<bool> isElevated() async {
    final cached = _elevated;
    if (cached != null) return cached;
    if (!Platform.isWindows) return _elevated = true;
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '(New-Object Security.Principal.WindowsPrincipal('
            '[Security.Principal.WindowsIdentity]::GetCurrent()))'
            '.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
      ]).timeout(const Duration(seconds: 10));
      _elevated = r.stdout.toString().trim().toLowerCase() == 'true';
      Logger.instance
          .info('privileges', 'windows elevation probe -> $_elevated');
    } catch (e) {
      // Fail CLOSED: an unreadable answer must not hand out TUN rights.
      Logger.instance.warn('privileges', 'elevation probe failed: $e');
      _elevated = false;
    }
    return _elevated!;
  }

  /// The PowerShell one-liner that relaunches [exePath] behind a UAC consent
  /// prompt. Kept as a pure builder so tests can assert the exact quoting
  /// (the command itself is never executed by the test suite — it would pop
  /// a real consent dialog).
  @visibleForTesting
  static String elevatedRelaunchCommand(String exePath) =>
      "Start-Process -FilePath '${exePath.replaceAll("'", "''")}' -Verb RunAs";

  /// Asks Windows (UAC) to start a new, Administrator instance of this app.
  ///
  /// Returns true when the consent dialog was accepted and the elevated copy
  /// is starting — the caller must then close the current instance. Returns
  /// false when the prompt was cancelled or the launch failed, so the current
  /// instance stays exactly as it is (never leave the user with nothing).
  static Future<bool> relaunchElevated() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        elevatedRelaunchCommand(Platform.resolvedExecutable),
      ]).timeout(const Duration(seconds: 30));
      final ok = r.exitCode == 0;
      if (!ok) {
        Logger.instance.warn('privileges',
            'elevated relaunch refused (exit ${r.exitCode}): '
            '${r.stderr.toString().trim()}');
      }
      return ok;
    } catch (e) {
      Logger.instance.warn('privileges', 'elevated relaunch failed: $e');
      return false;
    }
  }

  /// Test seam — forget the cached probe (the answer is constant in real
  /// life, but unit tests must be able to run the probe twice).
  @visibleForTesting
  static void resetCache() => _elevated = null;
}
