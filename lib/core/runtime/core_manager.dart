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

/// An engine process exited — tagged with the owning engine so crash
/// recovery can rebuild the correct topology (v0.2.1 W4).
class EngineExitEvent {
  const EngineExitEvent(this.engine, this.event);
  final CoreKind engine;
  final CoreExitEvent event;
}

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

  /// Work directory of the Xray runtime (for access-log paths in tests).
  Directory get xrayWorkDir => Directory(
      '${workDir.path}${Platform.pathSeparator}xray');

  /// W4: every engine's exit stream, tagged with the owning engine —
  /// the controller routes crash recovery per engine.
  final _anyExitCtrl = StreamController<EngineExitEvent>.broadcast();
  final _exitSubs = <StreamSubscription>[];
  bool _exitWired = false;

  Stream<EngineExitEvent> get onAnyExit {
    if (!_exitWired) {
      _exitWired = true;
      _exitSubs.addAll([
        singbox.onExit.listen((e) => _anyExitCtrl.add(EngineExitEvent(CoreKind.singbox, e))),
        xray.onExit.listen((e) => _anyExitCtrl.add(EngineExitEvent(CoreKind.xray, e))),
        masterDnsVpn.onExit
            .listen((e) => _anyExitCtrl.add(EngineExitEvent(CoreKind.masterDnsVpn, e))),
        amneziaWg.onExit
            .listen((e) => _anyExitCtrl.add(EngineExitEvent(CoreKind.amneziaWg, e))),
      ]);
    }
    return _anyExitCtrl.stream;
  }

  bool _isXrayOwned(ProxyProfile p) => needsXrayUpstream(p);

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

  /// Profiles that must be executed by the Xray upstream: either the
  /// detector/user pinned Xray, or an unknown-core profile with an
  /// Xray-only transport (xhttp) — defensive pairing with
  /// `OutboundBuilders.singBoxOutbound` (v0.2.1 W2/W6).
  static bool needsXrayUpstream(ProxyProfile p) =>
      p.effectiveCore == CoreKind.xray ||
      (p.effectiveCore == CoreKind.unknown &&
          p.transport == Transport.xhttp);

  Map<String, ({String host, int port})> _socksUpstreams(
      List<ProxyProfile> all) {
    final out = <String, ({String host, int port})>{};
    for (final p in all) {
      if (!p.enabled) continue;
      if (needsXrayUpstream(p)) {
        out[p.id] = (host: '127.0.0.1', port: xray.localPort);
      }
      switch (p.effectiveCore) {
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
      case CoreKind.unknown when profile.transport == Transport.xhttp:
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
          // W5: never hand sing-box a SOCKS stub whose upstream is not
          // actually listening.
          if (!await xray.inboundHealthy()) {
            throw CoreStartError(
                'Xray SOCKS inbound is not listening after start.',
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

  /// Full start for one profile.
  /// Safe to call while an engine is already running: the previous topology
  /// is stopped first (otherwise the old process keeps the ports bound and
  /// the old selector active — found by the failover E2E test).
  ///
  /// [warpProfile] — WARP traffic chaining (v0.3.0 §8): when non-null (built
  /// via `WarpRegistrar.toProfile(account)`), the WARP WireGuard endpoint is
  /// materialized inside the front sing-box config and node outbounds dial
  /// through it per [chainWarpOutside]. The chain is real: sing-box itself
  /// dials the WireGuard handshake through the chain.
  Future<StartResult> startFor(
    ProxyProfile profile, {
    required List<ProxyProfile> all,
    required RoutingProfile routing,
    required DnsSettings dns,
    ProxyProfile? warpProfile,
    bool chainWarpOutside = true,
  }) async {
    final sw = Stopwatch()..start();
    await prepare();
    if (singbox.status == RuntimeStatus.running ||
        singbox.status == RuntimeStatus.starting) {
      await singbox.stop();
    }
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
      socksUpstreams: _socksUpstreams(all),
      warpProfile: warpProfile,
      chainWarpOutside: chainWarpOutside,
    );
    if (r.ok) {
      _restartCount = 0;
      _active = profile;
      lastStartupMs = sw.elapsedMilliseconds;
    } else {
      await _stopUpstreams();
    }
    return r;
  }

  /// Phase 5 fast switch: selector swap, no restart — but ONLY when the
  /// target profile actually carries traffic after the swap (v0.3.0 §15/§12):
  ///  * native sing-box profiles (incl. `CoreKind.unknown` non-xhttp ones —
  ///    a gap the §15 test found) always qualify;
  ///  * Xray/MDVPN-owned profiles qualify only while their daemon is
  ///    actually serving its local SOCKS endpoint (a dead stub would break
  ///    the traffic path silently).
  Future<bool> hotSwitch(
    ProxyProfile next, {
    required RoutingProfile routing,
    required DnsSettings dns,
  }) async {
    final cur = _active;
    if (singbox.status != RuntimeStatus.running) return false;
    switch (next.effectiveCore) {
      case CoreKind.singbox:
      case CoreKind.wireguardSingbox:
        break;
      case CoreKind.unknown:
        if (needsXrayUpstream(next)) return false; // stub only via xray path
        break;
      case CoreKind.xray:
        if (xray.status != RuntimeStatus.running ||
            !await xray.inboundHealthy()) {
          return false;
        }
        break;
      case CoreKind.masterDnsVpn:
        if (masterDnsVpn.status != RuntimeStatus.running ||
            !await masterDnsVpn.probe()) {
          return false;
        }
        break;
      case CoreKind.amneziaWg:
        return false; // standalone daemon, never in the front selector
    }
    if (cur != null &&
        (cur.effectiveCore == CoreKind.singbox ||
            cur.effectiveCore == CoreKind.wireguardSingbox ||
            cur.effectiveCore == CoreKind.xray ||
            cur.effectiveCore == CoreKind.masterDnsVpn ||
            cur.effectiveCore == CoreKind.unknown)) {
      return singbox.switchToProfile(next);
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

  /// Wall-clock duration of the last successful engine start (§25 metrics).
  int? lastStartupMs;

  /// Phase 26: restart-once recovery; further crashes bubble to failover.
  /// [engine] selects which process topology to rebuild: the front engine
  /// (sing-box) or the Xray/MDVPN upstream of the active profile.
  Future<bool> recoverEngine(
    CoreKind engine, {
    required List<ProxyProfile> all,
    required RoutingProfile routing,
    required DnsSettings dns,
  }) async {
    final active = _active;
    if (active == null || _restartCount >= _maxRestarts) return false;
    _restartCount++;
    Logger.instance.warn('manager',
        'recovering $engine (attempt $_restartCount)');

    if (engine == CoreKind.xray && _isXrayOwned(active)) {
      final v = await xray.validateProfile(profile: active, routing: routing);
      if (!v.ok) return false;
      if (xray.status == RuntimeStatus.running) await xray.stop();
      final r = await xray.startProfile(profile: active, routing: routing);
      if (!r.ok) return false;
      return singbox.status == RuntimeStatus.running ||
          await singbox.inboundHealthy();
    }

    // MDVPN upstream crash: rebuild only the daemon (v0.3.0 §10 restart),
    // keep the front engine and selector untouched.
    if (engine == CoreKind.masterDnsVpn && active.effectiveCore == CoreKind.masterDnsVpn) {
      if (masterDnsVpn.status == RuntimeStatus.running) {
        await masterDnsVpn.stop();
      }
      masterDnsVpn.profile = active;
      final r = await masterDnsVpn.start();
      if (!r.ok) return false;
      // Readiness is the SOCKS greeting probe — no readiness, no recovery.
      return masterDnsVpn.probe();
    }

    await singbox.stop();
    final r = await startFor(active, all: all, routing: routing, dns: dns);
    return r.ok;
  }

  /// Back-compat alias used for front-crash recovery.
  Future<bool> recoverFront({
    required List<ProxyProfile> all,
    required RoutingProfile routing,
    required DnsSettings dns,
  }) =>
      recoverEngine(CoreKind.singbox,
          all: all, routing: routing, dns: dns);

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
    for (final s in _exitSubs) {
      await s.cancel();
    }
    await _anyExitCtrl.close();
    await singbox.dispose();
    await xray.dispose();
    await amneziaWg.dispose();
    await masterDnsVpn.dispose();
  }
}
