import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../application/connection_controller.dart';
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';

/// Primary connect control (design/COMPONENTS.md).
class ConnectButton extends StatelessWidget {
  const ConnectButton({
    super.key,
    required this.phase,
    required this.onToggle,
    this.size = 64,
  });

  final ConnectionPhase phase;
  final VoidCallback onToggle;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final connected = phase == ConnectionPhase.connected;
    final busy = const [
      ConnectionPhase.connecting,
      ConnectionPhase.startingCore,
      ConnectionPhase.switching,
      ConnectionPhase.disconnecting,
      ConnectionPhase.validating,
    ].contains(phase);
    final color = connected
        ? c.success
        : (phase == ConnectionPhase.error ? c.error : c.accent);

    return Semantics(
      button: true,
      label: connected ? 'Disconnect' : 'Connect',
      child: GestureDetector(
        onTap: busy ? null : onToggle,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            children: [
              if (busy)
                SizedBox(
                  width: size,
                  height: size,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation(c.accent),
                  ),
                )
              else
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    boxShadow: connected
                        ? [
                            BoxShadow(
                              color: c.success.withValues(alpha: 0.25),
                              blurRadius: 18,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                ),
              Center(
                child: Icon(
                  connected
                      ? Icons.stop_rounded
                      : (phase == ConnectionPhase.error
                          ? Icons.warning_amber_rounded
                          : Icons.power_settings_new_rounded),
                  color: Colors.white,
                  size: size * 0.42,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated connect-ring with progress for the dashboard hero.
class ConnectRing extends StatelessWidget {
  const ConnectRing({
    super.key,
    required this.phase,
    required this.onToggle,
    this.size = 168,
  });

  final ConnectionPhase phase;
  final VoidCallback onToggle;
  final double size;

  @override
  Widget build(BuildContext context) {
    final connected = phase == ConnectionPhase.connected;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.96, end: connected ? 1.0 : 0.96),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: ConnectButton(
        phase: phase,
        onToggle: onToggle,
        size: size,
      ),
    );
  }
}

/// Tiny reusable health dot with optional pulse (design/COMPONENTS.md).
class StatusDot extends StatelessWidget {
  const StatusDot({
    super.key,
    required this.color,
    this.label,
    this.pulse = false,
    this.size = 8,
  });

  final Color color;
  final String? label;
  final bool pulse;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 6),
        ],
      ),
    );
    if (label == null) return dot;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 6),
        Text(
          label!,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: ThemeExt.of(context).textSecondary),
        ),
      ],
    );
  }
}

/// Label-over-value metric with mono numerals (design/COMPONENTS.md).
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    this.color,
    this.mono = true,
  });

  final String label;
  final String value;
  final Color? color;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: c.textMuted,
                letterSpacing: 0.7,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (mono
                  ? NexusTypography.monoStyle
                  : Theme.of(context).textTheme.titleMedium)
              ?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: color ?? c.textPrimary,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// v0.4.7 §brand (sheet v2, 2026-09-15) — the circular CONNECT/DISCONNECT
/// control: glowing-ring circle artwork with the power glyph baked in, and
/// a REAL localized label underneath (اتصال / قطع اتصال), mirroring the
/// sheet's "circle + caption" anatomy. Busy state = a spinner riding the
/// circle; the tap target is the whole column.
class BrandPillButton extends StatelessWidget {
  const BrandPillButton({
    super.key,
    required this.connected,
    required this.busy,
    required this.onToggle,
    this.size = 148,
  });

  /// True → DISCONNECT artwork (thin ring); false → CONNECT (glowing ring).
  final bool connected;
  final bool busy;
  final VoidCallback onToggle;
  final double size;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);
    return Semantics(
      button: true,
      label: connected ? l.disconnect : l.connect,
      child: GestureDetector(
        onTap: busy ? null : onToggle,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Image.asset(
                  connected
                      ? 'assets/brand/circ_disconnect.png'
                      : 'assets/brand/circ_connect.png',
                  width: size,
                  height: size,
                  fit: BoxFit.contain,
                ),
                if (busy)
                  SizedBox(
                    width: size * 0.72,
                    height: size * 0.72,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              connected ? l.disconnect : l.connect,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: connected ? c.success : c.textSecondary,
                    letterSpacing: 4,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
