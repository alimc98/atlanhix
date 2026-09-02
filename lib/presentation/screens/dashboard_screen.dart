import 'dart:async';
import 'package:flutter/material.dart';
import '../../application/connection_controller.dart';
import '../../application/dependencies.dart';
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
  StreamSubscription? _sub;
  final _down = List<double>.generate(60, (_) => 0);
  final _up = List<double>.generate(60, (_) => 0);
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _sub = widget.deps.connection.states.listen((s) {
      if (!mounted) return;
      setState(() {
        _phase = s.phase;
        _active = s.activeProfile;
      });
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _down..removeAt(0)..add(0);
        _up..removeAt(0)..add(0);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final l = AppLocalizations.of(context)!;
    final health =
        _active == null ? null : widget.deps.healthStore.statsOf(_active!.id);
    final connected = _phase == ConnectionPhase.connected;
    final coreInfo = _active == null
        ? ''
        : '${_active!.protocol.name.toUpperCase()} · '
            '${widget.deps.detector.resolve(_active!).core.name} · '
            '${_active!.server}';

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
                  onToggle: () => connected
                      ? widget.deps.connection.disconnect()
                      : widget.deps.connection.smartConnect(),
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
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: MetricTile(
                        label: l.downloadSpeed,
                        value: '0 KB/s',
                        color: c.info),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: MetricTile(
                        label: l.uploadSpeed,
                        value: '0 KB/s',
                        color: c.success),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: MetricTile(
                      label: l.latency,
                      value: health?.lastLatencyMs == null
                          ? '—'
                          : '${health!.lastLatencyMs} ms',
                      color: (health?.lastLatencyMs ?? 999) < 300
                          ? c.success
                          : c.warning,
                    ),
                  ),
                ],
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
                child: _active == null
                    ? _emptyNode(context, l)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(_active!.name,
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
                              Chip(label: Text(_active!.protocol.name)),
                              Chip(
                                  label: Text(widget.deps
                                      .detector.resolve(_active!)
                                      .core
                                      .name)),
                              if (_active!.security != Security.none)
                                Chip(label: Text(_active!.security.name)),
                              if (_active!.transport != Transport.none)
                                Chip(label: Text(_active!.transport.name)),
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
          Text(title, style: Theme.of(context).textTheme.titleMedium),
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
