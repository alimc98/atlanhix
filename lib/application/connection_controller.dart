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
    AppSettings? settings,
  }) : _settings = settings {
    // Phase 26: react to engine crashes (front AND upstreams — v0.2.1 W4).
    cores.onAnyExit.listen(_onEngineExit);
  }

  /// v0.5.3 §mihomo: the engine preference (Settings → Engine) feeds the
  /// detector; optional so existing test constructors keep compiling.
  final AppSettings? _settings;

  /// v0.5.6 §connect-fix: the URL the tunnel-VERIFICATION probe fetches.
  ///
  /// BUG (user report: "وقتی کانکت میزنی فقط میچرخه و وصل نمیشه، به هیچ
  /// کانفیگی وصل نمیشه" — connect spins forever, NO config ever connects):
  /// every verification call was hardcoded to
  /// `https://www.gstatic.com/generate_204` — 5 sites here plus the Android
  /// one in vpn_session.dart. That URL is Google-hosted, and the app's
  /// whole audience is a filtered network where it is routinely blocked or
  /// intercepted. When the probe target is unreachable, `testHttpViaSocksProxy`
  /// returns ok=false for a node whose tunnel is actually PERFECT — and the
  /// connect path then throws ProbeError and tears the tunnel down. The
  /// symptom is identical for every config, which is exactly what was
  /// reported: the tunnel comes up, the probe fails on an unreachable
  /// canary, the session is destroyed.
  ///
  /// The fix is to honour the user's Settings → Delay test URL (which
  /// already exists and already drives the node-list tester and Smart
  /// Switch — so a user who set a reachable URL was still failed here),
  /// and to fall back through several independent canaries instead of
  /// trusting one.
  String get _probeUrl =>
      _settings?.effectiveDelayTestUrl ??
      AppSettings.defaultDelayTestUrl;

  /// Canaries tried, in order, when verifying a tunnel. A 204 from ANY of
  /// them proves the tunnel carries real traffic. Deliberately spread
  /// across providers and networks so one blocked host cannot fail every
  /// node at once. Public because the Android session verifies through the
  /// same list.
  static const probeFallbacks = <String>[
    // Cloudflare over PLAIN http (v0.5.9 §ping-fix): no in-tunnel TLS
    // handshake → a fast, decisive second opinion; the carrier cannot
    // hijack it because the fetch happens at the tunnel's foreign exit.
    'http://cp.cloudflare.com/generate_204',
    // Cloudflare https — same provider, full-TLS variant.
    'https://cp.cloudflare.com/generate_204',
    // gstatic: keep LAST. It is the historical default and works on many
    // networks, but it is the one most likely to be blocked, so it must
    // never be the only canary.
    'https://www.gstatic.com/generate_204',
  ];

  /// Verification probe with fallback. v0.6.0 §first-connect-fix (desktop
  /// parity with VpnSession's probeTunnel): the canaries used to run SERIAL
  /// — 4 × 6 s = 24 s worst case for a cold engine (or a node whose upstream
  /// takes a moment to dial) before the verdict. They now race IN PARALLEL:
  /// the worst-case round costs the SLOWEST canary (6 s), the first success
  /// still wins, and the error the user sees keeps the last real failure.
  /// v0.6.4 §mihomo: the mixed port of the engine that actually serves the
  /// CURRENT session. A standalone mihomo session listens on ITS OWN port
  /// (2081) and runs no sing-box front at all — probing/enabling the front's
  /// 2080 in that state failed every verify/monitor round on a healthy
  /// tunnel (desktop mihomo was effectively unusable before this).
  ///
  /// [core] overrides the guess (used by the fragment-ladder retry where
  /// the state snapshot has not been updated yet).
  int mixedPortFor(CoreKind? core) {
    final effective = core ?? _state.core ?? _state.activeProfile?.effectiveCore;
    if (effective == CoreKind.mihomo &&
        cores.mihomo.status == RuntimeStatus.running) {
      return cores.mihomo.mixedPort;
    }
    return cores.front.mixedPort;
  }

  Future<ProbeResult> _probeTunnel(String host, int port,
      {Duration? timeout}) async {
    final effective = timeout ?? const Duration(seconds: 6);
    final urls = [_probeUrl, ...probeFallbacks];
    final results = await Future.wait([
      for (final url in urls)
        tester
            .testHttpViaSocksProxy(host, port, url, timeout: effective)
            .then((r) => MapEntry(url, r)),
    ]);
    for (final e in results) {
      if (e.value.ok) {
        if (e.key != _probeUrl) {
          Logger.instance.info('connection',
              'tunnel probe: primary canary failed, ${e.key} succeeded');
        }
        return e.value;
      }
    }
    return results.last.value;
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

  /// v0.6.2 §stop-fix: run token of the connect funnel. A new connect (or a
  /// disconnect) bumps it; every await boundary re-checks it, so a superseded
  /// run leaves QUIETLY — no state write, no engine start, no teardown. This
  /// is the desktop twin of the Android wedge the user reported: a stop or a
  /// switch mid-connect used to race the in-flight run (which then repainted
  /// `connected`/`error` over the user's stop) and, while busy, every new
  /// request was silently dropped by `if (_state.isBusy) return false`.
  int _runId = 0;
  bool _runAlive(int run) => run == _runId;

  /// v0.6.2 §stop-fix: cancellable CANDIDATE WALKS (Smart Connect's ranked
  /// list, crash failover). Before this, stopping mid-walk only ended the
  /// current attempt — the loop moved on to the next candidate and dialed it
  /// a moment later, so the app reconnected itself right after a Stop.
  int _walkSeq = 0;

  // Phase 6 failover tuning.
  int failureThreshold = 2;
  Duration monitorInterval = const Duration(seconds: 30);
  Timer? _monitorTimer;
  ProxyProfile? _monitorProfile;
  bool _monitorForeground = true;

  /// v0.6.3 §battery: foreground/background cadence for the tunnel monitor.
  /// Foreground the verify probe runs at [monitorInterval] (30 s); when the
  /// app is hidden a dead tunnel matters far less than the CPU wake, so the
  /// cadence stretches to 2 minutes — the same v0.5.0 discipline the native
  /// watcher already gets (2 s → 15 s). main.dart flips this on lifecycle.
  void setMonitorCadence({required bool foreground}) {
    if (_monitorForeground == foreground) return;
    _monitorForeground = foreground;
    final p = _monitorProfile;
    // Restart a RUNNING monitor so the new cadence applies immediately.
    if (p != null && _monitorTimer != null) _startMonitor(p);
  }

  Duration get _monitorInterval =>
      _monitorForeground ? monitorInterval : const Duration(minutes: 2);
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
    // v0.6.2 §stop-fix: this walk over candidates is cancellable — a Stop or
    // a newer request bumps [_walkSeq] and the loop stops before dialing the
    // next node.
    final seq = ++_walkSeq;
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
      if (seq != _walkSeq) return;
      final before = _runId;
      final ok = await connect(profile);
      if (seq != _walkSeq) return;
      if (ok) return;
      // A NEWER connect (a tap elsewhere) claimed the run while this attempt
      // ran — the walk must not fight it for the tunnel.
      if (_runId != before + 1) return;
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
  ///
  /// v0.6.2 §stop-fix: every connect claims a RUN TOKEN ([_runId]) and every
  /// await boundary below re-checks it. A superseded run leaves quietly, so
  /// a stop or a node switch is FINAL instead of racing the in-flight flow.
  /// (The old `if (_state.isBusy) return false;` gate meant a node tap during
  /// a connect was silently dropped — the desktop half of "موقعی که توی
  /// کانکتینگ هست نمیشه ... یه کانفیگ دیگه رو کانکت کرد".)
  Future<bool> connect(ProxyProfile profile) async {
    final run = ++_runId;
    try {
      if (!_runAlive(run)) return false;
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.validating, activeProfile: profile));
      // v0.5.3 §mihomo: the app-level engine choice reaches detection —
      // `mihomo` steers mihomo-runnable nodes to the standalone engine.
      final decision = detector.resolve(
          profile,
          preference: _settings?.corePreference ?? CorePreference.auto);
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
      // v0.6.2 §stop-fix: the await above is a real cancellation window (the
      // stop may have landed while the previous engine was shutting down).
      if (!_runAlive(run)) return false;
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
      // v0.6.2 §stop-fix: a bootstrap DNS resolve can take seconds — never
      // boot an engine for a run the user already cancelled.
      if (!_runAlive(run)) return false;
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
      if (!_runAlive(run)) return false;
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
      final probe = await _probeTunnel(
          '127.0.0.1', mixedPortFor(decision.core));
      // v0.6.2 §stop-fix: the probe can outlive a stop (its canaries are real
      // HTTP requests). A cancelled run publishes nothing.
      if (!_runAlive(run)) return false;
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
            profile, decision.core, warpProfile, run);
        if (!_runAlive(run)) return false;
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
        // v0.6.2 §stop-fix: a superseded run must not tear the successor's
        // engine down on its way out.
        if (!_runAlive(run)) return false;
        await _teardown();
        if (!_runAlive(run)) return false;
        throw ProbeError(
          'The node did not respond through the tunnel.',
          kind: probe.errorKind,
          likelyCauses: causes,
        );
      }
      _consecutiveVerifyFailures = 0;

      // v0.6.2 §stop-fix: never celebrate a tunnel the user just cancelled.
      if (!_runAlive(run)) return false;
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
      // v0.6.2 §stop-fix: a superseded run reports nothing and tears nothing
      // down — its verdict belongs to the successor (or the stop).
      if (!_runAlive(run)) return false;
      Logger.instance.error('connection', e.userMessage);
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.error, activeProfile: profile, error: e));
      await _teardown();
      return false;
    } catch (e) {
      if (!_runAlive(run)) return false;
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
    // v0.6.4 §mihomo: on a standalone mihomo session the sing-box front is
    // NOT running — its stale tail would mislead. Report the engine that
    // actually serves this session.
    if (profile.effectiveCore == CoreKind.mihomo ||
        _state.core == CoreKind.mihomo) {
      final mihomoTail = cores.engineStderrTail(CoreKind.mihomo);
      if (mihomoTail.isNotEmpty) causes.add('mihomo: $mihomoTail');
      return causes;
    }
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
    int run,
  ) async {
    if (!cores.tlsFragmentEnabled) return null;
    if (!FragmentationEngine().isEligible(profile)) return null;
    Logger.instance.info('connection',
        'FRAGMENT_AUTO probe failed — climbing the ladder');
    while (cores.advanceAutoLadder()) {
      // v0.6.2 §stop-fix: the ladder restarts real engines — a cancelled run
      // must not keep climbing it.
      if (!_runAlive(run)) return null;
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
        final probe =
            await _probeTunnel('127.0.0.1', mixedPortFor(core));
        if (!_runAlive(run)) return null;
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
        SystemProxyController.instance.enable(port: mixedPortFor(null));
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
    // v0.6.2 §stop-fix: a hot switch is a cancellable walk too — a Stop
    // during its verification probe must win instead of being repainted into
    // `connected` by the swap that was still in flight.
    final seq = ++_walkSeq;
    _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.switching, activeProfile: next));
    try {
      if (seq != _walkSeq) return false;
      final hot = await cores.hotSwitch(next, routing: routing, dns: dns);
      if (seq != _walkSeq) return false;
      if (hot) {
        final ok = await _verifyActive(next);
        if (seq != _walkSeq) return false;
        if (ok) return true;
      }
      if (next.effectiveCore == CoreKind.xray) {
        final xr =
            await cores.restartXrayUpstream(next, routing: routing, dns: dns);
        if (seq != _walkSeq) return false;
        if (xr) {
          final ok = await _verifyActive(next, core: CoreKind.xray);
          if (seq != _walkSeq) return false;
          if (ok) return true;
        }
      }
      if (seq != _walkSeq) return false;
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
      // v0.6.2 §stop-fix: a superseded switch keeps its hands off the UI —
      // the stop (or the newer walk) owns the phase now.
      if (seq == _walkSeq && _state.phase == ConnectionPhase.switching) {
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
    // v0.5.6 §connect-fix: canary fallback (see _probeTunnel).
    final probe =
        await _probeTunnel('127.0.0.1', mixedPortFor(core ?? profile.effectiveCore));
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
    // v0.6.2 §stop-fix: a stop SUPERSEDES everything in flight FIRST — the
    // connect run (its next await boundary exits quietly) and any candidate
    // walk (Smart Connect / failover stop before the next node). Without
    // this the run kept going: its probe could finish after the teardown and
    // publish `connected`/`error` over the user's Stop, and the walk dialed
    // the next candidate right after.
    _runId++;
    _walkSeq++;
    final me = _runId;
    _monitorTimer?.cancel();
    _monitorTimer = null;
    _monitorProfile = null;
    _trafficTimer?.cancel();
    _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.disconnecting,
        activeProfile: _state.activeProfile));
    await _teardown();
    // A connect that started during the teardown owns the UI now — do not
    // stamp `disconnected` over its phases.
    if (!_runAlive(me)) return;
    _setState(ConnectionStateSnapshot(phase: ConnectionPhase.disconnected));
  }

  Future<void> _teardown() async {
    _monitorTimer?.cancel();
    _monitorTimer = null;
    _monitorProfile = null;
    _trafficTimer?.cancel();
    _removeTunnelMode();
    await cores.stop();
  }

  // ------------------------------------------------------------ Phase 6:
  // active-node monitoring + real failover.

  void _startMonitor(ProxyProfile profile) {
    _monitorProfile = profile;
    _monitorTimer?.cancel();
    _monitorTimer = Timer.periodic(_monitorInterval, (_) async {
      if (_state.phase != ConnectionPhase.connected &&
          _state.phase != ConnectionPhase.degraded) {
        return;
      }
      final probe = await _probeTunnel(
          '127.0.0.1', mixedPortFor(profile.effectiveCore));
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
    // v0.6.2 §stop-fix: failover is a CANDIDATE WALK too — a Stop must end
    // it (before, the walk carried on and reconnected the app).
    final seq = ++_walkSeq;
    _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.recovering, activeProfile: failed));
    final ranked = _scorer.rank(repository.all, healthStore.all, strategy);
    final candidates = ranked
        .map((r) => r.$1)
        .where((p) => p.id != failed.id)
        .take(4)
        .toList();
    for (final candidate in candidates) {
      if (seq != _walkSeq) return;
      Logger.instance.info('failover', 'trying candidate: ${candidate.name}');
      final before = _runId;
      final ok = await connect(candidate);
      if (seq != _walkSeq) return;
      if (_runId != before + 1) return;
      if (ok) {
        Logger.instance.info('failover', 'failover succeeded → ${candidate.name}');
        return;
      }
    }
    if (seq != _walkSeq) return;
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

      // Upstream crash (Xray/MDVPN/StormDNS): rebuild only the upstream,
      // keep the front engine and selector untouched.
      if (e.engine == CoreKind.xray ||
          e.engine == CoreKind.masterDnsVpn ||
          e.engine == CoreKind.stormDns) {
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

      // v0.6.4 §mihomo: standalone mihomo crash → rebuild the MIHOMO
      // session (recoverEngine delegates to startMihomo) and re-verify on
      // ITS mixed port. Before this, a mihomo crash fell into the front-
      // rebuild path, restarted sing-box for a session that never had one
      // and probed the wrong port — every crash ended in a bogus failover.
      if (e.engine == CoreKind.mihomo) {
        final recovered = await cores.recoverEngine(CoreKind.mihomo,
            all: repository.all, routing: routing, dns: dns);
        if (recovered) {
          final probe =
              await _probeTunnel('127.0.0.1', mixedPortFor(CoreKind.mihomo));
          if (probe.ok) {
            _setState(ConnectionStateSnapshot(
                phase: ConnectionPhase.connected,
                activeProfile: active,
                connectedAt: DateTime.now(),
                core: CoreKind.mihomo));
            return;
          }
        }
        await failoverFrom(active);
        return;
      }

      // Front engine crash: full front rebuild.
      final recovered = await cores
          .recoverFront(all: repository.all, routing: routing, dns: dns);
      if (recovered) {
        final probe =
            await _probeTunnel('127.0.0.1', mixedPortFor(null));
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
      // v0.6.4 §mihomo: read the counters of the engine that is ACTUALLY
      // serving — a standalone mihomo session never fills `front.traffic`,
      // so the dashboard graph stayed flat/zero on the default engine.
      final mihomoActive =
          _state.core == CoreKind.mihomo ||
          _state.activeProfile?.effectiveCore == CoreKind.mihomo;
      final t = mihomoActive &&
              cores.mihomo.status == RuntimeStatus.running
          ? cores.mihomo.traffic
          : cores.front.traffic;
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
