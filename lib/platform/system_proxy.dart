import 'dart:io';

import '../core/logger.dart';

/// Desktop system proxy control (Phase 13).
///
/// Windows: WinINET per-user settings via `reg` + option refresh.
/// Linux:   GNOME/gsettings when present (environment-aware detection).
///
/// Guarantees:
///  * previous settings are captured before modification and restored on
///    disable (Phase 13: never leave the user's proxy pointing at a dead
///    local port);
///  * all operations are async — never block the UI isolate.
class SystemProxyController {
  SystemProxyController._();

  static final SystemProxyController instance = SystemProxyController._();

  bool _enabled = false;
  bool get isEnabled => _enabled;

  static const _kInternet =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  /// Local/private ranges excluded from system proxy.
  static const _proxyOverride =
      'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;'
      '172.2*;172.30.*;172.31.*;192.168.*;<local>';

  // Captured originals (Windows).
  String? _winPrevEnable;
  String? _winPrevServer;
  String? _winPrevOverride;

  Future<void> enable({required int port}) async {
    if (_enabled) return;
    try {
      if (Platform.isWindows) {
        await _winCapture();
        // W8 (fixed v0.3.0): proper argv lists — Process.run passes each
        // element as one argument, no fragile string splitting.
        await _reg(['add', _kInternet, '/v', 'ProxyEnable',
              '/t', 'REG_DWORD', '/d', '1', '/f']);
        await _reg(['add', _kInternet, '/v', 'ProxyServer',
              '/t', 'REG_SZ', '/d', '127.0.0.1:$port', '/f']);
        await _reg(['add', _kInternet, '/v', 'ProxyOverride',
              '/t', 'REG_SZ', '/d', _proxyOverride, '/f']);
        await _refreshWinInet();
      } else if (Platform.isLinux) {
        final hasGsettings =
            await _which('gsettings');
        if (hasGsettings) {
          await _run('gsettings', ['set', 'org.gnome.system.proxy', 'mode', 'manual']);
          await _run('gsettings',
              ['set', 'org.gnome.system.proxy.http', 'host', '127.0.0.1']);
          await _run('gsettings',
              ['set', 'org.gnome.system.proxy.http', 'port', '$port']);
          await _run('gsettings',
              ['set', 'org.gnome.system.proxy.https', 'host', '127.0.0.1']);
          await _run('gsettings',
              ['set', 'org.gnome.system.proxy.https', 'port', '$port']);
          await _run('gsettings',
              ['set', 'org.gnome.system.proxy.socks', 'host', '127.0.0.1']);
          await _run('gsettings',
              ['set', 'org.gnome.system.proxy.socks', 'port', '$port']);
        } else {
          Logger.instance.info('sysproxy',
              'gsettings not found — desktop proxy not applied (KDE/other DE)');
        }
      } else {
        return;
      }
      _enabled = true;
      Logger.instance.info('sysproxy', 'system proxy → 127.0.0.1:$port');
    } catch (e) {
      Logger.instance.error('sysproxy', 'enable failed: $e');
    }
  }

  Future<void> disable() async {
    if (!_enabled) return;
    try {
      if (Platform.isWindows) {
        if (_winPrevEnable != null) {
          await _reg(['add', _kInternet, '/v', 'ProxyEnable',
                '/t', 'REG_DWORD', '/d', _winPrevEnable!, '/f']);
        }
        if (_winPrevServer != null) {
          await _reg(['add', _kInternet, '/v', 'ProxyServer',
                '/t', 'REG_SZ', '/d', _winPrevServer!, '/f']);
        } else {
          await _reg(
              ['delete', _kInternet, '/v', 'ProxyServer', '/f']);
        }
        if (_winPrevOverride != null) {
          await _reg(['add', _kInternet, '/v', 'ProxyOverride',
                '/t', 'REG_SZ', '/d', _winPrevOverride!, '/f']);
        }
        await _refreshWinInet();
      } else if (Platform.isLinux) {
        if (await _which('gsettings')) {
          await _run(
              'gsettings', ['set', 'org.gnome.system.proxy', 'mode', 'none']);
        }
      }
      _enabled = false;
      Logger.instance.info('sysproxy', 'system proxy restored');
    } catch (e) {
      Logger.instance.error('sysproxy', 'disable failed: $e');
    }
  }

  Future<void> _winCapture() async {
    final r = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    ]);
    final out = '${r.stdout}';
    String? value(String name) {
      final m = RegExp('$name\\s+REG_(?:DWORD|SZ)\\s+(\\S+)')
          .firstMatch(out);
      return m?.group(1);
    }

    _winPrevEnable = value('ProxyEnable');
    _winPrevServer = value('ProxyServer');
    _winPrevOverride = value('ProxyOverride');
  }

  /// W8 (fixed v0.3.0): proper argv — no string splitting anywhere, so the
  /// registry path (containing a space) is a single argument.
  Future<void> _reg(List<String> args) async {
    final r = await Process.run('reg', args);
    if (r.exitCode != 0) {
      Logger.instance.warn('sysproxy', 'reg failed: ${r.stderr}');
    }
  }

  /// Observability for tests/diagnostics (audit W8): read current WinINET
  /// per-user proxy state. Values are what the registry holds right now.
  Future<Map<String, String?>> query() async {
    if (!Platform.isWindows) return const {};
    final r = await Process.run('reg', ['query', _kInternet]);
    final out = '${r.stdout}';
    String? value(String name) {
      final m = RegExp('$name\\s+REG_(?:DWORD|SZ)\\s+(\\S+)').firstMatch(out);
      return m?.group(1);
    }

    return {
      'ProxyEnable': value('ProxyEnable'),
      'ProxyServer': value('ProxyServer'),
      'ProxyOverride': value('ProxyOverride'),
    };
  }

  /// Make WinINET pick up the change without a logoff.
  Future<void> _refreshWinInet() async {
    for (final option in const ['37', '39']) {
      await Process.run(
          'rundll32', ['wininet.dll,InternetSetOption', '0', option, '0', '0']);
    }
  }

  Future<bool> _which(String exe) async {
    try {
      final r = await Process.run('which', [exe]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _run(String exe, List<String> args) async {
    try {
      await Process.run(exe, args);
    } catch (e) {
      Logger.instance.warn('sysproxy', '$exe failed: $e');
    }
  }
}
