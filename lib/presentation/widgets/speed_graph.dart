import 'dart:math';
import 'package:flutter/material.dart';
import '../../theme/theme.dart';

/// Uplink/downlink area chart (design/COMPONENTS.md): 60 fps CustomPainter,
/// ring-buffered samples, grid at 25/50/75%.
class SpeedGraph extends StatelessWidget {
  const SpeedGraph({
    super.key,
    required this.downSamples,
    required this.upSamples,
    this.height = 96,
  });

  final List<double> downSamples;
  final List<double> upSamples;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    return CustomPaint(
      size: Size(double.infinity, height),
      painter: _SpeedPainter(
        down: downSamples,
        up: upSamples,
        lineDown: c.info,
        lineUp: c.success,
        grid: c.border,
      ),
    );
  }
}

class _SpeedPainter extends CustomPainter {
  _SpeedPainter({
    required this.down,
    required this.up,
    required this.lineDown,
    required this.lineUp,
    required this.grid,
  });

  final List<double> down;
  final List<double> up;
  final Color lineDown;
  final Color lineUp;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    _grid(canvas, size);
    _series(canvas, size, up, lineUp.withValues(alpha: 0.18), lineUp);
    _series(canvas, size, down, lineDown.withValues(alpha: 0.22), lineDown);
  }

  void _grid(Canvas canvas, Size size) {
    final p = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final f in const [0.25, 0.5, 0.75]) {
      final y = size.height * f;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  void _series(
      Canvas canvas, Size size, List<double> data, Color fill, Color line) {
    if (data.length < 2) {
      // Dashed baseline: "waiting for traffic".
      final p = Paint()
        ..color = line.withValues(alpha: 0.35)
        ..strokeWidth = 1;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(Offset(x, size.height - 1),
            Offset(min(x + 6, size.width), size.height - 1), p);
        x += 10;
      }
      return;
    }
    final maxV = data.reduce(max) == 0 ? 1.0 : data.reduce(max);
    final step = size.width / (data.length - 1);
    final path = Path()..moveTo(0, size.height);
    for (var i = 0; i < data.length; i++) {
      final y = size.height -
          (data[i] / maxV) * (size.height - 8) * 0.92 -
          4;
      path.lineTo(i * step, y);
    }
    path.lineTo(size.width, size.height);
    path.close();
    canvas.drawPath(path, Paint()..color = fill);

    final linePath = Path();
    for (var i = 0; i < data.length; i++) {
      final y = size.height -
          (data[i] / maxV) * (size.height - 8) * 0.92 -
          4;
      if (i == 0) {
        linePath.moveTo(0, y);
      } else {
        linePath.lineTo(i * step, y);
      }
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(_SpeedPainter old) =>
      old.down != down || old.up != up;
}
