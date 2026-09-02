import 'dart:async';
import '../core/core_detector.dart';
import '../core/fragmentation/fragment_profiles.dart';
import '../core/health/latency_tester.dart';
import '../core/health/test_scheduler.dart';
import '../core/logger.dart';
import '../core/scoring/node_scorer.dart';
import '../chain/chain_planner.dart';
import '../domain/entities/health.dart';
import '../domain/entities/proxy_profile.dart';
import '../domain/errors/app_error.dart';
import '../routing/builtin_profiles.dart';
import '../routing/routing_models.dart';
import '../data/profile_repository.dart';

/// Connection lifecycle states surfaced to the UI.
enum ConnectionPhase {
  disconnected,
  resolving,
  validating,
  startingCore,
  connecting,
  connected,
  switching,
  disconnecting,
  error,
}

class ConnectionStateSnapshot {
  ConnectionStateSnapshot({
    this.phase = ConnectionPhase.disconnected,
    this.activeProfile,
    this.error,
    this.connectedAt,
  });

  final ConnectionPhase phase;
  final ProxyProfile? activeProfile;
  final AppError? error;
  final DateTime? connectedAt;

  bool get isConnected => phase == ConnectionPhase.connected;
}

/// Modes of exposing the tunnel to the OS (§22, §23).
enum TunnelMode { off, systemProxy, tun, managed }

/// The application-layer orchestrator. Owns the connect/disconnect/switch
/// lifecycle. UI observes [state]; it never touches processes directly.
class ConnectionController {
  ConnectionController({
    required this.repository,
    required this.healthStore,
    required this.tester,
    required this.detector,
  });

  final ProfileRepository repository;
  final HealthStore healthStore;
  final LatencyTester tester;
  final CoreDetector detector;

  final _stateController =
      StreamController<ConnectionStateSnapshot>.broadcast();
  ConnectionStateSnapshot _state = ConnectionStateSnapshot();

  TunnelMode tunnelMode = TunnelMode.systemProxy;
  DnsSettings dns = DnsSettings(mode: DnsMode.automatic);
  RoutingProfile routing = BuiltinRoutingProfiles.all().first;
  SelectionStrategy strategy = SelectionStrategy.smart;
  FragmentProfile? fragmentOverride;
  ProxyChain? activeChain;

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

  /// Smart Connect (§70): rank candidates, try best, verify, fail over.
  Future<void> smartConnect() async {
    final ranked = _scorer.rank(repository.all, healthStore.all, strategy);
    if (ranked.isEmpty) {
      _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.error,
        error: AppError('No nodes available to connect.'),
      ));
      return;
    }
    for (final (profile, _) in ranked.take(5)) {
      final ok = await connect(profile);
      if (ok) return;
    }
    _setState(ConnectionStateSnapshot(
      phase: ConnectionPhase.error,
      error: AppError(
        'Could not establish a connection with the top candidates.',
        likelyCauses: [
          'All tried nodes are unreachable',
          'Your network may be blocking the selected protocols',
        ],
      ),
    ));
  }

  /// Connects a specific profile. Returns true on verified success.
  Future<bool> connect(ProxyProfile profile) async {
    try {
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.validating, activeProfile: profile));
      final decision = detector.resolve(profile);
      final problems = _validate(profile);
      if (problems.isNotEmpty) {
        throw ConfigValidationError(
          'This configuration has problems.',
          problems: problems,
        );
      }

      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.startingCore, activeProfile: profile));
      // Core launching is delegated to the platform runner: on Android via
      // VpnService, on desktop via CoreManager processes. See
      // docs/PLATFORM_ARCHITECTURE.md for the wiring contract.
      await _launchEngine(profile, decision);

      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.connecting, activeProfile: profile));
      final probe = await _verify(profile);
      if (!probe.ok) {
        await _stopEngine(profile);
        throw ProbeError(
          'The node did not respond through the tunnel.',
          kind: probe.errorKind,
        );
      }

      _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.connected,
        activeProfile: profile,
        connectedAt: DateTime.now(),
      ));
      healthStore.record(HealthRecord(
        profileId: profile.id,
        at: DateTime.now(),
        ok: true,
        latencyMs: probe.latencyMs,
      ));
      return true;
    } on AppError catch (e) {
      Logger.instance.error('connection', e.userMessage);
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.error, activeProfile: profile, error: e));
      return false;
    } catch (e) {
      Logger.instance.error('connection', e.toString());
      _setState(ConnectionStateSnapshot(
          phase: ConnectionPhase.error,
          activeProfile: profile,
          error: AppError('Unexpected error while connecting.', raw: e)));
      return false;
    }
  }

  List<String> _validate(ProxyProfile p) {
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

  Future<ProbeResult> _verify(ProxyProfile p) async {
    // Verify through the local mixed inbound (sing-box) or xray socks.
    final isXray = p.effectiveCore == CoreKind.xray;
    return tester.testHttpViaSocksProxy(
      '127.0.0.1',
      isXray ? 2081 : 2080,
      'https://www.gstatic.com/generate_204',
      timeout: const Duration(seconds: 6),
    );
  }

  Future<void> disconnect() async {
    final current = _state.activeProfile;
    _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.disconnecting, activeProfile: current));
    if (current != null) {
      await _stopEngine(current);
    }
    _setState(ConnectionStateSnapshot(phase: ConnectionPhase.disconnected));
  }

  /// Fast switching (§71): same-core switch prefers hot-swap paths.
  Future<bool> switchTo(ProxyProfile next) async {
    final current = _state.activeProfile;
    if (current == null) return connect(next);
    _setState(ConnectionStateSnapshot(
        phase: ConnectionPhase.switching, activeProfile: current));
    final ok = await connect(next);
    if (!ok) {
      // Recovery: attempt to restore the previous node.
      await connect(current);
    }
    return ok;
  }

  Future<void> _launchEngine(ProxyProfile p, CoreDecision decision) async {
    Logger.instance.info('connection',
        'start core=${decision.core.name} confidence=${decision.confidence}');
    // Platform runners hook in here (Android VpnService / desktop CoreManager).
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  Future<void> _stopEngine(ProxyProfile p) async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  void dispose() {
    _stateController.close();
  }
}
