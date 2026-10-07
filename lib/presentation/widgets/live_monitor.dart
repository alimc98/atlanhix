import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../platform/device_stats.dart';
import '../tab_stage.dart';
import '../../theme/theme.dart';

/// v0.5.2 §user — LIVE MONITOR: battery % + temperature, THIS app's CPU
/// share and RAM footprint, polled every 3 s while visible (TickerMode
/// gates the timer; hidden app → no polls).
class LiveMonitor extends StatefulWidget {
  const LiveMonitor({super.key});

  @override
  State<LiveMonitor> createState() => _LiveMonitorState();
}

class _LiveMonitorState extends State<LiveMonitor> {
  final DeviceStats _stats = DeviceStats();
  DeviceSample? _sample;
  Timer? _timer;

  /// v0.6.4 §battery: the poll reads /proc + the battery sensor every 3 s.
  /// It only earns that cost while this tab is actually on screen.
  bool _stageActive = true;

  @override
  void initState() {
    super.initState();
    if (_stats.isAndroid) _poll();
  }

  void _poll() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) return;
      final s = await _stats.poll();
      if (mounted) setState(() => _sample = s);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // v0.6.4 §battery: park the /proc poll while the dashboard tab is
    // offstage (the doc comment above promised exactly this via TickerMode,
    // which never stops a Dart timer — the shell now tells us directly).
    final active = TabStageScope.activeOf(context);
    if (active == _stageActive) return;
    _stageActive = active;
    if (active) {
      if (_stats.isAndroid) _poll();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final s = _sample;
    String? pct(int? v) => v == null ? null : '$v';
    String? tmp(double? v) => v == null ? null : '${v.toStringAsFixed(1)}°';
    String? cpu(double? v) => v == null ? null : '${v.toStringAsFixed(0)}%';
    String? ram(int? b) => b == null
        ? null
        : b >= 1 << 20
            ? '${(b / (1 << 20)).round()} MB'
            : '${(b / (1 << 10)).round()} KB';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          _cell(
            context,
            icon: Icons.battery_full_outlined,
            label: 'BATTERY',
            value: [
              if (pct(s?.batteryPct) != null)
                '${s!.batteryPct}%'
              else
                '—',
              if (s?.charging == true) ' ⚡',
            ].join(),
            sub: tmp(s?.batteryTempC) ?? '—',
            color: (s?.batteryPct ?? 100) < 20 ? c.warning : c.success,
          ),
          _divider(c),
          _cell(
            context,
            icon: Icons.memory,
            label: 'CPU',
            value: cpu(s?.cpuPct) ?? '—',
            sub: 'APP',
            color: (s?.cpuPct ?? 0) > 60 ? c.warning : c.textPrimary,
          ),
          _divider(c),
          _cell(
            context,
            icon: Icons.dns_outlined,
            label: 'RAM',
            value: ram(s?.ramBytes) ?? '—',
            sub: 'APP',
            color: c.textPrimary,
          ),
        ],
      ),
    );
  }

  Widget _divider(ThemeExt c) => Container(
        width: 1,
        height: 30,
        color: c.border,
        margin: const EdgeInsets.symmetric(horizontal: 10),
      );

  Widget _cell(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required String sub,
    required Color color,
  }) {
    return Expanded(
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: ThemeExt.of(context).textSecondary,
                        fontSize: 9,
                        letterSpacing: 1.2,
                      )),
              Text(value,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              Text(sub,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: ThemeExt.of(context).textMuted)),
            ],
          ),
        ],
      ),
    );
  }
}
