import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import 'dashboard_globe.dart';

/// v0.5.2 §user — THE GLOBE IS THE APP BACKGROUND. One full-screen point
/// globe sits BEHIND every screen (the shell's Stack base layer); each
/// screen paints its content on top with transparent page scaffolds. When
/// the tunnel connects the backdrop's tint shifts (background → accent
/// wash, echoing the reference art's limb glow) and the map→sphere unfold
/// replays — the same animation the hero plays, now app-wide.
///
/// The widget is a thin wrapper around the hero globe's painter parameters
/// so both layers share one code path; here it renders softer (lower point
/// opacity, deeper vignette) so foreground text stays readable.
class GlobeBackdrop extends StatelessWidget {
  const GlobeBackdrop({
    super.key,
    required this.connected,
    required this.connecting,
    this.anchors = const [],
  });

  final bool connected;
  final bool connecting;
  final List<GlobeAnchor> anchors;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Base wash: the page color, then the globe over it.
          // (ThemeExt carries no page color — Theme.of's scaffold color IS
          // the page background and follows the same tokens.)
          ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
          // The globe: slightly larger than the viewport bottom, anchored
          // to the lower half (reference art composition — planet low,
          // space above), tinted by connection state.
          Positioned(
            left: -80,
            right: -80,
            bottom: -120,
            height: MediaQuery.sizeOf(context).height * 0.85,
            child: _BackdropGlobe(
              connected: connected,
              connecting: connecting,
              anchors: anchors,
            ),
          ),
          // Readability vignette: the top half stays near-solid background
          // so lists/cards render over it cleanly.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.center,
                colors: [
                  Theme.of(context)
                      .scaffoldBackgroundColor
                      .withValues(alpha: 0.86),
                  Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BackdropGlobe extends StatefulWidget {
  const _BackdropGlobe({
    required this.connected,
    required this.connecting,
    required this.anchors,
  });

  final bool connected;
  final bool connecting;
  final List<GlobeAnchor> anchors;

  @override
  State<_BackdropGlobe> createState() => _BackdropGlobeState();
}

class _BackdropGlobeState extends State<_BackdropGlobe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _tint = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 0,
  );
  bool _wasConnected = false;

  @override
  void initState() {
    super.initState();
    _wasConnected = widget.connected;
    if (_wasConnected) _tint.value = 1;
  }

  @override
  void didUpdateWidget(covariant _BackdropGlobe old) {
    super.didUpdateWidget(old);
    if (widget.connected != _wasConnected) {
      _wasConnected = widget.connected;
      // Connect → tint rises (the accent wash breathes in); disconnect →
      // fades back to ink.
      _tint.forward(from: 0);
      _tint.value = 1 - _tint.value;
    }
  }

  @override
  void dispose() {
    _tint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    return AnimatedBuilder(
      animation: _tint,
      builder: (context, _) {
        final tint = Curves.easeInOut.transform(_tint.value);
        return Stack(
          fit: StackFit.expand,
          children: [
            // Connection-state WASH behind the globe (green breath on
            // connect — the app visibly changes color, per the user).
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, 0.55),
                  radius: 1.1,
                  colors: [
                    c.success.withValues(alpha: 0.10 + 0.12 * tint),
                    Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
            Opacity(
              opacity: 0.45,
              child: _StaticGlobe(
                anchors: widget.anchors,
                connected: widget.connected,
                tint: tint,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The globe itself — repainted by the shared dashboard-globe painter
/// through a widget instance with backdrop-tuned knobs. It participates in
/// no gestures (IgnorePointer above) and parks when the app hides.
class _StaticGlobe extends StatefulWidget {
  const _StaticGlobe({
    required this.anchors,
    required this.connected,
    required this.tint,
  });

  final List<GlobeAnchor> anchors;
  final bool connected;
  final double tint;

  @override
  State<_StaticGlobe> createState() => _StaticGlobeState();
}

class _StaticGlobeState extends State<_StaticGlobe>
    with SingleTickerProviderStateMixin {
  // v0.5.3 §perf-fix ("برنامه شدیداً کند شده"): the backdrop painted
  // 17,737 land points EVERY frame (a repeat()-ing controller) — behind
  // EVERY tab, for a globe mostly hidden under the vignette. The rotation
  // is now FRAME-THROTTLED: the controller still beats at 60 fps but only
  // ~10 repaints/s actually reach the painter (a yaw-step accumulator
  // holds the smooth motion between them). ~6× less paint work per second
  // for the backdrop, no visible stutter at this rotation speed.
  static const _throttleEvery = 6; // frames ≈ 10 repaints/s @60fps
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();
  int _spinTick = 0;
  double _yaw = 0;

  @override
  void initState() {
    super.initState();
    _yaw = math.Random().nextDouble() * 2 * math.pi;
    _spin.addListener(() {
      _spinTick++;
      // Advance the yaw by the FULL per-second step of the skipped frames.
      if (_spinTick % _throttleEvery == 0) _yaw += 0.00025 * _throttleEvery;
    });
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Backdrop variant: reuse the hero globe with muted knobs.
    return DashboardGlobe(
      anchors: widget.anchors,
      intro: widget.connected ? GlobeIntro.unfold : GlobeIntro.none,
      initialYaw: _yaw,
      pointOpacity: 0.5 + 0.3 * widget.tint,
      autoRotate: true,
    );
  }
}
