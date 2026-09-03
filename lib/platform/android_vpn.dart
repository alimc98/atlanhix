import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/logger.dart';

/// v0.3.0 آ§3â€“آ§7 â€” Android VPN runtime controller.
///
/// Bridge: Dart controller â†’ platform channel (`dev.atlanhix/vpn`) â†’
/// AtlanhixVpnService â†’ VpnEngine (libbox) â†’ TUN.
///
/// The state machine (آ§5) advances ONLY on real events: the native service
/// state plus an actual connectivity probe through the tunnel before
/// `connected`. A start() that merely returns never yields connected=true.
class AndroidVpnController {
  AndroidVpnController();

  static const _channel = MethodChannel('dev.atlanhix/vpn');

  /// Full sing-box config JSON for the TUN build (generated Dart-side with
  /// enableTun=true and handed to the native engine as-is, آ§3/آ§4).
  String? configJson;

  /// آ§7 TUN resolver addresses â€” must match the generated sing-box DNS.
  List<String> dnsServers = ['1.1.1.1', '8.8.8.8'];

  /// TUN interface addresses (must match the config's tun inbound).
  String inet4Address = '172.19.0.1';
  int inet4Prefix = 30;
  String? inet6Address;
  int inet6Prefix = 126;
  List<String> routes = ['0.0.0.0/0', '::/0'];

  /// آ§6 per-app routing (persisted by the settings layer).
  List<String> includeApps = [];
  List<String> excludeApps = [];
  int mtu = 9000;

  AndroidVpnPhase phase = AndroidVpnPhase.idle;
  String? lastDetail;

  /// How many seconds to wait for the user consent dialog before giving up.
  /// Reduced in tests to keep the deny path fast.
  int permissionPollSeconds = 60;

  final _stateController = StreamController<AndroidVpnPhase>.broadcast();
  Stream<AndroidVpnPhase> get states => _stateController.stream;

  bool get isConnected => phase == AndroidVpnPhase.connected;
  bool get isBusy =>
      phase == AndroidVpnPhase.preparing ||
      phase == AndroidVpnPhase.starting ||
      phase == AndroidVpnPhase.validating ||
      phase == AndroidVpnPhase.reconnecting ||
      phase == AndroidVpnPhase.stopping;

  void _set(AndroidVpnPhase p, {String? detail}) {
    phase = p;
    if (detail != null) lastDetail = detail;
    _stateController.add(p);
    Logger.instance.info(
        'android-vpn', 'phase=${p.name}${detail != null ? ' ($detail)' : ''}');
  }

  Future<Map<String, dynamic>> _call(String method, [Object? arg]) async {
    final raw = await _channel.invokeMethod<String>(method, arg);
    return jsonDecode(raw ?? '{}') as Map<String, dynamic>;
  }

  /// Asks Android for the VPN permission. True when already granted or the
  /// user accepts the consent dialog. REQUESTING_PERMISSION is a real state.
  Future<bool> requestPermission() async {
    try {
      var resp = await _call('prepare');
      if (resp['granted'] == true) {
        _set(AndroidVpnPhase.idle, detail: 'permission granted');
        return true;
      }
      _set(AndroidVpnPhase.requestingPermission);
      // The consent dialog was launched native-side; poll prepare() until
      // the user answers (bounded).
      for (var i = 0; i < permissionPollSeconds; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        resp = await _call('prepare');
        if (resp['granted'] == true) {
          _set(AndroidVpnPhase.idle, detail: 'permission granted after consent');
          return true;
        }
      }
      _set(AndroidVpnPhase.failed, detail: 'permission not granted');
      return false;
    } on MissingPluginException {
      _set(AndroidVpnPhase.failed,
          detail: 'platform channel unavailable (not Android)');
      return false;
    } catch (e) {
      _set(AndroidVpnPhase.failed, detail: 'permission flow failed: $e');
      return false;
    }
  }

  /// آ§3 config handoff payload consumed by AtlanhixVpnService.
  Map<String, dynamic> buildHandoff() => {
        'mtu': mtu,
        'inet4Address': inet4Address,
        'inet4Prefix': inet4Prefix,
        if (inet6Address != null) 'inet6Address': inet6Address,
        if (inet6Address != null) 'inet6Prefix': inet6Prefix,
        'dns': dnsServers,
        'routes': routes,
        'includeApps': includeApps,
        'excludeApps': excludeApps,
        'configJson': configJson ?? '',
      };

  /// Connect flow: permission â†’ handoff â†’ service start â†’ native engine
  /// reaches VALIDATING (TUN fd established) â†’ REAL probe through the tunnel
  /// â†’ connected. Every failure path lands on [AndroidVpnPhase.failed].
  Future<bool> connect({
    required Future<bool> Function() probeTunnel,
    Duration startupTimeout = const Duration(seconds: 12),
  }) async {
    if (isBusy) return false;
    try {
      if (!await requestPermission()) return false;
      _set(AndroidVpnPhase.preparing);
      await _channel.invokeMethod<String>(
          'start', jsonEncode(buildHandoff()));
      _set(AndroidVpnPhase.starting);

      final deadline = DateTime.now().add(startupTimeout);
      while (DateTime.now().isBefore(deadline)) {
        final s = await _call('state');
        final native = (s['state'] as String? ?? 'IDLE').toUpperCase();
        final detail = s['detail'] as String?;
        if (detail != null && detail.isNotEmpty) lastDetail = detail;
        switch (native) {
          case 'FAILED':
            _set(AndroidVpnPhase.failed, detail: detail ?? 'engine failed');
            await stop();
            return false;
          case 'VALIDATING':
          case 'CONNECTED':
            _set(AndroidVpnPhase.validating);
            final ok = await probeTunnel().timeout(startupTimeout);
            if (ok) {
              _set(AndroidVpnPhase.connected);
              return true;
            }
            _set(AndroidVpnPhase.failed, detail: 'connectivity probe failed');
            await stop();
            return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      _set(AndroidVpnPhase.failed, detail: 'engine did not reach validating in time');
      await stop();
      return false;
    } catch (e) {
      _set(AndroidVpnPhase.failed, detail: 'connect failed: $e');
      return false;
    }
  }

  /// Clean disconnect (آ§3): stop the service and confirm STOPPED natively.
  /// When [keepFailedPhase] is set (connect-failure paths), the controller
  /// tears everything down but the phase stays `failed` so UI/diagnostics
  /// surface the reason instead of a benign `stopped`.
  bool keepFailedPhase = false;

  Future<void> stop() async {
    if (phase == AndroidVpnPhase.idle || phase == AndroidVpnPhase.stopped) {
      return;
    }
    final wasFailed = phase == AndroidVpnPhase.failed || keepFailedPhase;
    if (!wasFailed) _set(AndroidVpnPhase.stopping);
    try {
      await _channel.invokeMethod<String>('stop');
    } catch (_) {}
    for (var i = 0; i < 20; i++) {
      try {
        final s = await _call('state');
        if ((s['state'] as String? ?? '').toUpperCase() == 'STOPPED') break;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (wasFailed) {
      keepFailedPhase = false;
      _stateController.add(AndroidVpnPhase.failed);
    } else {
      _set(AndroidVpnPhase.stopped);
    }
  }

  /// آ§19 diagnostics: real native state + config handoff facts.
  Future<Map<String, dynamic>> diagnostics() async {
    try {
      final s = await _call('state');
      return {
        'platform': 'android',
        'nativeState': s['state'],
        'detail': s['detail'],
        'phase': phase.name,
        'mtu': mtu,
        'dns': dnsServers,
        'includeApps': includeApps,
        'excludeApps': excludeApps,
      };
    } catch (_) {
      return {'platform': 'android', 'nativeState': 'UNAVAILABLE'};
    }
  }

  void dispose() {
    _stateController.close();
  }
}

/// Android VPN state machine (آ§5) â€” mirrors AtlanhixVpnService.State.
enum AndroidVpnPhase {
  idle,
  requestingPermission,
  preparing,
  starting,
  validating,
  connected,
  reconnecting,
  stopping,
  stopped,
  failed,
}
