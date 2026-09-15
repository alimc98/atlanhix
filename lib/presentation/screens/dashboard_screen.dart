import 'dart:async';
import 'package:flutter/material.dart';
import '../../application/connection_controller.dart';
import '../../application/dependencies.dart';
import '../../core/android_node_support.dart';
import '../../domain/entities/health.dart';
import '../../domain/entities/proxy_profile.dart';
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/speed_graph.dart';

/// Main dashboard (§30): answers in 5 seconds — connected? which node?
/// healthy? how fast? what core?
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.deps});

  final AppDependencies deps;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  ProxyProfile? _active;
  int? _latencyMs;
  CoreKind? _core;
  DateTime? _connectedAt;
  StreamSubscription? _sub;
  StreamSubscription? _trafficSub;
  StreamSubscription? _vpnSub;
  final _down = List<double>.filled(60, 0);
  final _up = List<double>.filled(60, 0);
  int? _lastUp; // for speed delta
  int? _lastDown;
  Timer? _clock;
  // v0.4.1 §5: Android selection is authoritative and can change OUTSIDE the
  // state machine (tap while disconnected emits no VPN phase), so the
  // dashboard also listens to explicit selection events and re-reads
  // selectedNode — the tapped node shows immediately, BEFORE any connect.
  StreamSubscription? _selectionSub;

  bool get _onAndroid => widget.deps.vpnSession.controller.isAndroid;

  @override
  void initState() {
    super.initState();
    _sub = widget.deps.connection.states.listen((s) {
      if (!mounted) return;
      setState(() {
        _phase = s.phase;
        _active = s.activeProfile;
        _latencyMs = s.latencyMs;
        _core = s.core ?? s.activeProfile?.effectiveCore;
        _connectedAt = s.connectedAt;
        if (s.phase == ConnectionPhase.disconnected) {
          // Reset the graphs on disconnect — honest empty state.
          for (var i = 0; i < 60; i++) {
            _down[i] = 0;
            _up[i] = 0;
          }
          _lastUp = null;
          _lastDown = null;
        }
      });
    });
    // v0.4.1 §5: single authoritative state — on Android the VPN session is
    // the source of truth; mirror its native phases into the dashboard UI.
    if (widget.deps.vpnSession.controller.isAndroid) {
      _vpnSub = widget.deps.vpnSession.states.listen((_) {
        if (!mounted) return;
        setState(() {
          _phase = widget.deps.vpnSession.uiPhase;
          _active = widget.deps.vpnSession.selectedNode;
        });
      });
      // Selection changed without a phase event (tap while disconnected):
      // repaint so the tapped node appears the moment it is tapped.
      _selectionSub = widget.deps.vpnSession.selectionChanged.listen((_) {
        if (!mounted) return;
        setState(() {
          _active = widget.deps.vpnSession.selectedNode;
        });
      });
    }
    _trafficSub = widget.deps.connection.trafficStream.listen((t) {
      if (!mounted) return;
      setState(() {
        // Real speed = delta of engine counters (Phase 24).
        final upSpeed =
            _lastUp == null ? 0 : (t.upBytes - _lastUp!).clamp(0, 1 << 30);
        final downSpeed = _lastDown == null
            ? 0
            : (t.downBytes - _lastDown!).clamp(0, 1 << 30);
        _lastUp = t.upBytes;
        _lastDown = t.downBytes;
        _down..removeAt(0)..add(downSpeed.toDouble());
        _up..removeAt(0)..add(upSpeed.toDouble());
      });
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _phase == ConnectionPhase.connected) {
        setState(() {}); // session clock
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _trafficSub?.cancel();
    _vpnSub?.cancel();
    _selectionSub?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  static String _fmtSpeed(num bps) {
    if (bps > 1 << 20) return '${(bps / (1 << 20)).toStringAsFixed(1)} MB/s';
    if (bps > 1 << 10) return '${(bps / (1 << 10)).toStringAsFixed(0)} KB/s';
    return '$bps B/s';
  }

  String _fmtSession(DateTime? since) {
    if (since == null) return '—';
    final d = DateTime.now().difference(since);
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final l = AppLocalizations.of(context)!;
    // v0.4.1 §5: on Android the VpnSession's explicit selection IS the truth.
    // Read it on every build so the hero card reflects the TAPPED node
    // immediately — before any connect attempt, even while disconnected.
    final active = _onAndroid
        ? (widget.deps.vpnSession.selectedNode ?? _active)
        : _active;
    final health =
        active == null ? null : widget.deps.healthStore.statsOf(active.id);
    final connected = _phase == ConnectionPhase.connected;
    final coreInfo = active == null
        ? ''
        : '${active.protocol.name.toUpperCase()} · '
            '${_onAndroid ? AndroidNodeSupport.androidCoreLabel(active) : widget.deps.detector.resolve(active).core.name} · '
            '${active.server}';
    // v0.4.1: REAL active-core indicator — derived from the VPN session's
    // selected node and the on-device engine gating, never hardcoded.
    final activeCoreLabel = _onAndroid && active != null
        ? AndroidNodeSupport.coreDisplayName(widget.deps.vpnSession.activeCore)
        : null;
    // Honest error codes from the last connect attempt (node-selection).
    final lastErr = _onAndroid ? widget.deps.vpnSession.lastError : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(NexusSpacing.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: ConnectRing(
                  phase: _phase,
                  // v0.4.1 §2: on Android the connect path is the VPN session
                  // (VpnService.prepare → libbox); desktop keeps smartConnect.
                  onToggle: () async {
                    if (connected) {
                      if (widget.deps.vpnSession.controller.isAndroid) {
                        await widget.deps.vpnSession.disconnect();
                      } else {
                        await widget.deps.connection.disconnect();
                      }
                    } else {
                      if (widget.deps.vpnSession.controller.isAndroid) {
                        final ok = await widget.deps.vpnSession.connect();
                        if (!ok && mounted) {
                          final vpn = widget.deps.vpnSession;
                          final req = vpn.selectedNode;
                          final why = req == null
                              ? ''
                              : ' (${AndroidNodeSupport.notRunnableReason(req) ?? req.name} cannot run on this device)';
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(AndroidNodeSupport
                                      .connectErrorHint(vpn.lastError) ??
                                  'Connection failed$why')));
                        }
                      } else {
                        await widget.deps.connection.smartConnect();
                      }
                    }
                  },
                ),
              ),
              const SizedBox(height: 20),
              Text(
                switch (_phase) {
                  ConnectionPhase.connected => l.connected,
                  ConnectionPhase.connecting ||
                  ConnectionPhase.startingCore ||
                  ConnectionPhase.switching ||
                  ConnectionPhase.validating =>
                    l.connecting,
                  ConnectionPhase.error => l.connectionFailed,
                  _ => l.disconnected,
                },
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      color: connected ? c.success : c.textPrimary,
                    ),
              ),
              if (_active != null) ...[
                const SizedBox(height: 6),
                Text(coreInfo,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: c.textSecondary)),
              ],
              if (activeCoreLabel != null) ...[
                const SizedBox(height: 10),
                // Per-connection core indicator — the core that WILL run (or
                // is running) this node on Android, from real session state.
                Tooltip(
                  message: 'Core that runs this node on Android',
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: c.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.memory, size: 14, color: c.info),
                        const SizedBox(width: 6),
                        Text(
                          activeCoreLabel,
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                  color: c.textSecondary,
                                  fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (lastErr != null && active != null &&
                  AndroidNodeSupport.notRunnableReason(active) != null) ...[
                const SizedBox(height: 10),
                // Node-selection honesty: the tapped node cannot run on this
                // device — the reason is visible here and in the log.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.swap_horiz, size: 14, color: c.warning),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${active.name}: ${AndroidNodeSupport.notRunnableReason(active) ?? 'not runnable on Android'}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: c.warning),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: MetricTile(
                        label: l.downloadSpeed,
                        value: _fmtSpeed(_down.last),
                        color: c.info),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: MetricTile(
                        label: l.uploadSpeed,
                        value: _fmtSpeed(_up.last),
                        color: c.success),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: MetricTile(
                      label: l.latency,
                      value: _latencyMs == null
                          ? '—'
                          : '$_latencyMs ms',
                      color: (_latencyMs ?? 999) < 300 ? c.success : c.warning,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${l.session}: ${_fmtSession(_connectedAt)} · '
                '↑${_fmtSpeed(_up.last)} · ↓${_fmtSpeed(_down.last)}',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
                child: SpeedGraph(downSamples: _down, upSamples: _up),
              ),
              const SizedBox(height: 24),
              _sectionCard(
                context,
                title: l.currentNode,
                child: active == null
                    ? _emptyNode(context, l)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(active.name,
                                    style:
                                        Theme.of(context).textTheme.titleMedium),
                              ),
                              StatusDot(
                                color: _healthColor(health?.state, c),
                                label: _healthLabel(health?.state, l),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Chip(label: Text(active.protocol.name)),
                              Chip(
                                  label: Text(_onAndroid
                                      ? AndroidNodeSupport.androidCoreLabel(
                                          active)
                                      : widget.deps.detector
                                          .resolve(active)
                                          .core
                                          .name)),
                              if (active.security != Security.none)
                                Chip(label: Text(active.security.name)),
                              if (active.transport != Transport.none)
                                Chip(label: Text(active.transport.name)),
                            ],
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 16),
              _sectionCard(
                context,
                title: l.quickActions,
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => widget.deps.connection.smartConnect(),
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: Text(l.autoSelect),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        widget.deps.scheduler
                            .updateProfiles(widget.deps.profiles.all);
                        widget.deps.scheduler.start();
                        widget.deps.scheduler.enqueueSweep();
                      },
                      icon: const Icon(Icons.speed, size: 18),
                      label: Text(l.testAllNodes),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionCard(BuildContext context,
      {required String title, required Widget child}) {
    final c = ThemeExt.of(context);
    return Container(
      padding: const EdgeInsets.all(NexusSpacing.lg),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(Localizations.localeOf(context).languageCode == 'fa'
              ? title
              : title.toUpperCase(),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _emptyNode(BuildContext context, AppLocalizations l) {
    final c = ThemeExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.travel_explore, size: 40, color: c.textMuted),
            const SizedBox(height: 8),
            Text(l.noNodeSelected,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: c.textSecondary)),
          ],
        ),
      ),
    );
  }

  Color _healthColor(NodeHealth? s, ThemeExt c) => switch (s) {
        NodeHealth.healthy => c.success,
        NodeHealth.degraded => c.warning,
        NodeHealth.checking => c.info,
        NodeHealth.timeout ||
        NodeHealth.offline ||
        NodeHealth.blocked ||
        NodeHealth.coreError ||
        NodeHealth.configError =>
          c.error,
        _ => c.textMuted,
      };

  String _healthLabel(NodeHealth? s, AppLocalizations l) => switch (s) {
        NodeHealth.healthy => l.healthHealthy,
        NodeHealth.degraded => l.healthDegraded,
        NodeHealth.checking => l.healthChecking,
        NodeHealth.timeout => l.healthTimeout,
        NodeHealth.offline => l.healthOffline,
        NodeHealth.blocked => l.healthBlocked,
        NodeHealth.coreError => l.healthCoreError,
        NodeHealth.configError => l.healthConfigError,
        _ => l.healthUnknown,
      };
}
