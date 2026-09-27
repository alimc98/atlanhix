import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../theme/theme.dart';

/// v0.5.0 §user — HERO TRAFFIC GRAPH (the mockup on the dashboard):
/// layered flowing waves (one smooth ribbon per series, glass fills, a
/// glow-cored edge line), a radial bar "burst" at the NOW edge and a
/// floating pill that tracks the current peak — the whole scene breathes
/// on a phase animator so even an idle link ripples gently.
///
/// Design language (mockup "TOTAL TRAFFIC / 12.4 KB/s / Upload / Download"):
///   * dark glass field, hairline cross grid, dotted accents
///   * series in accent-white (download) and green (upload)
///   * NOW-edge vertical bars: needle-style, soft, per-series
///   * pill markers: ↑ current upload, ↓ current download, rounded glass
///
/// Everything is drawn in ONE CustomPainter (60 fps cheap: two 64-sample
/// series + ~12 bars) and animated with a single AnimationController
/// driving (a) the horizontal phase drift and (b) the new-sample relax.
class TrafficGraph extends StatefulWidget {
  const TrafficGraph({
    super.key,
    required this.downSamples,
    required this.upSamples,
    this.height = 220,
    this.pillPosition,
    this.showPeakPill = true,
    this.transparentField = false,
  });

  /// Ring-buffered bytes/s samples (dashboard already keeps 60 of them).
  final List<double> downSamples;
  final List<double> upSamples;

  final double height;

  /// 0..1 — where the peak pill sits horizontally; null = auto (at the
  /// global maximum), matching the mockup's pill floating over its peak.
  final double? pillPosition;

  /// Show the floating speed pill (mockup's “12.4 KB/s” bubble).
  final bool showPeakPill;

  /// v0.5.0 §user: when true the painter skips its own glass field so the
  /// graph sits directly ON the hero artwork (the moon) instead of its own
  /// card — the mockup layers the waves over the planet.
  final bool transparentField;

  @override
  State<TrafficGraph> createState() => _TrafficGraphState();
}

class _TrafficGraphState extends State<TrafficGraph>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  )..repeat();

  // v0.5.0 §battery-fix ("یه مقدار برنامه کُنده، انگار لگ شده — مصرف باتری"):
  // the scene breathed on an endless 60 fps repeat — even with the app
  // HIDDEN (Android pauses Timers, but a running AnimationController keeps
  // painting through the raster thread and burns GPU/CPU in the
  // background), and even while the app sat on another TAB with the graph
  // offscreen. Now the repeat pauses when the app hides (or the widget is
  // not visible) and resumes on return — the graph is static during those
  // windows, which is exactly what a hidden dashboard should be.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_ctl.isAnimating) _ctl.repeat();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _ctl.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (context, _) => CustomPaint(
          size: Size(double.infinity, widget.height),
          painter: _TrafficPainter(
            phase: _ctl.value,
            down: widget.downSamples,
            up: widget.upSamples,
            // Mockup palette: the emerald ribbon + the white/silver one.
            green: c.success,
            accent: c.textPrimary,
            grid: c.border,
            pillPosition: widget.pillPosition,
            showPeakPill: widget.showPeakPill,
            transparentField: widget.transparentField,
          ),
        ),
      ),
    );
  }
}

class _TrafficPainter extends CustomPainter {
  _TrafficPainter({
    required this.phase,
    required this.down,
    required this.up,
    required this.green,
    required this.accent,
    required this.grid,
    this.pillPosition,
    this.showPeakPill = true,
    this.transparentField = false,
  });

  final double phase;
  final List<double> down;
  final List<double> up;
  final Color green;
  final Color accent;
  final Color grid;
  final double? pillPosition;
  final bool showPeakPill;
  final bool transparentField;

  @override
  void paint(Canvas canvas, Size size) {
    if (!transparentField) _field(canvas, size);
    _gridAndDots(canvas, size);

    final samples = _mergedSamples();
    // Depth echoes first (behind everything).
    _ribbon(canvas, size, samples.down, accent, haloColor: accent, echo: true);
    _ribbon(canvas, size, samples.up, green, haloColor: green, echo: true);
    final top = _ribbon(canvas, size, samples.up, green, haloColor: green);
    final bottom = _ribbon(canvas, size, samples.down, accent,
        haloColor: Color.lerp(accent, green, 0.45)!);

    _burst(canvas, size, samples);
    if (showPeakPill) {
      _peakPill(canvas, size, samples, top, bottom);
    }
  }

  // ── SCENE ────────────────────────────────────────────────────────────

  /// Glass field: a vertical sheen so the panel reads as a card even
  /// directly on the hero background (the mockup's faint panel).
  void _field(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.035),
            Colors.white.withValues(alpha: 0.012),
            Colors.white.withValues(alpha: 0.045),
          ],
        ).createShader(rect),
    );
  }

  void _gridAndDots(Canvas canvas, Size size) {
    final hairline = Paint()
      ..color = grid.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    // Vertical hairlines at the time ticks (mockup: -6h · -4h · -2h · Now).
    for (final f in const [0.12, 0.375, 0.625, 0.88]) {
      canvas.drawLine(Offset(size.width * f, 12),
          Offset(size.width * f, size.height - 10), hairline);
    }
    // Horizontal hairlines.
    for (final f in const [0.3, 0.58, 0.86]) {
      canvas.drawLine(Offset(6, size.height * f),
          Offset(size.width - 6, size.height * f), hairline);
    }
    // Dotted star-specks (the mockup's tiny scattered stars).
    final dot = Paint()..color = Colors.white.withValues(alpha: 0.20);
    const specks = [
      (0.07, 0.16), (0.21, 0.10), (0.34, 0.20), (0.47, 0.08),
      (0.61, 0.15), (0.72, 0.09), (0.84, 0.17), (0.94, 0.10),
      (0.11, 0.42), (0.28, 0.34), (0.44, 0.39), (0.68, 0.33),
      (0.88, 0.41), (0.18, 0.24), (0.52, 0.24), (0.78, 0.26),
    ];
    for (var i = 0; i < specks.length; i++) {
      final (fx, fy) = specks[i];
      // A slow per-speck twinkle (phase + index ⇒ incoherent shimmer).
      final tw = 0.55 +
          0.45 * math.sin(phase * 2 * math.pi + i * 1.7) *
              (0.5 + 0.5 * math.sin(i * 2.3));
      canvas.drawCircle(
        Offset(size.width * fx, size.height * fy),
        1.1,
        dot..color = Colors.white.withValues(alpha: 0.10 + 0.16 * tw),
      );
    }
  }

  // ── DATA SHAPING ─────────────────────────────────────────────────────

  /// Resamples the ring buffer to 64 ribbon points. A 5-tap moving
  /// average first turns the per-second spiky counters into the mockup's
  /// rolling hills (the needle shape of the raw data is why the first
  /// golden looked like a seismograph), then the sine relaxation makes
  /// the wave breathe between real samples.
  _Series _shape(List<double> src, double phase) {
    const n = _TrafficPainter.points;
    if (src.isEmpty) return _Series(List.filled(n, 0), 0, 0);
    final maxV = src.reduce(math.max);
    final norm = List<double>.filled(src.length, 0);
    for (var i = 0; i < src.length; i++) {
      norm[i] = maxV <= 0 ? 0 : src[i] / maxV;
    }
    // 5-tap [1 2 3 2 1]/9 kernel — softens single-sample needles while
    // keeping real bursts (they survive as wider hills).
    final smooth = List<double>.filled(src.length, 0);
    const k = [1, 2, 3, 2, 1];
    for (var i = 0; i < src.length; i++) {
      var acc = 0.0;
      var wsum = 0;
      for (var j = -2; j <= 2; j++) {
        final idx = (i + j).clamp(0, src.length - 1);
        acc += norm[idx] * k[j + 2];
        wsum += k[j + 2];
      }
      smooth[i] = acc / wsum;
    }
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      final x = t * (src.length - 1);
      final i0 = x.floor();
      final i1 = math.min(i0 + 1, src.length - 1);
      final f = x - i0;
      final base = smooth[i0] + (smooth[i1] - smooth[i0]) * f;
      final ripple =
          0.035 * math.sin(2 * math.pi * (t * 2.2 + phase)) * (0.25 + base);
      out[i] = (base + ripple).clamp(0.0, 1.0);
    }
    // The TRUE current speed for the NOW burst: the last RAW (unsmoothed)
    // sample — smoothing is for the wave's silhouette, not for "how fast
    // are we going RIGHT NOW".
    return _Series(out, maxV, norm.last);
  }

  _Samples _mergedSamples() => _Samples(
        down: _shape(down, phase),
        up: _shape(up, phase * 0.8 + 0.35), // desynced so ribbons differ
      );

  // ── SERIES ───────────────────────────────────────────────────────────

  /// Paints one glass wave + glow-cored edge line. Returns the absolute
  /// y of the global maximum point (for pill anchoring).
  double _ribbon(Canvas canvas, Size size, _Series s, Color color,
      {required Color haloColor, bool echo = false}) {
    final w = size.width;
    final h = size.height;
    final plotH = h * 0.66; // waves occupy the lower 2/3
    final baseY = h - 8;
    final step = w / (_TrafficPainter.points - 1);
    Offset? peak;
    var peakV = -1.0;
    if (echo) {
      // Distant ridge: the same series offset + softened, no line — the
      // mockup's layered depth (a faint mountain behind the main pair).
      final echoPath = Path()..moveTo(0, baseY - s.values[12 % s.values.length] * plotH * 0.75);
      for (var i = 1; i < _TrafficPainter.points; i++) {
        final v = s.values[(i + 12) % s.values.length];
        final mx = (i - 0.5) * step;
        echoPath.cubicTo(
            mx, baseY - s.values[(i - 1 + 12) % s.values.length] * plotH * 0.75,
            mx, baseY - v * plotH * 0.75,
            i * step, baseY - v * plotH * 0.75);
      }
      final echoBody = Path.from(echoPath)
        ..lineTo(w, baseY)
        ..lineTo(0, baseY)
        ..close();
      canvas.drawPath(
        echoBody,
        Paint()
          ..color = color.withValues(alpha: 0.055),
      );
      canvas.drawPath(
        echoPath,
        Paint()
          ..color = color.withValues(alpha: 0.14)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      return baseY;
    }

    double yOf(int i) {
      final v = s.values[i];
      if (v > peakV) {
        peakV = v;
        peak = Offset(i * step, baseY - v * plotH);
      }
      return baseY - v * plotH;
    }

    final path = Path()..moveTo(0, yOf(0));
    for (var i = 1; i < _TrafficPainter.points; i++) {
      final x0 = (i - 1) * step, y0 = yOf(i - 1);
      final x1 = i * step, y1 = yOf(i);
      // Cubic through the midpoints — silky, no overshoot on spikes.
      final mx = (x0 + x1) / 2;
      path.cubicTo(mx, y0, mx, y1, x1, y1);
    }

    // 1) Filled glass body (vertical fade).
    final body = Path.from(path)
      ..lineTo(w, baseY)
      ..lineTo(0, baseY)
      ..close();
    final bodyRect = Rect.fromLTWH(0, h - plotH - 8, w, plotH + 8);
    canvas.drawPath(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.30),
            color.withValues(alpha: 0.10),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(bodyRect),
    );

    // 2) Edge glow (wide, faint) — the mockup's neon rim. The accent
    // (white) wave gets a GREEN-tinted rim light, exactly like the
    // mockup's white mountains edged with emerald.
    canvas.drawPath(
      path,
      Paint()
        ..color = haloColor.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // 3) Crisp edge line.
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.92)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Peak glow dot (the mockup's bright spot on each crest).
    if (peak != null && peakV > 0.08) {
      canvas.drawCircle(peak!, 2.4,
          Paint()..color = color.withValues(alpha: 0.95));
      canvas.drawCircle(
        peak!,
        7,
        Paint()
          ..color = color.withValues(alpha: 0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    return peak?.dy ?? baseY;
  }

  // ── NOW-EDGE BAR BURST ───────────────────────────────────────────────

  /// The mockup's needle cluster at "Now": vertical bars of varying
  /// heights, tallest = current speed, drawn per series.
  void _burst(Canvas canvas, Size size, _Samples s) {
    final h = size.height;
    final baseY = h - 8;
    final plotH = h * 0.66;
    final xNow = size.width - 20;

    var i = 0;
    for (final s0 in [s.up, s.down]) {
      final color = i == 0 ? green : accent;
      i++;
      // Current speed: the stronger of the raw last sample and the
      // smoothed tail — the burst must read even on a jittery link.
      final cur = math.max(s0.values.last, s0.lastRaw);
      final maxV = s0.max <= 0 ? 1.0 : s0.max;
      // Bar cluster: a few soft bars whose heights decay from the
      // current value — reads as the burst in the mockup.
      const bars = 6;
      for (var b = 0; b < bars; b++) {
        final decay = cur *
            (1.0 - b * 0.13) *
            (0.78 + 0.22 * math.sin(phase * 2 * math.pi + b * 1.1 + i * 2));
        final bh = (decay / maxV) * plotH * (0.92 - b * 0.07);
        if (bh <= 1) continue;
        final x = xNow - b * 4.2;
        final r = Rect.fromLTWH(x, baseY - bh, 2.4, bh);
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(1.2)),
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withValues(alpha: 0.95),
                color.withValues(alpha: 0.22),
              ],
            ).createShader(r),
        );
        // Neon cap on each bar.
        canvas.drawCircle(
          Offset(x + 1.2, baseY - bh),
          1.6,
          Paint()
            ..color = color.withValues(alpha: 0.9)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
        );
      }
      // A faint vertical halo at the exact NOW edge.
      canvas.drawLine(
        Offset(xNow + 8, baseY - plotH * 0.95),
        Offset(xNow + 8, baseY),
        Paint()
          ..color = color.withValues(alpha: 0.14)
          ..strokeWidth = 1.2,
      );
    }
  }

  // ── PEAK PILL ────────────────────────────────────────────────────────

  void _peakPill(
      Canvas canvas, Size size, _Samples s, double topUp, double topDown) {
    if (s.up.max <= 0 && s.down.max <= 0) return;
    // The pill rides the CURRENT series' peak: the stronger series wins
    // (mockup shows the pill over the active upload spike).
    final upWins = s.up.max >= s.down.max;
    final color = upWins ? green : accent;
    final value = upWins ? s.up.max : s.down.max;
    final anchorY = math.min(topUp, topDown);
    final fx = pillPosition ?? 0.635; // mockup's pill x position
    final cx = (size.width * fx).clamp(28.0, size.width - 28.0);

    final text = _fmtSpeed(value);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.92),
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Arrow glyph (↑ / ↓) drawn as a tiny path so no icon font is needed.
    const arrowSize = 7.0;
    final arrowDy = 0.0;
    final pillW = tp.width + arrowSize + 16;
    final pillH = 22;
    // Float the pill ABOVE the crest, following it smoothly.
    final py = (anchorY - pillH - 10).clamp(6.0, size.height - pillH - 6);
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx - pillW / 2, py, pillW, pillH.toDouble()),
      const Radius.circular(11),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.07)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final arrowCx = rect.left + 11;
    final arrowCy = rect.center.dy + arrowDy;
    final arrow = Path();
    if (upWins) {
      // ↑
      arrow
        ..moveTo(arrowCx, arrowCy - arrowSize / 2)
        ..lineTo(arrowCx - arrowSize / 2, arrowCy + arrowSize / 2)
        ..lineTo(arrowCx + arrowSize / 2, arrowCy + arrowSize / 2)
        ..close();
    } else {
      // ↓
      arrow
        ..moveTo(arrowCx, arrowCy + arrowSize / 2)
        ..lineTo(arrowCx - arrowSize / 2, arrowCy - arrowSize / 2)
        ..lineTo(arrowCx + arrowSize / 2, arrowCy - arrowSize / 2)
        ..close();
    }
    canvas.drawPath(arrow, Paint()..color = color);

    tp.paint(
      canvas,
      Offset(rect.left + arrowSize + 8, rect.center.dy - tp.height / 2),
    );
  }

  static String _fmtSpeed(double bps) {
    if (bps > 1 << 20) return '${(bps / (1 << 20)).toStringAsFixed(1)} MB/s';
    if (bps > 1 << 10) return '${(bps / (1 << 10)).toStringAsFixed(1)} KB/s';
    return '${bps.toStringAsFixed(0)} B/s';
  }

  static const int points = 64;

  @override
  bool shouldRepaint(_TrafficPainter old) =>
      old.phase != phase ||
      old.down != down ||
      old.up != up ||
      old.showPeakPill != showPeakPill ||
      old.transparentField != transparentField;
}

class _Series {
  _Series(this.values, this.max, this.lastRaw);
  final List<double> values;
  final double max;

  /// Last RAW (unsmoothed) normalized sample — the burst's truth.
  final double lastRaw;
}

class _Samples {
  _Samples({required this.up, required this.down});
  final _Series up;
  final _Series down;
}
