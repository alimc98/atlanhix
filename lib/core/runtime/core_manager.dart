import 'dart:async';
import 'dart:io';

import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import '../../routing/routing_models.dart';
import '../logger.dart';
import 'binary_manager.dart';
import 'core_process.dart';
import 'core_runtime.dart';
import 'external_runtimes.dart';
import 'singbox_runtime.dart';
import 'xray_runtime.dart';

/// Orchestrates every engine runtime (Phase 1).
///
/// Architecture: **sing-box is always the front engine** — it owns the mixed
/// inbound (127.0.0.1:2080), optional TUN and the selector. sing-box-runnable
/// profiles live as real outbounds; Xray / MasterDNSVPN profiles appear as
/// SOCKS stubs pointing at their local daemon ports. Switching:
///  * sing-box→sing-box: Clash API selector swap (no restart, sub-second)
///  * xray→xray: Xray process restart, then selector swap
///  * cross-family: start/stop the needed upstream, then selector swap
///  * AWG: standalone daemon (no front) — documented limitation
class CoreManager {
  CoreManager({
    required this.binaryManager,
    required this.workDir,
    this.enableTun = false,
  });

  final BinaryManager binaryManager;
  final Directory workDir;
  final bool enableTun;

  late final SingBoxRuntime singbox;
  late final XrayRuntime xray;
  late final AmneziaWgRuntime amneziaWg;
  late final MasterDnsVpnRuntime masterDnsVpn;

  bool _prepared = false;
  ProxyProfile? _active;
  int _restartCount = 0;
  static const _maxRestarts = 1; // Phase 26: never loop

  ProxyProfile? get activeProfile => _active;
  RuntimeStatus get frontStatus => singbox.status;
  SingBoxRuntime get front => singbox;

  Future<void> prepare() async {
    if (_prepared) return;
    singbox = SingBoxRuntime(
      binaryManager: binaryManager,
      workDir: Directory('${workDir.path}${Platform.pathSeparator}singbox'),
      enableTun: enableTun,
    );
    xray = XrayRuntime(
      binaryManager: binaryManager,
      workDir: Directory('${workDir.path}${Platform.pathSeparator}xray'),
    );
    amneziaWg = AmneziaWgRuntime(
      binaryManager: binaryManager,
      workDir: Directory('${workDir.path}${Platform.pathSeparator}awg'),
    );
    masterDnsVpn = MasterDnsVpnRuntime(
      binaryManager: binaryManager,
      workDir: Directory('${workDir.path}${Platform.pathSeparator}mdvpn'),
    );
    await singbox.prepare();
    await xray.prepare();
    await amneziaWg.prepare();
    await masterDnsVpn.prepare();
    _prepared = true;
  }

  /// The load sing-box must carry: every profile runnable by sing-box,
  /// WireGuard profiles as endpoints, and SOCKS stubs for upstream daemons.
  List<ProxyProfile> _singboxLoad(List<ProxyProfile> all) => all
      .where((p) => p.enabled)
      .where((p) => switch (p.effectiveCore) {
            CoreKind.singbox ||
            CoreKind.wireguardSingbox ||
            CoreKind.xray ||
            CoreKind.masterDnsVpn ||
            CoreKind.unknown =>
              true,
            CoreKind.amneziaWg => false, // standalone daemon
          })
      .toList();

  Map<String, ({String host, int port})> _socksUpstreams(
      List<ProxyProfile> all) {
    final out = <String, ({String host, int port})>{};
    for (final p in all) {
      switch (p.effectiveCore) {
        case CoreKind.xray:
          out[p.id] = (host: '127.0.0.1', port: xray.localPort);
        case CoreKind.masterDnsVpn:
          out[p.id] = (host: '127.0.0.1', port: masterDnsVpn.socksPort);
        default:
          break;
      }
    }
    return out;
  }

  Future<void> _ensureUpstream(
    ProxyProfile profile, {
    required RoutingProfile routing,
  }) async {
    switch (profile.effectiveCore) {
      case CoreKind.xray:
        if (xray.currentProfile?.id != profile.id ||
            !await xray.inboundHealthy()) {
          final v =
              await xray.validateProfile(profile: profile, routing: routing);
          if (!v.ok) {
            throw ConfigValidationError(
              'Xray rejected this configuration.',
              problems: [v.message ?? 'validation failed'],
            );
          }
          if (xray.status == RuntimeStatus.running) await xray.stop();
          final r = await xray.startProfile(profile: profile, routing: routing);
          if (!r.ok) {
            throw CoreStartError('Xray failed to start: ${r.message}',
                exitCode: null);
          }
        }
      case CoreKind.masterDnsVpn:
        masterDnsVpn.profile = profile;
        if (masterDnsVpn.status != RuntimeStatus.running ||
            !await masterDnsVpn.probe()) {
          if (masterDnsVpn.status == RuntimeStatus.running) {
            await masterDnsVpn.stop();
          }
          final r = await masterDnsVpn.start();
          if (!r.ok) {
            throw CoreStartError('MasterDNSVPN failed to start: ${r.message}',
                exitCode: null);
          }
        }
      default:
        break;
    }
  }

  /// Full start for one profile (Phases 3/4/7 pipeline).
  Future<StartResult> startFor(
    ProxyProfile profile, {
    required List<ProxyProfile> all,
    required RoutingProfile routing,
    required DnsSettings dns,
  }) async {
    await prepare();
    if (profile.effectiveCore == CoreKind.amneziaWg) {
      amneziaWg.profile = profile;
      final r = await amneziaWg.start();
      if (r.ok) _active = profile;
      return r;
    }
    await _ensureUpstream(profile, routing: routing);
    final r = await singbox.startWith(
      profiles: _singboxLoad(all),
      selectedProfileId: profile.id,
      routing: routing,
      dns: dns,
    );
    if (r.ok) {
      _restartCount = 0;
      _active = profile;
    } else {
      await _stopUpstreams();
    }
    return r;
  }

  /// Phase 5 fast switch: same-family swap via selector, no restart.
  Future<bool> hotSwitch(
    ProxyProfile next, {
    required RoutingProfile routing,
    required DnsSettings dns,
  }) async {
    final cur = _active;
    if (singbox.status != RuntimeStatus.running) return false;
    final nextCore = next.effectiveCore;
    if (nextCore == CoreKind.singbox || nextCore == CoreKind.wireguardSingbox) {
      if (cur == null ||
          cur.effectiveCore == CoreKind.singbox ||
          cur.effectiveCore == CoreKind.wireguardSingbox) {
        return singbox.switchToProfile(next);
      }
    }
    return false;
  }

  /// Phase 5 for Xray: restart only the upstream, then selector swap.
  Future<bool> restartXrayUpstream(
    ProxyProfile next, {
    required RoutingProfile routing,
    required DnsSettings dns,
  }) async {
    if (singbox.status != RuntimeStatus.running) return false;
    if (next.effectiveCore != CoreKind.xray) return false;
    try {
      await _ensureUpstream(next, routing: routing);
      return await singbox.switchToProfile(next);
    } on AppError catch (e) {
      Logger.instance
          .warn('manager', 'xray upstream switch failed: ${e.userMessage}');
      return false;
    }
  }

  void setActive(ProxyProfile p) => _active = p;

  /// Phase 26: restart-once recovery; further crashes bubble to failover.
  Future<bool> recoverFront({
    required List<ProxyProfile> all,
    required RoutingProfile routing,
    required DnsSettings dns,
  }) async {
    final active = _active;
    if (active == null || _restartCount >= _maxRestarts) return false;
    _restartCount++;
    Logger.instance
        .warn('manager', 'recovering front engine (attempt $_restartCount)');
    await singbox.stop();
    final r = await startFor(active, all: all, routing: routing, dns: dns);
    return r.ok;
  }

  Future<void> _stopUpstreams() async {
    if (xray.status == RuntimeStatus.running) await xray.stop();
    if (masterDnsVpn.status == RuntimeStatus.running) await masterDnsVpn.stop();
  }

  Future<void> stop() async {
    await _stopUpstreams();
    if (amneziaWg.status == RuntimeStatus.running) await amneziaWg.stop();
    await singbox.stop();
    _active = null;
    _restartCount = 0;
  }

  Future<void> dispose() async {
    await stop();
    await singbox.dispose();
    await xray.dispose();
    await amneziaWg.dispose();
    await masterDnsVpn.dispose();
  }
}
