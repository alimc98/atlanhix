import 'package:flutter/material.dart';

/// v0.4.7 brand-sheet assets (user-supplied full redesign):
/// `assets/brand/logo.png`      — stacked mark + ATLANHTHIX wordmark block
/// `assets/brand/logotype_{dark,light}.png` — wordmark strip per theme
/// `assets/brand/appicon.png`   — rounded-square app icon (moon + mark)
/// `assets/brand/nav_*_dark.png` / `nav_*_light.png` — five tab icons
/// (dashboard/nodes/routing/logs/settings) as the user's cleaned tiles:
/// dark set = white glyph on charcoal tile, light set = ink glyph
/// (tinted to the light theme's textPrimary) on transparent ground.
/// `assets/brand/btn_*.png`     — CONNECT / DISCONNECT pill buttons
///
/// The v0.4.3 line-type monogram widgets below stay: they are the only
/// variant that can tint itself per-theme (assets are baked white-on-dark),
/// so compact inline marks keep using them.

/// The stacked brand block (mark over wordmark) from the redesign sheet.
/// Used where the full brand leads the layout (rail header, splash card).
class AtlanhixBrandBlock extends StatelessWidget {
  const AtlanhixBrandBlock({super.key, this.height = 96});

  final double height;

  @override
  Widget build(BuildContext context) {
    // The sheet background is the same charcoal family as the app's; the
    // PNG's own dark field blends into the surfaces without a visible box.
    return Image.asset(
      'assets/brand/logo.png',
      height: height,
      fit: BoxFit.contain,
    );
  }
}

/// The wide-tracked ATLANHTHIX wordmark strip. v0.5.0 §user: supplied as a
/// DARK variant (near-black glyphs for the light theme) and a LIGHT variant
/// (white glyphs for dark/OLED themes); picked from the ambient brightness.
class AtlanhixWordmark extends StatelessWidget {
  const AtlanhixWordmark({super.key, this.height = 16});

  final double height;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Image.asset(
      'assets/brand/logotype_${dark ? 'light' : 'dark'}.png',
      height: height,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}

/// Atlanhix line-type brand (v0.4.3 "مشکی خطی" spec): a monoline **ATHIX**
/// monogram whose letterforms deliberately overlap into an ambiguous weave —
/// pure strokes, no fills, no gradients, no globe. The crossing strokes are
/// cut through the black with a transparent gap and re-drawn in brand blue,
/// which makes the whole mark read as one glyph-cluster instead of five
/// letters. Tune [overlap] for density.
class AtlanhixLogo extends StatelessWidget {
  const AtlanhixLogo({
    super.key,
    this.height = 22,
    this.inkColor,
    this.lineColor,
    this.overlap = 0.38,
  });

  final double height;
  final Color? inkColor;
  final Color? lineColor;

  /// 0 = spaced letters, .5 = dense interlocked weave.
  final double overlap;

  @override
  Widget build(BuildContext context) {
    final ink = inkColor ?? Theme.of(context).textTheme.titleMedium?.color;
    final lines = lineColor ?? Theme.of(context).colorScheme.primary;
    return CustomPaint(
      size: _Metrics.size(height, overlap),
      painter: _WeavePainter(
        ink: ink ?? const Color(0xFF101216),
        lines: lines,
        capHeight: height,
        overlap: overlap,
      ),
    );
  }
}

/// Glyph grid: every letter lives in a box [gw] wide, [gh] = cap height.
class _Metrics {
  static const gh = 100.0;
  static const _w = <String, double>{
    'A': 66, 'T': 62, 'H': 68, 'I': 22, 'X': 64,
  };

  static double advance(String ch) => _w[ch] ?? 66;
  static const word = 'ATHIX';

  static double total(double overlap) {
    var x = 0.0;
    for (var i = 0; i < word.length; i++) {
      final adv = advance(word[i]);
      x += i == word.length - 1 ? adv : adv * (1 - overlap);
    }
    return x;
  }

  static Size size(double capHeight, double overlap) =>
      Size(total(overlap) * capHeight / gh, capHeight * 1.12);
}

class _WeavePainter extends CustomPainter {
  const _WeavePainter({
    required this.ink,
    required this.lines,
    required this.capHeight,
    required this.overlap,
  });

  final Color ink;
  final Color lines;
  final double capHeight;
  final double overlap;

  static const _blue = {'T', 'X'};

  /// Strokes of one glyph in its local box (0..w, 0..gh).
  static List<List<double>> _strokes(String ch) {
    const gh = _Metrics.gh;
    final w = _Metrics.advance(ch);
    switch (ch) {
      case 'A':
        return [
          [0, gh, w / 2, 0],
          [w / 2, 0, w, gh],
          [w * 0.18, gh * 0.62, w * 0.82, gh * 0.62],
        ];
      case 'T':
        return [
          [0, 0, w, 0],
          [w / 2, 0, w / 2, gh],
        ];
      case 'H':
        return [
          [0, 0, 0, gh],
          [w, 0, w, gh],
          [0, gh / 2, w, gh / 2],
        ];
      case 'I':
        return [
          [w / 2, 0, w / 2, gh],
        ];
      case 'X':
        return [
          [0, 0, w, gh],
          [w, 0, 0, gh],
        ];
    }
    return const [];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = capHeight * 0.085;
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = stroke;
    final cutter = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke * 2.4;

    canvas.save();
    canvas.translate(0, capHeight * 0.06);
    canvas.scale(capHeight / _Metrics.gh);
    // Weave needs its own layer so BlendMode.clear punches the ink, not bg.
    final bounds = Rect.fromLTWH(-2, -12, _Metrics.total(overlap) + 4,
        _Metrics.gh + 24);
    canvas.saveLayer(bounds, Paint());

    final xs = <String, double>{};
    var x = 0.0;
    for (var i = 0; i < _Metrics.word.length; i++) {
      final ch = _Metrics.word[i];
      xs[ch] = x;
      x += _Metrics.advance(ch) * (1 - overlap);
    }

    // Pass 1 — ink glyphs.
    base.color = ink;
    for (var i = 0; i < _Metrics.word.length; i++) {
      final ch = _Metrics.word[i];
      if (_blue.contains(ch)) continue;
      _glyph(canvas, base, ch, xs[ch]!);
    }
    // Pass 2 — blue strokes: first punch a gap through the ink, then draw.
    for (final ch in _blue) {
      _glyph(canvas, cutter, ch, xs[ch]!);
    }
    base.color = lines;
    for (final ch in _blue) {
      _glyph(canvas, base, ch, xs[ch]!);
    }
    canvas.restore(); // layer
    canvas.restore();
  }

  void _glyph(Canvas c, Paint p, String ch, double ox) {
    for (final s in _strokes(ch)) {
      c.drawLine(Offset(ox + s[0], s[1]), Offset(ox + s[2], s[3]), p);
    }
  }

  @override
  bool shouldRepaint(_WeavePainter old) =>
      old.ink != ink ||
      old.lines != lines ||
      old.capHeight != capHeight ||
      old.overlap != overlap;
}

/// Small monoline shield used by the WARP chain card — pure stroke, same
/// design language as the wordmark.
class AtlanhixShieldMark extends StatelessWidget {
  const AtlanhixShieldMark({super.key, this.size = 22, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? Theme.of(context).textTheme.titleMedium?.color;
    return CustomPaint(
      size: Size.square(size),
      painter: _ShieldPainter(ink ?? const Color(0xFF101216)),
    );
  }
}

class _ShieldPainter extends CustomPainter {
  const _ShieldPainter(this.ink);
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = size.width * 0.09;
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w * .5, h * .06)
      ..lineTo(w * .92, h * .22)
      ..lineTo(w * .92, h * .5)
      ..cubicTo(w * .92, h * .74, w * .74, h * .9, w * .5, h * .97)
      ..cubicTo(w * .26, h * .9, w * .08, h * .74, w * .08, h * .5)
      ..lineTo(w * .08, h * .22)
      ..close();
    canvas.drawPath(path, p);
    // inner tick
    canvas.drawPath(
        Path()
          ..moveTo(w * .3, h * .5)
          ..lineTo(w * .45, h * .66)
          ..lineTo(w * .72, h * .34), p);
  }

  @override
  bool shouldRepaint(_ShieldPainter old) => old.ink != ink;
}

/// v0.4.4 brand-sheet icon: the standalone geometric 'A' — two thick
/// angled strokes that deliberately DON'T touch at the apex + a mint
/// crossbar. Monoline, no fills; matches the launcher adaptive icon.
class AtlanhixAMark extends StatelessWidget {
  const AtlanhixAMark({super.key, this.size = 26, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? Theme.of(context).textTheme.titleMedium?.color ??
        const Color(0xFFE8E9ED);
    return CustomPaint(
      size: Size.square(size),
      painter: _AMarkPainter(ink),
    );
  }
}

class _AMarkPainter extends CustomPainter {
  const _AMarkPainter(this.ink);
  final Color ink;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..color = ink
      ..strokeWidth = w * 0.10;
    final mint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF4FE0B7)
      ..strokeWidth = w * 0.085;
    final apexGap = w * 0.085, spread = w * 0.36, cx = w / 2;
    canvas.drawLine(Offset(cx - apexGap, w * 0.14),
        Offset(cx - spread, w * 0.88), stroke);
    canvas.drawLine(Offset(cx + apexGap, w * 0.14),
        Offset(cx + spread, w * 0.88), stroke);
    final y = w * 0.62;
    canvas.drawLine(Offset(cx - spread * 0.62, y),
        Offset(cx + spread * 0.62, y), mint);
  }

  @override
  bool shouldRepaint(_AMarkPainter old) => old.ink != ink;
}
