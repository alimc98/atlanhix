// v0.5.2 §globe — THE DASHBOARD GLOBE ("2D map morphs into 3D globe",
// Vercel-style). A globe of ~17.7 k sampled land points rotates under the
// dashboard hero; when the tunnel connects it can UNFOLD from a flat map
// plane onto the sphere (the reference spell) and draws the great-circle
// ARC home → exit (Iran → Romania) with pings on both anchors.
//
// Design contract (design/DESIGN_SYSTEM.md):
//  * line-type monochrome language — land dots are hairline ink on the
//    near-black hero, the arc is the single bright stroke,
//  * every animated surface parks when hidden — TickerMode upstream gates
//    the repeating controller (same pattern as TrafficGraph),
//  * honest states: no fix → calm un-anchored globe; never fake data.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../globe/land_points.dart';

/// One geographic anchor the globe draws.
class GlobeAnchor {
  const GlobeAnchor({
    required this.lat,
    required this.lon,
    required this.kind,
    this.label = '',
    this.active = false,
  });

  final GlobeAnchorKind kind;
  final double lat;
  final double lon;
  final String label;

  /// The ACTIVE node's exit pin gets the larger pulse.
  final bool active;
}

enum GlobeAnchorKind { home, exit }

/// Which intro choreography the globe plays for the hero.
enum GlobeIntro { none, unfold }

/// Camera yaw/pitch for centering a lat/lon toward the viewer.
/// With the rotation used in [_GlobePainter], z is maximal (facing the
/// viewer) exactly at yaw = −lon, pitch = lat.
double _yawFor(double lat, double lon) => -lon * math.pi / 180;
double _pitchFor(double lat, double lon) =>
    -(lat.clamp(-60, 60).toDouble()) * math.pi / 180 * 0.9;

/// Mutable camera the state ticks and the painter reads per frame — one
/// tiny object instead of rebuilding the painter at 60 fps.
class _Camera {
  double yaw = 0;
  double pitch = 0.34;
  double unfold = 1; // 0 = flat map plane, 1 = full sphere
}

/// v0.5.2 §globe — the point-cloud globe widget.
///
/// Usage (dashboard hero):
///   DashboardGlobe(
///     intro: connecting ? GlobeIntro.unfold : GlobeIntro.none,
///     anchors: [homeAnchor, exitAnchor],
///   )
class DashboardGlobe extends StatefulWidget {
  const DashboardGlobe({
    super.key,
    this.anchors = const [],
    this.intro = GlobeIntro.none,
    this.autoRotate = true,
    this.focusLat,
    this.focusLon,
    this.initialYaw,
    this.initialPitch = 0.34,
    this.pointOpacity = 1.0,
    this.onIntroDone,
  });

  final List<GlobeAnchor> anchors;

  /// [GlobeIntro.unfold] plays the flat-map → sphere morph once.
  final GlobeIntro intro;

  /// Idle yaw drift (set false when a tunnel arc owns the focus).
  final bool autoRotate;

  /// Optional camera target: when the tunnel connects, the globe eases its
  /// yaw/pitch so the ARC's region faces the viewer.
  final double? focusLat;
  final double? focusLon;

  /// Deterministic starting yaw — tests pass a constant, production leaves
  /// it null (randomized so two app opens never show the same hemisphere).
  final double? initialYaw;

  /// Camera tilt (rad). 0.34 ≈ the reference art's pleasant 3/4 view.
  final double initialPitch;

  /// Overall alpha of the land cloud (the hero fades it into its bottom
  /// gradient exactly like the old moon artwork did).
  final double pointOpacity;

  /// Fired ONCE when the unfold morph completes — the dashboard flips its
  /// first-paint flag so a later connect re-plays the spell cleanly.
  final VoidCallback? onIntroDone;

  @override
  State<DashboardGlobe> createState() => _DashboardGlobeState();
}

class _DashboardGlobeState extends State<DashboardGlobe>
    with SingleTickerProviderStateMixin {
  // Repeats forever (drives rotation + anchor pulse); TickerMode upstream
  // parks it while the hero is offscreen. The unfold reads elapsed time.
  // v0.5.3 §perf-fix: the painter's per-frame cost is ~17.7k circle draws;
  // a smooth slow rotation needs nowhere near 60 fps. FRAMES ARE SKIPPED —
  // only every Nth tick notifies the RepaintBoundary (a yaw-step
  // accumulator keeps the rotation speed identical). The UNFOLD morph and
  // the connect FOCUS still repaint every frame (they are brief and they
  // animate fast) — throttle applies only to the steady-state rotation.
  static const _throttleEvery = 4; // ≈15 repaints/s instead of 60
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();
  int _tickCount = 0;

  static const _unfoldDuration = Duration(milliseconds: 4200);

  final _Camera _cam = _Camera();
  double _focusYaw = 0;
  double _focusPitch = 0.34;
  bool _hasFocus = false;
  DateTime? _unfoldStart;
  bool _introDoneFired = false;

  /// The gated listenable the painter subscribes to (built after _ctrl).
  late final _ThrottledListenable _throttledCtrl =
      _ThrottledListenable(_ctrl, _throttleEvery);

  @override
  void initState() {
    super.initState();
    _cam.yaw = widget.initialYaw ?? (math.Random().nextDouble() * 2 * math.pi);
    _cam.pitch = widget.initialPitch;
    _focusYaw = _cam.yaw;
    _focusPitch = widget.initialPitch;
    if (widget.intro == GlobeIntro.unfold) _beginUnfold();
    _ctrl.addListener(_tick);
  }

  void _beginUnfold() {
    _unfoldStart = DateTime.now();
    _cam.unfold = 0;
  }

  void _tick() {
    // Unfold progress from wall clock (survives controller restarts).
    // NOTE: the unfold path repaints EVERY frame (fast animation) — the
    // repaint throttle below only applies to the steady rotation.
    final start = _unfoldStart;
    if (start != null) {
      final t = DateTime.now().difference(start).inMicroseconds /
          _unfoldDuration.inMicroseconds;
      if (t >= 1) {
        _cam.unfold = 1;
        _unfoldStart = null;
        if (!_introDoneFired) {
          _introDoneFired = true;
          // Post-frame: the callback flips the dashboard's intro flag via
          // setState — safe here (tick runs inside the frame already built).
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.onIntroDone?.call();
          });
        }
      } else {
        // Staggered ease-out: most of the morph lands in the first half.
        _cam.unfold = 1 - math.pow(1 - t, 3).toDouble();
      }
    }
    if (widget.autoRotate) {
      // A slow breath, not a fan (~0.02 rad/s).
      _cam.yaw += 0.00035;
    }
    if (_hasFocus) {
      _cam.yaw += (_focusYaw - _cam.yaw) * 0.045;
      _cam.pitch += (_focusPitch - _cam.pitch) * 0.04;
    }
  }

  @override
  void didUpdateWidget(covariant DashboardGlobe old) {
    super.didUpdateWidget(old);
    if (widget.intro == GlobeIntro.unfold && old.intro == GlobeIntro.none) {
      _beginUnfold();
    }
    if (widget.intro == GlobeIntro.none && old.intro == GlobeIntro.unfold) {
      _cam.unfold = 1;
      _unfoldStart = null;
    }
    // New focus target (e.g. the tunnel just connected / node changed).
    if (widget.focusLat != old.focusLat || widget.focusLon != old.focusLon) {
      if (widget.focusLat != null && widget.focusLon != null) {
        _hasFocus = true;
        final targetYaw = _yawFor(widget.focusLat!, widget.focusLon!);
        // Take the SHORT way around the sphere.
        var dy = targetYaw - _cam.yaw;
        while (dy > math.pi) {
          dy -= 2 * math.pi;
        }
        while (dy < -math.pi) {
          dy += 2 * math.pi;
        }
        _focusYaw = _cam.yaw + dy;
        _focusPitch = _pitchFor(widget.focusLat!, widget.focusLon!);
      } else {
        _hasFocus = false;
      }
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_tick);
    _throttledCtrl.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // v0.5.3 §perf-fix: the painter listens to _throttledCtrl (a gate that
    // only forwards every Nth tick), so the steady rotation repaints at
    // ~15 fps instead of 60 — the unfold/focus fast paths still go through
    // _ctrl directly (every frame) via the same painter listenable.
    final animatingFast = _unfoldStart != null || _hasFocus;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _GlobePainter(
          repaint: animatingFast ? _ctrl : _throttledCtrl,
          camera: _cam,
          ext: ThemeExt.of(context),
          anchors: widget.anchors,
          pointOpacity: widget.pointOpacity,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Listenable gate: forwards a listener ping only every [_Every.th] tick.
/// Cheap (an int compare per tick) and keeps the rotation visually smooth
/// while cutting the painter's 17.7k-draw cost by the same factor.
class _ThrottledListenable extends ChangeNotifier {
  _ThrottledListenable(this._source, this.every) {
    _source.addListener(_onTick);
  }
  final Listenable _source;
  final int every;
  int _n = 0;

  void _onTick() {
    _n++;
    if (_n % every == 0) notifyListeners();
  }

  @override
  void dispose() {
    _source.removeListener(_onTick);
    super.dispose();
  }
}

class _GlobePainter extends CustomPainter {
  _GlobePainter({
    required Listenable repaint,
    required this.camera,
    required this.ext,
    required this.anchors,
    required this.pointOpacity,
  }) : super(repaint: repaint) {
    _precompute();
  }

  final _Camera camera;
  final ThemeExt ext;
  final List<GlobeAnchor> anchors;
  final double pointOpacity;

  // Precomputed unit-sphere vectors + flat-map positions for every land
  // point. Per-frame cost is then ~10 flops per point — no per-point trig.
  late final Float32List _sx, _sy, _sz, _fu, _fv;
  int _n = 0;

  void _precompute() {
    _n = kLandPointCount;
    _sx = Float32List(_n);
    _sy = Float32List(_n);
    _sz = Float32List(_n);
    _fu = Float32List(_n);
    _fv = Float32List(_n);
    const d2r = math.pi / 180;
    for (var i = 0; i < _n; i++) {
      final lat = kLandLats[i] * d2r;
      final lon = kLandLons[i] * d2r;
      final cl = math.cos(lat);
      _sx[i] = cl * math.sin(lon);
      _sy[i] = math.sin(lat);
      _sz[i] = cl * math.cos(lon);
      _fu[i] = (kLandLons[i] + 180) / 360;
      _fv[i] = (90 - kLandLats[i]) / 180;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final short = size.shortestSide;
    final cx = size.width / 2;
    final cy = size.height * 0.46;
    final r = math.min(short * 0.46, size.height * 0.42);

    // ── Limb glow (reference art: soft halo around the sphere) ──
    final glow = Paint()
      ..shader = ui.Gradient.radial(
        Offset(cx, cy),
        r * 1.45,
        [
          ext.accentSoft.withValues(alpha: 0.55 * pointOpacity),
          ext.accent.withValues(alpha: 0.03 * pointOpacity),
          const Color(0x00000000),
        ],
        [0.55, 0.82, 1.0],
      );
    canvas.drawCircle(Offset(cx, cy), r * 1.45, glow);

    // Sphere body — barely lifted dark disc so the dots read against it.
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()..color = ext.surfaceSunken.withValues(alpha: 0.72),
    );
    // Hairline rim.
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = ext.border.withValues(alpha: 0.9),
    );

    final u = camera.unfold;
    _paintLand(canvas, size, cx, cy, r, u);
    if (u < 0.999) _paintMapFrame(canvas, cx, cy, r, u);

    // Graticule + anchors + arc only once the sphere has formed.
    if (u > 0.35) {
      _paintGraticule(canvas, cx, cy, r, (u - 0.35) / 0.65);
      if (anchors.length >= 2) {
        _paintArc(canvas, cx, cy, r, anchors[0], anchors[1]);
      }
      for (final a in anchors) {
        _paintAnchor(canvas, cx, cy, r, a);
      }
    }
  }

  /// Rotates a unit vector by the camera and projects it.
  /// Returns screen offset + view-space z (1 = facing viewer).
  (Offset, double)? _projectUnit(
      double sx, double sy, double sz, double lift, double cx, double cy,
      double r) {
    final cy_ = math.cos(camera.yaw), sy_ = math.sin(camera.yaw);
    final x1 = sx * cy_ + sz * sy_;
    final z1 = -sx * sy_ + sz * cy_;
    final cp = math.cos(camera.pitch), sp = math.sin(camera.pitch);
    final y2 = sy * cp - z1 * sp;
    final z2 = sy * sp + z1 * cp;
    if (z2 < -0.3) return null; // far backside — skip entirely
    final rr = r * lift;
    return (Offset(cx + x1 * rr, cy - y2 * rr), z2);
  }

  void _paintLand(
      Canvas canvas, Size size, double cx, double cy, double r, double u) {
    final mapW = r * 3.4;
    final mapH = mapW / 2;
    final left = cx - mapW / 2;
    final top = cy - mapH / 2;
    final paint = Paint();

    // Adaptive density: on small spheres every other point keeps the SAME
    // look at half the fill cost (17.7 k circles/frame is real work).
    final stride = r < 150 ? 2 : 1;
    for (var i = 0; i < _n; i += stride) {
      // Staggered per-point morph: a wave sweeps west → east across the
      // map as it folds onto the sphere (the reference spell's motion).
      final p = _projectUnit(_sx[i], _sy[i], _sz[i], 1.0, cx, cy, r);
      Offset sphere;
      double depth;
      if (p == null) {
        if (u >= 1) continue;
        // Point is on the far backside — during the morph it is still
        // visible on the flat plane, so fall back to the flat position.
        sphere = Offset(left + _fu[i] * mapW, top + _fv[i] * mapH);
        depth = 0.25;
      } else {
        sphere = p.$1;
        depth = p.$2;
      }
      final wave = _fu[i] * 0.6; // left edge folds first
      final tp = u >= 1
          ? 1.0
          : ((u - wave) / 0.4).clamp(0.0, 1.0);
      if (tp <= 0) {
        // Still fully flat.
        paint.color = ext.textPrimary.withValues(alpha: 0.40 * pointOpacity);
        canvas.drawCircle(
            Offset(left + _fu[i] * mapW, top + _fv[i] * mapH), 1.1, paint);
        continue;
      }
      final fx = left + _fu[i] * mapW;
      final fy = top + _fv[i] * mapH;
      final x = fx + (sphere.dx - fx) * tp;
      final y = fy + (sphere.dy - fy) * tp;
      final fade = (depth + 1) / 2; // 0 = rim, 1 = facing viewer
      final a = (0.14 + 0.42 * fade) * pointOpacity * (0.5 + 0.5 * tp);
      paint.color = ext.textPrimary.withValues(alpha: a);
      canvas.drawCircle(Offset(x, y), 0.9 + 0.6 * fade, paint);
    }
  }

  void _paintMapFrame(
      Canvas canvas, double cx, double cy, double r, double u) {
    final mapW = r * 3.4;
    final mapH = mapW / 2;
    final rect = Rect.fromLTWH(cx - mapW / 2, cy - mapH / 2, mapW, mapH);
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = ext.border.withValues(alpha: 0.5 * (1 - u)),
    );
  }

  void _paintGraticule(
      Canvas canvas, double cx, double cy, double r, double alpha) {
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = ext.border.withValues(alpha: 0.28 * alpha);
    // Latitude rings.
    for (final latDeg in const [-60, -30, 0, 30, 60]) {
      final path = Path();
      var pen = false;
      for (var lon = -180; lon <= 180; lon += 6) {
        const d2r = math.pi / 180;
        final cl = math.cos(latDeg * d2r);
        final p = _projectUnit(cl * math.sin(lon * d2r), math.sin(latDeg * d2r),
            cl * math.cos(lon * d2r), 1.0, cx, cy, r);
        if (p == null || p.$2 < 0) {
          pen = false;
          continue;
        }
        if (!pen) {
          path.moveTo(p.$1.dx, p.$1.dy);
          pen = true;
        } else {
          path.lineTo(p.$1.dx, p.$1.dy);
        }
      }
      canvas.drawPath(path, grid);
    }
  }

  /// Slerp between the two anchors lifted by sin(t·π) — the classic flight
  /// arc, drawn as ONE bright stroke (the single saturated element).
  void _paintArc(Canvas canvas, double cx, double cy, double r,
      GlobeAnchor a, GlobeAnchor b) {
    const d2r = math.pi / 180;
    final la1 = a.lat * d2r, lo1 = a.lon * d2r;
    final la2 = b.lat * d2r, lo2 = b.lon * d2r;
    final va = (math.cos(la1) * math.cos(lo1), math.cos(la1) * math.sin(lo1),
        math.sin(la1));
    final vb = (math.cos(la2) * math.cos(lo2), math.cos(la2) * math.sin(lo2),
        math.sin(la2));
    final dot = (va.$1 * vb.$1 + va.$2 * vb.$2 + va.$3 * vb.$3)
        .clamp(-1.0, 1.0);
    final omega = math.acos(dot);
    final so = math.sin(omega);
    if (so < 1e-6) return; // identical points — no arc

    final path = Path();
    var pen = false;
    const steps = 64;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final w1 = math.sin((1 - t) * omega) / so;
      final w2 = math.sin(t * omega) / so;
      final x = w1 * va.$1 + w2 * vb.$1;
      final y = w1 * va.$2 + w2 * vb.$2;
      final z = w1 * va.$3 + w2 * vb.$3;
      final lift = 1 + 0.35 * math.sin(t * math.pi);
      final p = _projectUnit(x, y, z, lift, cx, cy, r);
      if (p == null) {
        pen = false;
        continue;
      }
      if (!pen) {
        path.moveTo(p.$1.dx, p.$1.dy);
        pen = true;
      } else {
        path.lineTo(p.$1.dx, p.$1.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = ext.textPrimary.withValues(alpha: 0.92),
    );
  }

  void _paintAnchor(
      Canvas canvas, double cx, double cy, double r, GlobeAnchor a) {
    const d2r = math.pi / 180;
    final cl = math.cos(a.lat * d2r);
    final p = _projectUnit(cl * math.sin(a.lon * d2r), math.sin(a.lat * d2r),
        cl * math.cos(a.lon * d2r), 1.0, cx, cy, r);
    if (p == null || p.$2 < -0.05) return;
    final color = switch (a.kind) {
      GlobeAnchorKind.home => ext.success,
      GlobeAnchorKind.exit => ext.textPrimary,
    };
    final pt = p.$1;
    // Breathing halo (the repeating controller drives the phase).
    final phase = (DateTime.now().millisecondsSinceEpoch % 2400) / 2400;
    final haloR = (a.active ? 13 : 9) + 3 * math.sin(phase * 2 * math.pi);
    canvas.drawCircle(
      pt,
      haloR,
      Paint()..color = color.withValues(alpha: 0.14),
    );
    canvas.drawCircle(pt, 2.4, Paint()..color = color.withValues(alpha: 0.95));
  }

  @override
  bool shouldRepaint(_GlobePainter old) =>
      old.anchors != anchors ||
      old.pointOpacity != pointOpacity ||
      old.ext != ext;
}

// Kept out of the class: distance formatting shared with the node card.
String fmtRouteKm(double km) =>
    '${km.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')} km';
