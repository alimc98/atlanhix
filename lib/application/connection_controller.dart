import 'dart:async';
import '../core/core_detector.dart';
import '../core/fragmentation/fragment_profiles.dart';
import '../core/health/latency_tester.dart';
import '../core/health/test_scheduler.dart';
import '../core/logger.dart';
import '../core/net/bootstrap_dns.dart';
import '../core/runtime/core_manager.dart';
import '../core/runtime/core_process.dart';
import '../core/runtime/core_runtime.dart';
import '../core/runtime/singbox_runtime.dart';
import '../core/scoring/node_scorer.dart';
import '../core/scoring/smart_connect.dart';
import '../chain/chain_planner.dart';
import '../domain/entities/health.dart';
import '../domain/entities/proxy_profile.dart';
import '../domain/errors/app_error.dart';
import '../routing/routing_models.dart';
import '../warp/warp_registrar.dart';
import '../data/profile_repository.dart';
import '../data/repositories.dart';
import '../platform/system_proxy.dart';
import '../settings/app_settings.dart';

/// Strict connection state machine (Phase 25).
///
/// DISCONNECTED → CONNECTING → STARTING_CORE → CORE_READY → VERIFYING
///   → CONNECTED ⇄ SWITCHING · CONNECTED ⇄ DEGRADED → RECOVERING
/// Any state → DISCONNECTING → DISCONNECTED, or ERROR.
/// Only [ConnectionController] transitions states; the UI renders them.
enum ConnectionPhase {
  disconnected,
  connecting,
  validating,
  startingCore,
  coreReady,
  verifying,
  connected,
  degraded,
  switching,
  recovering,
  disconnecting,
  error,
}

class ConnectionStateSnapshot {
  ConnectionStateSnapshot({
    this.phase = ConnectionPhase.disconnected,
    this.activeProfile,
    this.error,
    this.connectedAt,
    this.core,
    this.latencyMs,
  });

  final ConnectionPhase phase;
  final ProxyProfile? activeProfile;
  final AppError? error;
  final DateTime? connectedAt;
  final CoreKind? core;
  final int? latencyMs;

  bool get isConnected => phase == ConnectionPhase.connected;
  bool get isBusy =>
      phase == ConnectionPhase.connecting ||
      phase == ConnectionPhase.startingCore ||
      phase == ConnectionPhase.verifying ||
      phase == ConnectionPhase.switching ||
      phase == ConnectionPhase.recovering ||
      phase == ConnectionPhase.disconnecting;
}

/// Modes of exposing the tunnel to the OS (§22, §23).
enum TunnelMode { off, systemProxy, tun, managed }

/// The application-layer orchestrator, driving the real [CoreManager].
class ConnectionController {
  ConnectionController({
    required this.repository,
    required this.healthStore,
    required this.tester,
    required this.detector,
    required this.cores,
    this.warpRepo,
  }) {
    // Phase 26: react to engine crashes (front AND upstreams — v0.2.1 W4).
    cores.onAnyExit.listen(_onEngineExit);
  }

  final ProfileRepository repository;
  final HealthStore healthStore;
  final LatencyTester tester;
  final CoreDetector detector;
  final CoreManager cores;
  final WarpRepository? warpRepo;

  /// WARP traffic chaining (v0.3.0 §8). When true, the saved WARP account is
  /// materialized as a WireGuard endpoint inside the front engine config and
  /// node traffic is dialed through it. [chainWarpOutside] picks the
  /// direction: true → node → WARP → internet, false → WARP → node → internet.
  bool warpChainEnabled = false;
  bool chainWarpOutside = true;

  final _stateController =
      StreamController<ConnectionStateSnapshot>.broadcast();
  ConnectionStateSnapshot _state = ConnectionStateSnapshot();

  /// Realtime engine traffic (bytes) — Phase 24/28.
  Stream<TrafficSnapshot> get trafficStream => _trafficSubject.stream;
  final _trafficSubject = StreamController<TrafficSnapshot>.broadcast();
  Timer? _trafficTimer;

  TunnelMode tunnelMode = TunnelMode.systemProxy;
  DnsSettings dns = DnsSettings(mode: DnsMode.automatic);
  /// Desktop connect path. OPT-IN default: a rule-less profile — the user
  /// gets no routing rules until they explicitly enable routing in settings
  /// (the Android session uses RuntimeConfigBridge.routingProfile(), which
  /// carries the same default-off gate).
  RoutingProfile routing = RoutingProfile(
      id: 'routing-disabled', name: 'Routing off', rules: const []);
  SelectionStrategy strategy = SelectionStrategy.smart;
  FragmentProfile? fragmentOverride;
  ProxyChain? activeChain;

  /// v0.4.6 WIRING: the Settings → TLS-Fragment pill now reaches BOTH
  /// engines. Desktop: [ConnectionController] pushes the flag into the
  /// front sing-box runtime (tls.fragment option) before every start; the
  /// Xray path uses the Xray-native freedom-fragment form (see
  /// CoreManager._fragmentFor / XrayRuntime.fragment). Android: VpnSession
  /// performs the same push (libbox reads the generated config as-is).
  bool get tlsFragmentEnabled => _tlsFragmentEnabled;
  set tlsFragmentEnabled(bool v) {
    if (_tlsFragmentEnabled == v) return;
    _tlsFragmentEnabled = v;
    cores.front.tlsFragment = v;
  }

  bool _tlsFragmentEnabled = false;

  /// v0.4.6 §user: which fragment profile the pill uses (Conservative /
  /// Default / Aggressive). Mirrors into [CoreManager.fragmentPreset] so the
  /// next Xray start carries the user's chosen intensity, not a fixed one.
  FragmentPreset get fragmentPreset => cores.fragmentPreset;
  set fragmentPreset(FragmentPreset v) {
    if (cores.fragmentPreset == v) return;
    cores.fragmentPreset = v;
  }

  // Phase 6 failover tuning.
  int failureThreshold = 2;
  Duration monitorInterval = const Duration(seconds: 30);
  Timer? _monitorTimer;
  int _consecutiveVerifyFailures = 0;

  final NodeScorer _scorer = NodeScorer();
  final SmartConnectSelector _selector = SmartConnectSelector();

  /// Exposed for UI/tests: number of candidates currently in failure cooldown.
  int get coolingCandidateCount => _selector.coolingCount;
  void clearCandidateCooldowns() => _selector.clearCooldowns();

  ConnectionStateSnapshot get state => _state;
  Stream<ConnectionStateSnapshot> get states => _stateController.stream;

  void _setState(ConnectionStateSnapshot s) {
    _state = s;
    _stateController.add(s);
    Logger.instance.debug(
        'connection',
        'phase=${s.phase.name}'
        '${s.activeProfile != null ? ' node=${s.activeProfile!.name}' : ''}');
  }

  /// Smart Connect (v0.3.0 §14): rank → cooldown filter → limited-concurrency
  /// TCP pre-probe → try in order with full engine start + HTTP verify.
  /// A candidate is healthy only after a real probe; parsing never qualifies.
  Future<void> smartConnect() async {
    final ranked = _selector.eligible(
        repository.all, healthStore.all, strategy);
    if (ranked.isEmpty) {
      _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.error,
        error: AppError('No nodes available to connect.'),
      ));
      return;
    }
    // Pre-probe keeps the attempt budget for candidates that can actually
    // accept a TCP connection right now.
    final probed = await _selector.preprobe(ranked);
    final candidates =
        (probed.isNotEmpty ? probed.map((r) => r.$1) : ranked).take(5);
    var lastError = 'all candidates failed';
    for (final profile in candidates) {
      final ok = await connect(profile);
      if (ok) return;
      // Session cooldown so the next Smart Connect (and failover) skips it
      // until the cooldown expires — recovery is automatic on expiry.
      _selector.markFailed(profile.id);
      lastError = _state.error?.userMessage ?? lastError;
    }
    _setState(ConnectionStateSnapshot(
      phase: ConnectionPhase.error,
      error: AppError(
        'Could not establish a connection with the top candidates.',
        likelyCauses: [
          lastError,
          'Your network may be blocking the tried protocols',
        ],
      ),
    ));
  }

  /// Connects a specific profile through the real runtime (Flow A/B).
  Future<bool> connect(ProxyProfile profile) async {
    if (_state.isBusy) return false;
    try {
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.validating, activeProfile: profile));
      final decision = detector.resolve(profile);
      final problems = _validateProfile(profile);
      if (problems.isNotEmpty) {
        throw ConfigValidationError(
            'This configuration has problems.', problems: problems);
      }

      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.startingCore,
          activeProfile: profile,
          core: decision.core));
      // W3: persist the detector/user decision on the profile so the
      // CoreManager (which owns the actual traffic path) executes the
      // selected engine. Without this, the manager sees `unknown` and
      // never starts the Xray/MDVPN upstream.
      profile.core = decision.core;
      await cores.stop(); // clean slate for a new start
      // v0.4.6 §user: a fresh connect BEGINS the fragment AUTO ladder (rung
      // 0 — or the node's persisted winning rung when one exists). Fixed
      // presets are unaffected by this call.
      cores.beginAutoLadder(profile);
      // v0.4.6 DESKTOP BOOTSTRAP PIN (parity with VpnSession._connectProfile,
      // which has run this on Android since v0.4.4): resolve the node's
      // hostname OUTSIDE the tunnel BEFORE any engine owns the network and
      // pin the verified public IPv4 into the config. Without it, Xray
      // resolves the node's own domain THROUGH the tunnel it serves and
      // races its poisoned/serial DNS (the 1.1.1.1+localhost round-robin) —
      // the exact desktop failure mode the Android path already fixed.
      // SNI/Host keep the hostname (profile.copyWith), so TLS/Reality and
      // Host headers are byte-for-byte unchanged.
      profile = await _withBootstrappedAddress(profile);
      // WARP traffic chaining (§8): materialize the saved WARP account as a
      // WireGuard endpoint and dial node traffic through it. If the account
      // is missing/incomplete the chain is silently skipped — chaining is a
      // per-connection modifier, not a hard requirement.
      ProxyProfile? warpProfile;
      if (warpChainEnabled) {
        final acct = warpRepo?.account;
        if (acct != null &&
            acct.privateKey.isNotEmpty &&
            acct.peerPublicKey.isNotEmpty) {
          warpProfile = WarpRegistrar.profileFor(acct);
          Logger.instance.info('connection',
              'WARP chain enabled (outside=$chainWarpOutside)');
        }
      }
      final start = await cores.startFor(
        profile,
        all: repository.all,
        routing: routing,
        dns: dns,
        warpProfile: warpProfile,
        chainWarpOutside: chainWarpOutside,
      );
      if (!start.ok) {
        throw CoreStartError(
          _friendlyStartFailure(start),
          exitCode: null,
        );
      }

      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.coreReady,
          activeProfile: profile,
          core: decision.core));

      // Phase 25/6: verify real connectivity through the running tunnel.
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.verifying,
          activeProfile: profile,
          core: decision.core));
      final probe = await tester.testHttpViaSocksProxy(
        '127.0.0.1',
        cores.front.mixedPort,
        'https://www.gstatic.com/generate_204',
        timeout: const Duration(seconds: 6),
      );
      // v0.4.6 §user-3: the FIRST rung's probe is a real attempt too —
      // otherwise every rung the ladder started with would show a dishonest
      // 0-attempt (or worse: an untouched 100%) in the per-sub stats.
      if (cores.tlsFragmentEnabled &&
          cores.fragmentPreset == FragmentPreset.auto &&
          FragmentationEngine().isEligible(profile)) {
        final firstRung = cores.currentAutoFragment;
        if (firstRung != null) {
          await cores.fragmentLadder?.recordRungAttempt(
              profile.subscriptionId, firstRung,
              won: probe.ok);
        }
      }
      // v0.4.6 §user: AUTO ladder escalation loop. With the fragment pill on
      // and fragmentPreset == auto, a failed probe retries the engine start
      // with the NEXT rung (conservative → default → aggressive) BEFORE
      // giving up on this node; a probe that finally passes records the
      // winning rung per node id, so the next connect to this node starts
      // there directly.
      if (!probe.ok && cores.fragmentPreset == FragmentPreset.auto) {
        final attempt = await _retryWithEscalatedFragment(
            profile, decision.core, warpProfile);
        if (attempt != null) {
          _consecutiveVerifyFailures = 0;
          _applyTunnelMode();
          _startMonitor(profile);
          _startTrafficPolling();
          healthStore.record(HealthRecord(
            profileId: profile.id,
            at: DateTime.now(),
            ok: true,
            latencyMs: attempt.latencyMs,
          ));
          _setState(ConnectionStateSnapshot(
            phase: ConnectionPhase.connected,
            activeProfile: profile,
            connectedAt: DateTime.now(),
            core: decision.core,
            latencyMs: attempt.latencyMs,
          ));
          return true;
        }
      }
      if (!probe.ok) {
        healthStore.record(HealthRecord(
          profileId: profile.id,
          at: DateTime.now(),
          ok: false,
          errorKind: probe.errorKind,
        ));
        final causes = <String>[
          if (probe.detail != null && probe.detail!.trim().isNotEmpty)
            'probe: ${Logger.redact(probe.detail!)}',
        ];
        causes.addAll(_engineFailureCauses(profile));
        await _teardown();
        throw ProbeError(
          'The node did not respond through the tunnel.',
          kind: probe.errorKind,
          likelyCauses: causes,
        );
      }
      _consecutiveVerifyFailures = 0;

      _applyTunnelMode();
      _startMonitor(profile);
      _startTrafficPolling();

      healthStore.record(HealthRecord(
        profileId: profile.id,
        at: DateTime.now(),
        ok: true,
        latencyMs: probe.latencyMs,
      ));
      _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.connected,
        activeProfile: profile,
        connectedAt: DateTime.now(),
        core: decision.core,
        latencyMs: probe.latencyMs,
      ));
      return true;
    } on AppError catch (e) {
      Logger.instance.error('connection', e.userMessage);
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.error, activeProfile: profile, error: e));
      await _teardown();
      return false;
    } catch (e) {
      Logger.instance.error('connection', e.toString());
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.error,
          activeProfile: profile,
          error: AppError('Unexpected error while connecting.', raw: e)));
      await _teardown();
      return false;
    }
  }

  String _friendlyStartFailure(StartResult r) => switch (r.status) {
        StartStatus.binaryMissing =>
          'The engine for this node is not installed. See Settings → Cores.',
        StartStatus.configInvalid => r.message ?? 'configuration invalid',
        StartStatus.portConflict =>
          'A local port needed by the engine is already in use.',
        _ => r.message ?? 'engine failed to start',
      };

  /// v0.4.6 §user: WHY did the tunnel fail? Builds the engine-side likelyCauses
  /// for a failed probe: the active engine's redacted stderr tail (dial
  /// refused, resolve timeout, TLS reset, "invalid request from"...) plus
  /// the upstream's last exit reason when it crashed. The sing-box front is
  /// ALWAYS probed (it owns the inbound the probe dials); for Xray-owned
  /// nodes the Xray upstream tail is added too — that's where the real
  /// resolve/TLS failure lives.
  List<String> _engineFailureCauses(ProxyProfile profile) {
    final causes = <String>[];
    final frontTail = cores.engineStderrTail(CoreKind.singbox);
    if (frontTail.isNotEmpty) causes.add('sing-box: $frontTail');
    if (profile.effectiveCore == CoreKind.xray) {
      final xrayTail = cores.engineStderrTail(CoreKind.xray);
      if (xrayTail.isNotEmpty) causes.add('xray: $xrayTail');
    }
    return causes;
  }

  /// v0.4.6 §user — the fragment AUTO escalation ladder (desktop).
  ///
  /// Called after a failed tunnel probe with fragmentPreset == auto. Climbs
  /// [CoreManager.advanceAutoLadder] rung by rung: each step restarts the
  /// engines with the NEXT fragment profile, re-probes, and on success
  /// (a) records the winning rung in the per-node ladder cache and (b)
  /// returns the probe result so [connect] completes normally. Exhausted
  /// ladder (or fragment off / ineligible node) → null, i.e. "no escalation
  /// helped" — the caller falls through to the honest ProbeError.
  Future<ProbeResult?> _retryWithEscalatedFragment(
    ProxyProfile profile,
    CoreKind core,
    ProxyProfile? warpProfile,
  ) async {
    if (!cores.tlsFragmentEnabled) return null;
    if (!FragmentationEngine().isEligible(profile)) return null;
    Logger.instance.info('connection',
        'FRAGMENT_AUTO probe failed — climbing the ladder');
    while (cores.advanceAutoLadder()) {
      final rung = cores.currentAutoFragment;
      Logger.instance.info('connection',
          'FRAGMENT_AUTO retrying with next rung${rung != null ? ' (${rung.id})' : ''}');
      try {
        await cores.stop();
        final start = await cores.startFor(
          profile,
          all: repository.all,
          routing: routing,
          dns: dns,
          warpProfile: warpProfile,
          chainWarpOutside: chainWarpOutside,
        );
        if (!start.ok) {
          Logger.instance.warn('connection',
              'FRAGMENT_AUTO rung start failed: ${_friendlyStartFailure(start)}');
          continue; // try the next rung
        }
        final probe = await tester.testHttpViaSocksProxy(
          '127.0.0.1',
          cores.front.mixedPort,
          'https://www.gstatic.com/generate_204',
          timeout: const Duration(seconds: 6),
        );
        // v0.4.6 §user-3: every real probe is an attempt — pass or fail.
        if (rung != null) {
          await cores.fragmentLadder?.recordRungAttempt(
              profile.subscriptionId, rung,
              won: probe.ok);
        }
        if (probe.ok) {
          if (rung != null) {
            await cores.fragmentLadder?.recordWinner(profile.id, rung);
            // v0.4.6 §user-2: promote the proven rung to the subscription-
            // level suggestion, so sibling nodes START there (still safe:
            // they wrap through every rung if it does not fit them).
            await cores.fragmentLadder?.recordSuggestion(
                profile.subscriptionId, rung);
          }
          Logger.instance.info('connection',
              'FRAGMENT_AUTO won at rung ${rung?.id ?? '?'} (redacted node id)');
          return probe;
        }
        Logger.instance.warn('connection',
            'FRAGMENT_AUTO rung did not answer the probe');
      } on AppError catch (e) {
        Logger.instance.warn('connection',
            'FRAGMENT_AUTO rung errored: ${e.userMessage}');
      }
    }
    return null;
  }

  /// v0.4.6 desktop parity of VpnSession._withBootstrappedAddress: resolve
  /// [profile]'s hostname OUTSIDE the tunnel (clean resolvers + sinkhole
  /// filter, see BootstrapResolver) and return a profile whose `server` is
  /// the verified public IPv4. SNI/server_name and HTTP Host keep the
  /// hostname so TLS, Reality and CDN routing are byte-for-byte unchanged.
  /// Failures leave the hostname as-is — the clean-DNS pair in the Xray
  /// config remains the fallback, never a hard dependency.
  Future<ProxyProfile> _withBootstrappedAddress(ProxyProfile profile) async {
    final host = profile.server.trim();
    if (host.isEmpty || BootstrapResolver.isPublicV4(host)) return profile;
    String? ip;
    try {
      ip = await BootstrapResolver.instance.addressFor(profile);
    } catch (_) {
      ip = null; // bootstrap DNS must never block a connect
    }
    if (ip == null || ip == host) return profile;
    Logger.instance.info('connection', 'BOOT host pinned (redacted)');
    return profile.copyWith(
      server: ip,
      sni: profile.sni ?? host,
      host: profile.host ?? host,
    );
  }

  List<String> _validateProfile(ProxyProfile p) {
    final problems = <String>[];
    if (p.server.isEmpty) problems.add('Server address is empty');
    if (p.port <= 0 || p.port > 65535) {
      problems.add('Port must be between 1 and 65535');
    }
    switch (p.protocol) {
      case ProxyProtocol.vmess:
      case ProxyProtocol.vless:
        if ((p.uuid ?? '').isEmpty) problems.add('UUID/password is missing');
      case ProxyProtocol.trojan:
      case ProxyProtocol.hysteria2:
        if ((p.password ?? '').isEmpty) {
          problems.add('Password is missing');
        }
      case ProxyProtocol.shadowsocks:
        if ((p.ssMethod ?? '').isEmpty || (p.password ?? '').isEmpty) {
          problems.add('Method and password are required');
        }
      default:
        break;
    }
    if (p.security == Security.reality &&
        (p.realityPublicKey ?? '').isEmpty) {
      problems.add('Reality public key is missing');
    }
    return problems;
  }

  void _applyTunnelMode() {
    switch (tunnelMode) {
      case TunnelMode.systemProxy:
      case TunnelMode.managed:
        SystemProxyController.instance.enable(port: cores.front.mixedPort);
      case TunnelMode.tun:
      case TunnelMode.off:
        break;
    }
  }

  void _removeTunnelMode() {
    switch (tunnelMode) {
      case TunnelMode.systemProxy:
      case TunnelMode.managed:
        SystemProxyController.instance.disable();
      case TunnelMode.tun:
      case TunnelMode.off:
        break;
    }
  }

  /// Phase 5: switch with hot paths. Order:
  ///  1. same-family sing-box → selector swap (no restart)
  ///  2. xray→xray → restart upstream only, then selector swap
  ///  3. fallback → full connect cycle
  Future<bool> switchTo(ProxyProfile next) async {
    final current = _state.activeProfile;
    if (current == null || !_state.isConnected) return connect(next);
    _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.switching, activeProfile: next));
    try {
      final hot = await cores.hotSwitch(next, routing: routing, dns: dns);
      if (hot) {
        final ok = await _verifyActive(next);
        if (ok) return true;
      }
      if (next.effectiveCore == CoreKind.xray) {
        final xr =
            await cores.restartXrayUpstream(next, routing: routing, dns: dns);
        if (xr) {
          final ok = await _verifyActive(next, core: CoreKind.xray);
          if (ok) return true;
        }
      }
      // v0.4.6: leave the busy `switching` phase before the fallback full
      // connect — connect() refuses to run while busy, so this documented
      // path-3 fallback was DEAD CODE: every failed hot switch silently
      // stayed on the old node. Restoring the pre-switch snapshot first is
      // honest (the old node IS still serving) and lets connect() proceed;
      // its own error path now surfaces the engine stderr tails.
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.connected,
          activeProfile: current,
          connectedAt: _state.connectedAt));
      return await connect(next);
    } finally {
      if (_state.phase == ConnectionPhase.switching) {
        // v0.4.6: carry the failure cause into the restored snapshot so the
        // UI's last-error view keeps WHY the switch failed.
        _setState(ConnectionStateSnapshot(
            phase: ConnectionPhase.connected,
            activeProfile: current,
            connectedAt: _state.connectedAt,
            error: _state.error));
      }
    }
  }

  Future<bool> _verifyActive(ProxyProfile profile, {CoreKind? core}) async {
    final probe = await tester.testHttpViaSocksProxy(
      '127.0.0.1',
      cores.front.mixedPort,
      'https://www.gstatic.com/generate_204',
      timeout: const Duration(seconds: 6),
    );
    if (!probe.ok) {
      _setState(ConnectionStateSnapshot(
        phase: _state.phase,
        activeProfile: profile,
        connectedAt: _state.connectedAt,
        error: AppError(
          'The node did not respond through the tunnel.',
          likelyCauses: [
            if (probe.detail != null && probe.detail!.trim().isNotEmpty)
              'probe: ${Logger.redact(probe.detail!)}',
            ..._engineFailureCauses(profile),
          ],
        ),
      ));
      return false;
    }
    _consecutiveVerifyFailures = 0;
    cores.setActive(profile);
    healthStore.record(HealthRecord(
        profileId: profile.id,
        at: DateTime.now(),
        ok: true,
        latencyMs: probe.latencyMs));
    _setState(ConnectionStateSnapshot(
      phase: ConnectionPhase.connected,
      activeProfile: profile,
      connectedAt: _state.connectedAt,
      core: core ?? profile.effectiveCore,
      latencyMs: probe.latencyMs,
    ));
    return true;
  }

  Future<void> disconnect() async {
    _monitorTimer?.cancel();
    _trafficTimer?.cancel();
    _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.disconnecting,
        activeProfile: _state.activeProfile));
    await _teardown();
    _setState(ConnectionStateSnapshot(phase: ConnectionPhase.disconnected));
  }

  Future<void> _teardown() async {
    _monitorTimer?.cancel();
    _trafficTimer?.cancel();
    _removeTunnelMode();
    await cores.stop();
  }

  // ------------------------------------------------------------ Phase 6:
  // active-node monitoring + real failover.

  void _startMonitor(ProxyProfile profile) {
    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(monitorInterval, (_) async {
      if (_state.phase != ConnectionPhase.connected &&
          _state.phase != ConnectionPhase.degraded) {
        return;
      }
      final probe = await tester.testHttpViaSocksProxy(
          '127.0.0.1', cores.front.mixedPort,
          'https://www.gstatic.com/generate_204',
          timeout: const Duration(seconds: 6));
      if (probe.ok) {
        _consecutiveVerifyFailures = 0;
        healthStore.record(HealthRecord(
            profileId: profile.id,
            at: DateTime.now(),
            ok: true,
            latencyMs: probe.latencyMs));
        if (_state.phase == ConnectionPhase.degraded) {
          _setState(ConnectionStateSnapshot(
              phase: ConnectionPhase.connected,
              activeProfile: _state.activeProfile,
              connectedAt: _state.connectedAt,
              latencyMs: probe.latencyMs));
        }
        return;
      }
      _consecutiveVerifyFailures++;
      healthStore.record(HealthRecord(
          profileId: profile.id,
          at: DateTime.now(),
          ok: false,
          errorKind: probe.errorKind));
      Logger.instance.warn('failover',
          'probe failed ($_consecutiveVerifyFailures/$failureThreshold)');
      if (_consecutiveVerifyFailures >= failureThreshold) {
        await failoverFrom(profile);
      } else {
        // v0.4.6: carry the engine tail into the degraded snapshot so the
        // user sees WHY the tunnel is degrading before failover fires.
        _setState(ConnectionStateSnapshot(
            phase: ConnectionPhase.degraded,
            activeProfile: profile,
            connectedAt: _state.connectedAt,
            error: AppError(
              'The connection is degrading.',
              likelyCauses: [
                if (probe.detail != null && probe.detail!.trim().isNotEmpty)
                  'probe: ${Logger.redact(probe.detail!)}',
                ..._engineFailureCauses(profile),
              ],
            )));
      }
    });
  }

  /// Phase 6 failover: best healthy candidate → connect → verify,
  /// walking down the ranking. Bounded at 4 candidates.
  Future<void> failoverFrom(ProxyProfile failed) async {
    if (_state.phase == ConnectionPhase.recovering) return;
    _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.recovering, activeProfile: failed));
    final ranked = _scorer.rank(repository.all, healthStore.all, strategy);
    final candidates = ranked
        .map((r) => r.$1)
        .where((p) => p.id != failed.id)
        .take(4)
        .toList();
    for (final candidate in candidates) {
      Logger.instance.info('failover', 'trying candidate: ${candidate.name}');
      final ok = await connect(candidate);
      if (ok) {
        Logger.instance.info('failover', 'failover succeeded → ${candidate.name}');
        return;
      }
    }
    _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.error,
        activeProfile: failed,
        error: AppError(
          'Automatic failover could not restore the connection.',
          likelyCauses: [
            'All alternative nodes are unreachable',
            'Check your base network connection',
          ],
        )));
  }

  // ------------------------------------------------------------ Phase 26:
  // crash recovery: restart once, then failover. Routes per crashing engine.

  void _onEngineExit(EngineExitEvent e) {
    if (e.event.kind == CoreExitKind.clean) return;
    Logger.instance.error('connection',
        '${e.engine.name} crashed: ${e.event.kind.name} (${e.event.stderrTail})');
    final active = _state.activeProfile;
    if (active == null) return;
    if (_state.phase != ConnectionPhase.connected &&
        _state.phase != ConnectionPhase.degraded) {
      return;
    }
    unawaited(() async {
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.recovering, activeProfile: active));

      // Upstream crash (Xray/MDVPN): rebuild only the upstream, keep the
      // front engine and selector untouched.
      if (e.engine == CoreKind.xray || e.engine == CoreKind.masterDnsVpn) {
        final recovered = await cores.recoverEngine(
            e.engine,
            all: repository.all,
            routing: routing,
            dns: dns);
        if (recovered) {
          final ok = await _verifyActive(active,
              core: active.effectiveCore);
          if (ok) return;
        }
        await failoverFrom(active);
        return;
      }

      // Front engine crash: full front rebuild.
      final recovered = await cores
          .recoverFront(all: repository.all, routing: routing, dns: dns);
      if (recovered) {
        final probe = await tester.testHttpViaSocksProxy(
            '127.0.0.1', cores.front.mixedPort,
            'https://www.gstatic.com/generate_204',
            timeout: const Duration(seconds: 6));
        if (probe.ok) {
          _setState(ConnectionStateSnapshot(
              phase: ConnectionPhase.connected,
              activeProfile: active,
              connectedAt: DateTime.now()));
          return;
        }
      }
      await failoverFrom(active);
    }());
  }

  // ------------------------------------------------------------ Phase 24/28:
  // real engine traffic stream.

  void _startTrafficPolling() {
    _trafficTimer?.cancel();
    _trafficTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final t = cores.front.traffic;
      if (t != null && !_trafficSubject.isClosed) {
        _trafficSubject.add(t);
      }
    });
  }

  void dispose() {
    _monitorTimer?.cancel();
    _trafficTimer?.cancel();
    _stateController.close();
    _trafficSubject.close();
  }
}
