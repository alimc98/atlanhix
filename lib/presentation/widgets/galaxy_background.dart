import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// v0.4.9 §user (experimental) — Flutter port of the Compose
/// `AtlanthixGalaxyBackground` Claude suggested: a static galaxy scene
/// (star field + nebula wash + two planets + tilted orbit rings) drawn
/// ONLY from the app's own palette tokens.
///
/// Battery/behavior parity with the original notes:
///  * painted ONCE per state — [stars]/[nebula] are generated once per
///    State with a fixed seed (Compose's `remember` equivalent), never per
///    frame; no animation loop, no repaint churn (a CustomPainter whose
///    properties are const never repaints on rebuilds).
///  * true-black base (#0A0B0E) — near-free on AMOLED/OLED.
///
/// Usage:
///   SizedBox(height: 380, child: GalaxyBackground())
///   // hero content stacks on top exactly like the old artwork layer did.
class GalaxyBackground extends StatefulWidget {
  const GalaxyBackground({
    super.key,
    this.seedStars = 42,
    this.seedNebula = 7,
    this.starCount = 140,
  });

  final int seedStars;
  final int seedNebula;
  final int starCount;

  @override
  State<GalaxyBackground> createState() => _GalaxyBackgroundState();
}

class _GalaxyBackgroundState extends State<GalaxyBackground> {
  late final List<_Star> _stars = _generateStars(widget.seedStars, widget.starCount);
  late final List<_NebulaBlob> _nebula = _generateNebula(widget.seedNebula);

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    return RepaintBoundary(
      child: CustomPaint(
        // The painter carries only immutable value fields (palette tokens +
        // pre-generated lists) → Flutter skips repaints entirely on rebuilds.
        painter: _GalaxyPainter(
          ext: c,
          stars: _stars,
          nebula: _nebula,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Star {
  _Star(this.xFrac, this.yFrac, this.radius, this.alpha, this.sparkle);
  final double xFrac;
  final double yFrac;
  final double radius;
  final double alpha;
  final bool sparkle;
}

class _NebulaBlob {
  _NebulaBlob(this.xFrac, this.yFrac, this.radiusFrac, this.color, this.alpha);
  final double xFrac;
  final double yFrac;
  final double radiusFrac;
  final Color color;
  final double alpha;
}

List<_Star> _generateStars(int seed, int count) {
  final rnd = math.Random(seed);
  return List.generate(count, (i) {
    return _Star(
      rnd.nextDouble(),
      rnd.nextDouble(),
      0.5 + rnd.nextDouble() * 1.3,
      0.20 + rnd.nextDouble() * 0.55,
      i % 18 == 0,
    );
  });
}

List<_NebulaBlob> _generateNebula(int seed) {
  final rnd = math.Random(seed);
  // v0.4.9 §user-fix: Claude's snippet sampled WITHOUT the index (rnd /
  // palette.length is a double; `int` indexes threw on device). Two
  // pre-picked indices keep the same intent — surface + border tints.
  const palette = <Color?>[null, null]; // resolved per-build from ThemeExt
  return List.generate(3, (i) {
    return _NebulaBlob(
      rnd.nextDouble(),
      rnd.nextDouble(),
      0.30 + rnd.nextDouble() * 0.25,
      palette[i] ?? const Color(0xFF1A1D22),
      0.08 + rnd.nextDouble() * 0.05,
    );
  });
}

class _GalaxyPainter extends CustomPainter {
  _GalaxyPainter({
    required this.ext,
    required this.stars,
    required this.nebula,
  });

  final ThemeExt ext;
  final List<_Star> stars;
  final List<_NebulaBlob> nebula;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Base: true black (Primary) — AMOLED-friendly.
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0A0B0E));

    // Faint nebula wash, tinted with the app's own surface/border tones.
    final blobColors = [ext.surface, ext.border, ext.surface];
    for (var i = 0; i < nebula.length; i++) {
      final b = nebula[i];
      final center = Offset(b.xFrac * w, b.yFrac * h);
      final radius = b.radiusFrac * w;
      final tint = blobColors[i % blobColors.length];
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(
            center,
            radius,
            [
              tint.withValues(alpha: b.alpha),
              tint.withValues(alpha: 0),
            ],
          ),
      );
    }

    // Star field.
    final starPaint = Paint();
    final linePaint = Paint()
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (final s in stars) {
      final c0 = Offset(s.xFrac * w, s.yFrac * h);
      final white = const Color(0xFFFFFFFF).withValues(alpha: s.alpha);
      if (s.sparkle) {
        final len = s.radius * 4.5;
        linePaint.color = white;
        canvas.drawLine(c0 - Offset(len, 0), c0 + Offset(len, 0), linePaint);
        canvas.drawLine(c0 - Offset(0, len), c0 + Offset(0, len), linePaint);
      }
      starPaint.color = white;
      canvas.drawCircle(c0, s.radius, starPaint);
    }

    // Small companion planet.
    final moonCenter = Offset(w * 0.60, h * 0.34);
    final moonRadius = w * 0.085;
    canvas.drawCircle(
      moonCenter,
      moonRadius,
      Paint()
        ..shader = ui.Gradient.radial(
          moonCenter - Offset(-moonRadius * 0.3, -moonRadius * 0.3),
          moonRadius * 2,
          [ext.border, ext.surface, const Color(0xFF0A0B0E)],
        ),
    );

    // Main planet, lit rim on the right.
    final planetCenter = Offset(w * 0.72, h * 0.60);
    final planetRadius = w * 0.20;
    canvas.drawCircle(
      planetCenter,
      planetRadius,
      Paint()
        ..shader = ui.Gradient.radial(
          planetCenter - Offset(planetRadius * 0.35, planetRadius * 0.35),
          planetRadius * 2.1,
          [ext.border, ext.surface, const Color(0xFF0A0B0E)],
        ),
    );
    // Rim glow in white (accent) matching the logo/accent exactly.
    canvas.drawCircle(
      planetCenter,
      planetRadius,
      Paint()
        ..shader = ui.Gradient.radial(
          planetCenter + Offset(planetRadius * 0.95, planetRadius * 0.05),
          planetRadius,
          [
            const Color(0xFFFFFFFF).withValues(alpha: 0.65),
            const Color(0xFFFFFFFF).withValues(alpha: 0.12),
            const Color(0xFFFFFFFF).withValues(alpha: 0),
          ],
        ),
    );

    // Thin tilted orbit rings in Border/Text tones — UI, not noise.
    final ringCenter = Offset(w * 0.70, h * 0.48);
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;
    const rings = <(double, double, double)>[
      (0.36, 0.115, -18),
      (0.31, 0.078, 8),
      (0.27, 0.165, -32),
    ];
    for (var i = 0; i < rings.length; i++) {
      final (rx, ry, angleDeg) = rings[i];
      final alpha = i == 0 ? 0.30 : 0.20;
      canvas.save();
      canvas.translate(ringCenter.dx, ringCenter.dy);
      canvas.rotate(angleDeg * math.pi / 180);
      ringPaint.color = ext.textMuted.withValues(alpha: alpha);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset.zero,
          width: rx * 2 * w,
          height: ry * 2 * w,
        ),
        ringPaint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_GalaxyPainter old) =>
      old.ext != ext || !identical(old.stars, stars) || !identical(old.nebula, nebula);
}