import 'package:flutter/material.dart';

/// Atlanhix monoline line-type wordmark, drawn as pure strokes (no fills, no
/// gradients) — the "مشکی خطی" type logo: geometric single-weight letters with
/// round caps, uppercase, wide tracking. [strokeColor] decides the ink
/// (black on light surfaces, off-white on dark ones).
class AtlanhixLogo extends StatelessWidget {
  const AtlanhixLogo({
    super.key,
    this.height = 18,
    this.strokeColor,
    this.word = 'ATLANHIX',
    this.tracking = 0.28,
    this.strokeWidthFactor = 0.085,
  });

  final double height;
  final Color? strokeColor;
  final String word;

  /// Letter advance as a fraction of cap height (wide-tracking look).
  final double tracking;
  final double strokeWidthFactor;

  @override
  Widget build(BuildContext context) {
    final ink = strokeColor ?? Theme.of(context).textTheme.titleMedium?.color;
    return CustomPaint(
      size: _AtlasMetrics.size(word, height, tracking),
      painter: _WordmarkPainter(
        word: word,
        capHeight: height,
        ink: ink ?? const Color(0xFFE8E9ED),
        tracking: tracking,
        strokeWidthFactor: strokeWidthFactor,
      ),
    );
  }
}

/// Monoline brand mark: a thin-line globe ("atlas") with a meridian cross,
/// pure strokes, round caps — sits where the filled bolt badge used to be.
class AtlanhixMark extends StatelessWidget {
  const AtlanhixMark({super.key, this.size = 22, this.strokeColor});

  final double size;
  final Color? strokeColor;

  @override
  Widget build(BuildContext context) {
    final ink = strokeColor ?? Theme.of(context).textTheme.titleMedium?.color;
    return CustomPaint(
      size: Size.square(size),
      painter: _MarkPainter(ink ?? const Color(0xFFE8E9ED)),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.ink);
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = size.width * 0.085;
    final r = Rect.fromLTWH(p.strokeWidth, p.strokeWidth,
        size.width - 2 * p.strokeWidth, size.height - 2 * p.strokeWidth);
    final c = r.center;
    // outer circle
    canvas.drawCircle(c, r.width / 2, p);
    // vertical meridian (narrow ellipse)
    canvas.drawOval(
        Rect.fromCenter(
            center: c, width: r.width * 0.42, height: r.height), p);
    // horizontal equator chord
    canvas.drawLine(Offset(r.left + r.width * 0.06, c.dy),
        Offset(r.right - r.width * 0.06, c.dy), p);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.ink != ink;
}

class _AtlasMetrics {
  /// One em-grid: every glyph lives in a 0..GW wide, 0..GH tall box.
  static const gh = 100.0;
  static const gw = 62.0;

  static const _advance = <String, double>{
    'A': 66, 'T': 62, 'L': 56, 'N': 70, 'H': 68, 'I': 24, 'X': 64, ' ': 34,
  };

  static double advance(String ch) => (_advance[ch] ?? 66) / gh;

  static Size size(String word, double capHeight, double tracking) {
    final w = word.codeUnits
            .map((u) => advance(String.fromCharCode(u)) + tracking)
            .fold<double>(0, (a, b) => a + b) *
        capHeight;
    return Size(w, capHeight);
  }
}

class _WordmarkPainter extends CustomPainter {
  const _WordmarkPainter({
    required this.word,
    required this.capHeight,
    required this.ink,
    required this.tracking,
    required this.strokeWidthFactor,
  });

  final String word;
  final double capHeight;
  final Color ink;
  final double tracking;
  final double strokeWidthFactor;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = capHeight * strokeWidthFactor;
    canvas.save();
    canvas.scale(capHeight / _AtlasMetrics.gh);
    var x = p.strokeWidth / 2;
    for (final ch in word.split('')) {
      _glyph(canvas, p, ch, x);
      x += (_AtlasMetrics.advance(ch) * _AtlasMetrics.gh) +
          tracking * _AtlasMetrics.gh;
    }
    canvas.restore();
  }

  void _glyph(Canvas c, Paint p, String ch, double ox) {
    final g = _AtlasMetrics.gw;
    final h = _AtlasMetrics.gh;
    void line(double x1, double y1, double x2, double y2) =>
        c.drawLine(Offset(ox + x1, y1), Offset(ox + x2, y2), p);
    switch (ch) {
      case 'A':
        line(0, h, g * .5, 0);
        line(g * .5, 0, g, h);
        line(g * .18, h * .62, g * .82, h * .62);
      case 'T':
        line(0, 0, g, 0);
        line(g / 2, 0, g / 2, h);
      case 'L':
        line(0, 0, 0, h);
        line(0, h, g * .88, h);
      case 'N':
        line(0, h, 0, 0);
        line(0, 0, g, h);
        line(g, h, g, 0);
      case 'H':
        line(0, 0, 0, h);
        line(g, 0, g, h);
        line(0, h / 2, g, h / 2);
      case 'I':
        line(0, 0, 0, h);
      case 'X':
        line(0, 0, g, h);
        line(g, 0, 0, h);
      case ' ':
        break;
      default:
        line(0, h, g * .5, 0);
        line(g * .5, 0, g, h);
    }
  }

  @override
  bool shouldRepaint(_WordmarkPainter old) =>
      old.word != word ||
      old.capHeight != capHeight ||
      old.ink != ink ||
      old.tracking != tracking ||
      old.strokeWidthFactor != strokeWidthFactor;
}
