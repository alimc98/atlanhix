import 'dart:convert';

import 'package:flutter/services.dart';

/// v0.4.3: bridge to the `:xray` Android process. Xray runs as the official
/// Android release binary shipped inside the APK (`lib/arm64-v8a/libxray_core
/// .so`, exec'd from the native-lib dir — the one location Android W^X allows
/// — NekoBox's executableSo pattern). It lives in a second process because
/// one Go runtime per process is the law and libbox owns the main one. The
/// Dart side treats it as an upstream engine: start it with an Xray config,
/// get a local SOCKS port, then the front sing-box selector dials the node
/// through that SOCKS stub (socksUpstreams).
class XrayBridge {
  XrayBridge._();
  static final XrayBridge instance = XrayBridge._();

  static const _channel = MethodChannel('dev.atlanhix/xray');

  bool _statusKnown = false;
  bool _running = false;
  int _socksPort = 0;

  /// True once the native side reports the exec'd Xray binary is present in
  /// this build (nativeLibraryDir). False = honest "Xray off" state.
  bool available = false;

  /// Boot handshake (called from main after runApp): asks the native side
  /// whether the AAR exists. Safe on desktop (MissingPluginException).
  Future<void> probe() async {
    try {
      final raw = await _channel.invokeMethod<String>('status');
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      available = j['available'] == true;
      _running = j['running'] == true;
      _socksPort = (j['socksPort'] as num?)?.toInt() ?? 0;
      _statusKnown = true;
    } on MissingPluginException {
      available = false; // desktop/test: the Xray *binary* path is used
    } catch (_) {
      available = false;
    }
  }

  bool get statusKnown => _statusKnown;
  bool get running => _running;
  int get socksPort => _socksPort;

  /// Start the :xray process with a full Xray JSON config; it must contain a
  /// socks inbound on [socksPort]. Polls status until the service reports it
  /// is running (exec + bind take a moment) or 8s elapse.
  Future<bool> start(String xrayConfigJson, int socksPort) async {
    try {
      final raw = await _channel.invokeMethod<String>(
          'start', {'config': xrayConfigJson, 'socksPort': socksPort});
      final j = raw == null ? const <String, dynamic>{} : jsonDecode(raw);
      if (j['ok'] != true) {
        _running = false;
        return false;
      }
      for (var i = 0; i < 16; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final st = await _status();
        if (st['running'] == true) {
          _running = true;
          _socksPort = (st['socksPort'] as num?)?.toInt() ?? socksPort;
          return true;
        }
      }
      _running = false;
      return false;
    } catch (_) {
      _running = false;
      return false;
    }
  }

  Future<Map<String, dynamic>> _status() async {
    final raw = await _channel.invokeMethod<String>('status');
    return raw == null
        ? const <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<String>('stop');
    } catch (_) {}
    _running = false;
    _socksPort = 0;
  }
}
