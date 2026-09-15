import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/logger.dart';

/// v0.4.1 (§2-§6) — Android VPN runtime controller.
///
/// Bridge: Dart controller → platform channel (`dev.atlanhix/vpn`) →
/// AtlanhixVpnService → VpnEngine → TUN.
///
/// The state machine (§5) advances ONLY on real events: the native service
/// state plus an actual connectivity probe through the tunnel before
/// `connected`. A start() that merely returns never yields connected=true.
class AndroidVpnController {

  /// True when running on an Android device (platform channel usable).
  bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  AndroidVpnController();

  static const _channel = MethodChannel('dev.atlanhix/vpn');

  /// Full sing-box config JSON for the TUN build (generated Dart-side with
  /// enableTun=true and handed to the native engine as-is, §3/§4).
  String? configJson;

  /// §7 TUN resolver addresses — must match the generated sing-box DNS.
  List<String> dnsServers = ['1.1.1.1', '8.8.8.8'];

  /// TUN interface addresses (must match the config's tun inbound).
  String inet4Address = '172.19.0.1';
  int inet4Prefix = 30;
  String? inet6Address;
  int inet6Prefix = 126;
  List<String> routes = ['0.0.0.0/0', '::/0'];

  /// §6 per-app routing (persisted by the settings layer).
  /// [includeApps] = only these packages use the VPN (addAllowedApplication).
  /// [excludeApps] = these packages bypass the VPN (addDisallowedApplication,
  /// i.e. Android-level DIRECT). Include wins over exclude native-side.
  List<String> includeApps = [];
  List<String> excludeApps = [];
  int mtu = 9000;

  AndroidVpnPhase phase = AndroidVpnPhase.idle;

  /// §6 structured failure classification (stable codes, no stack traces).
  String? lastErrorCode;
  String? lastDetail;

  /// How many seconds to wait for the user consent dialog before giving up.
  /// Reduced in tests to keep the deny path fast.
  int permissionPollSeconds = 60;

  /// How often the connected-state watcher polls the native service.
  Duration watcherInterval = const Duration(seconds: 2);

  final _stateController = StreamController<AndroidVpnPhase>.broadcast();
  Stream<AndroidVpnPhase> get states => _stateController.stream;

  /// v0.4.4 §user-2: the engine's real cumulative counters, mirrored from
  /// the native `state` poll (libbox writeStatus). The dashboard turns these
  /// into DOWNLOAD/UPLOAD/speed — previously the on-device path had no
  /// traffic source at all (only desktop Clash-API polling fed it), so the
  /// metrics sat at 0 forever on the phone.
  int upBytes = 0;
  int downBytes = 0;
  int connections = 0;

  /// v0.4.4 §user-5: when true the session runs engine-only (no TUN) and
  /// the OS global http_proxy points at [proxyPort].
  bool _proxyMode = false;
  bool get isProxyMode => _proxyMode;
  int proxyPort = 0;

  bool get isConnected => phase == AndroidVpnPhase.connected;
  bool get isBusy =>
      phase == AndroidVpnPhase.preparing ||
      phase == AndroidVpnPhase.starting ||
      phase == AndroidVpnPhase.validating ||
      phase == AndroidVpnPhase.reconnecting ||
      phase == AndroidVpnPhase.stopping;

  void _set(AndroidVpnPhase p, {String? detail, String? errorCode}) {
    phase = p;
    if (detail != null) lastDetail = detail;
    if (errorCode != null) lastErrorCode = errorCode;
    _stateController.add(p);
    Logger.instance.info('android-vpn',
        'phase=${p.name}${detail != null ? ' ($detail)' : ''}${errorCode != null ? ' [$errorCode]' : ''}');
  }

  Future<Map<String, dynamic>> _call(String method, [Object? arg]) async {
    final raw = await _channel.invokeMethod<String>(method, arg);
    return jsonDecode(raw ?? '{}') as Map<String, dynamic>;
  }

  /// §4: while the tunnel is up, mirror native lifecycle events (REVOKED,
  /// FAILED) into the Dart state machine. The VPN belongs to the Android
  /// service — the UI must follow reality, never assume it.
  void _startWatcher() {
    _watcher?.cancel();
    _watcher = Timer.periodic(watcherInterval, (_) async {
      try {
        final s = await _call('state');
        final native = (s['state'] as String? ?? '').toUpperCase();
        final code = s['errorCode'] as String?;
        upBytes = (s['up'] as num?)?.toInt() ?? upBytes;
        downBytes = (s['down'] as num?)?.toInt() ?? downBytes;
        connections = (s['conns'] as num?)?.toInt() ?? connections;
        switch (native) {
          case 'REVOKED':
            _set(AndroidVpnPhase.revoked,
                detail: 'VPN permission revoked by system',
                errorCode: code ?? VpnErrorCode.revoked);
            await stop();
          case 'FAILED':
            _set(AndroidVpnPhase.failed,
                detail: s['detail'] as String? ?? 'service reported failure',
                errorCode: code ?? VpnErrorCode.unknown);
          default:
            break;
        }
      } catch (_) {
        // Channel hiccup — next tick retries; never crash the watcher.
      }
    });
  }

  Timer? _watcher;

  /// Asks Android for the VPN permission (v0.4.1 §2/§3).
  ///
  /// Real flow: one `prepare()` call. When consent is needed the NATIVE side
  /// launches the dialog and holds the method reply until the user answers —
  /// so this future resolves exactly once, with the dialog outcome. Denial
  /// lands on [AndroidVpnPhase.permissionDenied]; there is NO re-launch loop
  /// (the pre-0.4.1 poll loop re-opened the dialog on every tick).
  Future<bool> requestPermission() async {
    try {
      final resp = await _call('prepare');
      if (resp['granted'] == true) {
        _set(AndroidVpnPhase.idle, detail: 'permission granted');
        return true;
      }
      if (resp['needsUserConsent'] == true) {
        // Defensive path for native layers that reply immediately and expect
        // polling. Bounded; each tick only ASKS, never re-launches more than
        // the platform does for prepare() itself.
        _set(AndroidVpnPhase.requestingPermission);
        for (var i = 0; i < permissionPollSeconds; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          final r2 = await _call('prepare');
          if (r2['granted'] == true) {
            _set(AndroidVpnPhase.idle,
                detail: 'permission granted after consent');
            return true;
          }
        }
        _set(AndroidVpnPhase.permissionDenied,
            detail: 'user did not grant VPN permission',
            errorCode: VpnErrorCode.permissionDenied);
        return false;
      }
      // Explicit denial (dialog answered with cancel, or permanently denied).
      _set(AndroidVpnPhase.permissionDenied,
          detail: 'VPN permission denied by user',
          errorCode: VpnErrorCode.permissionDenied);
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

  /// §3 config handoff payload consumed by AtlanhixVpnService.
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

  /// Connect flow (§2): permission → handoff → service start → native engine
  /// reaches VALIDATING (TUN fd established) → REAL probe through the tunnel
  /// → connected. Every failure path lands on a terminal state with a
  /// structured §6 error code. CONNECTED is impossible without a real probe.
  Future<bool> connect({
    required Future<bool> Function() probeTunnel,
    Duration startupTimeout = const Duration(seconds: 12),
    bool proxyMode = false,
  }) async {
    if (isBusy) return false;
    _proxyMode = proxyMode;
    try {
      // v0.4.4 §user-5: PROXY MODE skips the TUN entirely — no consent
      // dialog (VpnService never calls establish), the engine serves the
      // local mixed port and Android's global http_proxy routes traffic.
      if (!proxyMode && !await requestPermission()) return false;
      _set(AndroidVpnPhase.preparing);
      final generation =
          DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      await _channel.invokeMethod<String>(
          'start', jsonEncode(buildHandoff()..['generation'] = generation));
      _set(AndroidVpnPhase.starting);

      final deadline = DateTime.now().add(startupTimeout);
      var generationAcked = false;
      while (DateTime.now().isBefore(deadline)) {
        final s = await _call('state');
        final native = (s['state'] as String? ?? 'IDLE').toUpperCase();
        // Race fix (audit #3): the start intent is QUEUED on the main
        // looper — a state read before onStartCommand runs shows the
        // PREVIOUS session (CONNECTED → celebrate on a dying tunnel;
        // FAILED → our stop() queues ACTION_STOP behind our own
        // ACTION_START and kills the fresh session). The service adopts
        // this connect's generation INSIDE onStartCommand and echoes it;
        // any payload with a different generation is the previous session
        // and must be skipped. The starting/preparing mirror is the
        // accepted floor: the native side always lands on one of them.
        final echoed = s['generation'] as String?;
        if (echoed != generation) {
          final prior = native == 'IDLE' ||
              native == 'PREPARING' ||
              native == 'STARTING' ||
              (native == 'FAILED' &&
                  (s['detail'] as String? ?? '').contains('generation'));
          if (!prior) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            continue;
          }
        } else {
          generationAcked = true;
        }
        final detail = s['detail'] as String?;
        final code = s['errorCode'] as String?;
        if (detail != null && detail.isNotEmpty) lastDetail = detail;
        switch (native) {
          case 'REVOKED':
            _set(AndroidVpnPhase.revoked,
                detail: detail ?? 'revoked during startup',
                errorCode: code ?? VpnErrorCode.revoked);
            await stop();
            return false;
          case 'FAILED':
            _set(AndroidVpnPhase.failed,
                detail: detail ?? 'engine failed',
                errorCode: code ?? VpnErrorCode.engineStartFailed);
            await stop();
            return false;
          case 'VALIDATING':
          case 'CONNECTED':
            _set(AndroidVpnPhase.validating);
            final ok = await probeTunnel().timeout(startupTimeout);
            if (ok) {
              if (_proxyMode) {
                final set = await _call('setProxy', {'port': proxyPort});
                if (set['ok'] != true) {
                  _set(AndroidVpnPhase.failed,
                      detail: set['error'] as String? ??
                          'global proxy refused by Android',
                      errorCode: VpnErrorCode.unknown);
                  await stop();
                  return false;
                }
              }
              _set(AndroidVpnPhase.connected);
              _startWatcher();
              return true;
            }
            _set(AndroidVpnPhase.failed,
                detail: 'connectivity probe failed',
                errorCode: VpnErrorCode.healthCheckFailed);
            await stop();
            return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      _set(AndroidVpnPhase.failed,
          detail: 'engine did not reach validating in time',
          errorCode: VpnErrorCode.engineNotReady);
      await stop();
      return false;
    } catch (e) {
      _set(AndroidVpnPhase.failed, detail: 'connect failed: $e');
      // Device-wedge fix (pipeline audit 2026-09-15): a probe that THROWS
      // (TimeoutException — the probe budget and startup budget were the
      // same clock) skipped the teardown the `ok==false` branch does. The
      // engine kept the TUN fd, the mixed port and libbox alive; the next
      // connect died on `bind: address already in use` and every retry
      // failed until a force-restart. Always best-effort stop on failure.
      await stop();
      return false;
    }
  }

  /// Clean disconnect (§3): stop the service and confirm STOPPED natively.
  /// Terminal failure phases (failed/denied/revoked) are preserved so the UI
  /// surfaces the reason instead of a benign `stopped`.
  Future<void> stop() async {
    _watcher?.cancel();
    _watcher = null;
    if (_proxyMode) {
      _proxyMode = false;
      try {
        await _call('clearProxy');
      } catch (_) {}
    }
    if (phase == AndroidVpnPhase.idle || phase == AndroidVpnPhase.stopped) {
      return;
    }
    final wasFailed = phase == AndroidVpnPhase.failed ||
        phase == AndroidVpnPhase.permissionDenied ||
        phase == AndroidVpnPhase.revoked;
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
      _stateController.add(phase);
    } else {
      _set(AndroidVpnPhase.stopped);
    }
  }

  /// §19 diagnostics: real native state + config handoff facts.
  Future<Map<String, dynamic>> diagnostics() async {
    try {
      final s = await _call('state');
      return {
        'platform': 'android',
        'nativeState': s['state'],
        'detail': s['detail'],
        'errorCode': s['errorCode'],
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

  /// §11 — installed applications from the REAL PackageManager (native
  /// cached inventory; the picker does not rescan per frame).
  /// Returns [{package, name, system}] — icons are rendered Dart-side.
  Future<List<Map<String, dynamic>>> installedApps() async {
    try {
      final raw = await _channel.invokeMethod<String>('installedApps');
      final list = jsonDecode(raw ?? '[]') as List;
      return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
    } on MissingPluginException {
      return const [];
    } catch (e) {
      Logger.instance.warn('android-vpn', 'installedApps failed: $e');
      return const [];
    }
  }

  void dispose() {
    _watcher?.cancel();
    _stateController.close();
  }
}

/// Android VPN state machine (§5) — mirrors AtlanhixVpnService.State.
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
  permissionDenied,
  revoked,
}

/// §6 stable error codes — map 1:1 to AtlanhixVpnService companion constants.
abstract final class VpnErrorCode {
  static const permissionDenied = 'VPN_PERMISSION_DENIED';
  static const tunCreateFailed = 'TUN_CREATE_FAILED';
  static const engineStartFailed = 'ENGINE_START_FAILED';
  static const engineNotReady = 'ENGINE_NOT_READY';
  static const healthCheckFailed = 'HEALTH_CHECK_FAILED';
  static const revoked = 'VPN_REVOKED';
  static const serviceStartFailed = 'SERVICE_START_FAILED';
  static const configInvalid = 'CONFIG_INVALID';
  static const networkUnavailable = 'NETWORK_UNAVAILABLE';
  static const coreUnavailable = 'CORE_UNAVAILABLE';
  static const unknown = 'UNKNOWN';
}
