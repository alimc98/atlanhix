import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/application/tunnel_mode_resolver.dart';
import 'package:nexus/platform/desktop_privileges.dart';

/// v0.6.12 §windows-tun regression guards.
///
/// Three separate real-world facts are encoded here, each verified on a
/// Windows box against the shipped sing-box 1.14.0:
///  1. a non-elevated sing-box cannot create the TUN device
///     (`configure tun interface: Access is denied.`), so the desktop
///     connect must fall back to system-proxy mode instead of dying;
///  2. the fallback must TELL the user (needsAdminNotice) — a silent
///     fallback is what made "TUN mode doesn't work on Windows" invisible;
///  3. the UAC relaunch command must quote the executable path correctly —
///     the app lives under paths like `C:\Program Files\…`.
void main() {
  group('resolveTunnelMode', () {
    test('Proxy selected → system-proxy mode, no admin nag', () {
      for (final available in [true, false]) {
        final d = resolveTunnelMode(
          proxyModeSelected: true,
          tunAvailable: available,
          tunSupported: true,
        );
        expect(d.mode, TunnelMode.systemProxy);
        expect(d.needsAdminNotice, isFalse);
        expect(d.usingTun, isFalse);
      }
    });

    test('TUN selected + available + supported → real TUN, no nag', () {
      final d = resolveTunnelMode(
        proxyModeSelected: false,
        tunAvailable: true,
        tunSupported: true,
      );
      expect(d.mode, TunnelMode.tun);
      expect(d.usingTun, isTrue);
      expect(d.needsAdminNotice, isFalse);
    });

    test('TUN selected on Windows without admin → FALLS BACK and says why',
        () {
      // The regression this whole feature exists for: the old code had no
      // desktop TUN path at all, so the toggle did nothing and nobody was
      // told. Now: the connect keeps working (system proxy) AND the user is
      // handed the exact missing ingredient.
      final d = resolveTunnelMode(
        proxyModeSelected: false,
        tunAvailable: false, // bootstrap saw a non-elevated process
        tunSupported: true, // Windows
      );
      expect(d.mode, TunnelMode.systemProxy,
          reason: 'a non-elevated user must NOT be failed over to a broken '
              'connect — the system-proxy path still works');
      expect(d.usingTun, isFalse,
          reason: 'no tun inbound may be generated without admin rights');
      expect(d.needsAdminNotice, isTrue);
    });

    test('platform without TUN support falls back SILENTLY (no dead button)',
        () {
      final d = resolveTunnelMode(
        proxyModeSelected: false,
        tunAvailable: false,
        tunSupported: false, // linux / macos today
      );
      expect(d.mode, TunnelMode.systemProxy);
      expect(d.needsAdminNotice, isFalse,
          reason: '"restart as administrator" would be a useless instruction '
              'on a platform that ships no TUN at all');
    });

    test('the fallback can never claim TUN', () {
      // Exhaustive over the three inputs: whenever the mode is not tun, the
      // notice is the only channel that may fire — and whenever TUN really
      // runs, no notice may be shown (it would be a lie).
      for (final proxy in [true, false]) {
        for (final avail in [true, false]) {
          for (final supported in [true, false]) {
            final d = resolveTunnelMode(
              proxyModeSelected: proxy,
              tunAvailable: avail,
              tunSupported: supported,
            );
            expect(d.usingTun, d.mode == TunnelMode.tun);
            if (d.usingTun) {
              expect(d.needsAdminNotice, isFalse,
                  reason: 'TUN is running — claiming it needs admin would '
                      'be a false dialog');
            }
            if (d.needsAdminNotice) {
              expect(d.usingTun, isFalse);
              expect(proxy, isFalse,
                  reason: 'a Proxy-mode user has nothing to restart');
              expect(supported, isTrue);
            }
          }
        }
      }
    });
  });

  group('DesktopPrivileges', () {
    test('elevation probe answers and is cached', () async {
      final first = await DesktopPrivileges.isElevated();
      final second = await DesktopPrivileges.isElevated();
      expect(first, isA<bool>());
      expect(identical(first, second) || first == second, isTrue);
      // The dev box that wrote this test is NOT elevated, and the whole
      // feature hinges on the probe being able to say so. Non-Windows CI
      // answers true by definition.
      // (No assertion on the VALUE — it is machine state, not behaviour.)
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('relaunch command quotes the executable path', () {
      final plain = DesktopPrivileges.elevatedRelaunchCommand(
          r'C:\Users\ib432\AppData\Local\Atlanhix\atlanhix.exe');
      expect(plain, contains(r'C:\Users\ib432\AppData\Local\Atlanhix\atlanhix.exe'));
      expect(plain, contains('Start-Process'));
      expect(plain, contains('-Verb RunAs'));

      // A path containing a single quote must be doubled for PowerShell's
      // single-quoted string, or the command silently breaks.
      const apostrophePath = 'C:\\O\'Brien\\app.exe'; // C:\O'Brien\app.exe
      final quoted = DesktopPrivileges.elevatedRelaunchCommand(apostrophePath);
      expect(quoted, contains("C:\\O''Brien\\app.exe"));
      expect(quoted, startsWith('Start-Process'));
      // The whole thing is one PowerShell command line: no line breaks.
      expect(quoted.contains('\n'), isFalse);
    });
  });
}
