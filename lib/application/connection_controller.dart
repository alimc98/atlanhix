import 'dart:async';
import '../core/core_detector.dart';
import '../core/fragmentation/fragment_profiles.dart';
import '../core/health/latency_tester.dart';
import '../core/health/test_scheduler.dart';
import '../core/logger.dart';
import '../core/runtime/core_manager.dart';
import '../core/runtime/core_process.dart';
import '../core/runtime/core_runtime.dart';
import '../core/runtime/singbox_runtime.dart';
import '../core/scoring/node_scorer.dart';
import '../chain/chain_planner.dart';
import '../domain/entities/health.dart';
import '../domain/entities/proxy_profile.dart';
import '../domain/errors/app_error.dart';
import '../routing/builtin_profiles.dart';
import '../routing/routing_models.dart';
import '../data/profile_repository.dart';
import '../platform/system_proxy.dart';

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
  }) {
    // Phase 26: react to engine crashes.
    cores.front.onExit.listen(_onCoreExit);
  }

  final ProfileRepository repository;
  final HealthStore healthStore;
  final LatencyTester tester;
  final CoreDetector detector;
  final CoreManager cores;

  final _stateController =
      StreamController<ConnectionStateSnapshot>.broadcast();
  ConnectionStateSnapshot _state = ConnectionStateSnapshot();

  /// Realtime engine traffic (bytes) — Phase 24/28.
  Stream<TrafficSnapshot> get trafficStream => _trafficSubject.stream;
  final _trafficSubject = StreamController<TrafficSnapshot>.broadcast();
  Timer? _trafficTimer;

  TunnelMode tunnelMode = TunnelMode.systemProxy;
  DnsSettings dns = DnsSettings(mode: DnsMode.automatic);
  RoutingProfile routing = BuiltinRoutingProfiles.all().first;
  SelectionStrategy strategy = SelectionStrategy.smart;
  FragmentProfile? fragmentOverride;
  ProxyChain? activeChain;

  // Phase 6 failover tuning.
  int failureThreshold = 2;
  Duration monitorInterval = const Duration(seconds: 30);
  Timer? _monitorTimer;
  int _consecutiveVerifyFailures = 0;

  final NodeScorer _scorer = NodeScorer();

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

  /// Smart Connect (Phase 7): rank → try in order → verify → connected.
  /// Never requires the user to choose an engine.
  Future<void> smartConnect() async {
    final ranked = _scorer.rank(repository.all, healthStore.all, strategy);
    if (ranked.isEmpty) {
      _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.error,
        error: AppError('No nodes available to connect.'),
      ));
      return;
    }
    var lastError = 'all candidates failed';
    for (final (profile, _) in ranked.take(5)) {
      final ok = await connect(profile);
      if (ok) return;
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
      await cores.stop(); // clean slate for a new start
      final start = await cores.startFor(
        profile,
        all: repository.all,
        routing: routing,
        dns: dns,
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
      if (!probe.ok) {
        healthStore.record(HealthRecord(
          profileId: profile.id,
          at: DateTime.now(),
          ok: false,
          errorKind: probe.errorKind,
        ));
        await _teardown();
        throw ProbeError(
          'The node did not respond through the tunnel.',
          kind: probe.errorKind,
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
      return await connect(next);
    } finally {
      if (_state.phase == ConnectionPhase.switching) {
        _setState(ConnectionStateSnapshot(
            phase: ConnectionPhase.connected,
            activeProfile: current,
            connectedAt: _state.connectedAt));
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
    if (!probe.ok) return false;
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
        _setState(ConnectionStateSnapshot(
            phase: ConnectionPhase.degraded,
            activeProfile: profile,
            connectedAt: _state.connectedAt));
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
  // crash recovery: restart once, then failover.

  void _onCoreExit(CoreExitEvent e) {
    if (e.kind == CoreExitKind.clean) return;
    Logger.instance
        .error('connection', 'core crashed: ${e.kind.name} (${e.stderrTail})');
    final active = _state.activeProfile;
    if (active == null) return;
    if (_state.phase != ConnectionPhase.connected &&
        _state.phase != ConnectionPhase.degraded) {
      return;
    }
    unawaited(() async {
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.recovering, activeProfile: active));
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
