// v0.5.4 §globe3d — ATLANHIX GLOBE VIEW. The signature visual: a REAL GPU
// planet (fragment shader: dark rocky surface, rim light, atmosphere,
// night-lights) with the user→node great-circle ROUTE and its packet flow
// drawn by an overlay painter, rotating slowly and reacting to the real
// VPN connection state.
//
// Architecture contract:
//  * ZERO VPN coupling — the widget receives plain values (source,
//    destination, visual state) and never imports application/ or settings/.
//  * GPU-first, CPU-fallback: when the fragment-program asset fails to
//    load (test envs, shader compiler issues) the painter draws the same
//    planet procedurally on the CPU — the look survives, the FPS budget
//    drops. A nullable [ui.FragmentProgram] drives the switch.
//  * One controller object per widget instance mutates camera/phase fields;
//    the overlay painter subscribes to a throttled listenable so steady
//    rotation costs ~15 repaints/s, not 60 (same perf pattern as the
//    dashboard point globe, v0.5.3 §perf-fix).
//  * Gestures: horizontal drag = yaw, vertical drag = tilt, release =
//    inertia then auto-rotation resumes. No scroll interference: the
//    backdrop instance is wrapped in IgnorePointer by its owner.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import 'globe_geo.dart';
import 'land_mask.dart';

/// Visual states the globe animates through — mapped 1:1 from the REAL
/// connection phases by the owner (shell/dashboard). Never invented here.
enum GlobeVisualState { idle, connecting, connected, disconnecting, error }

/// One tunable bundle for the whole globe (no scattered magic numbers).
class AtlanhixGlobeConfig {
  const AtlanhixGlobeConfig({
    this.autoRotate = true,
    this.rotationSpeed = 0.105, // rad/s → one revolution ≈ 60 s
    this.interactive = true,
    this.showRoute = true,
    this.showAtmosphere = true,
    this.showPacketFlow = true,
    this.showOrbit = true,
    this.routeAnimationEnabled = true,
    this.maxFps = 30.0,
    this.shaderAsset = 'assets/shaders/planet.frag',
  });

  final bool autoRotate;
  final double rotationSpeed;
  final bool interactive;
  final bool showRoute;
  final bool showAtmosphere;
  final bool showPacketFlow;
  final bool showOrbit;
  final bool routeAnimationEnabled;

  /// Steady-state repaint ceiling (the shader quad is cheap; 30 fps is
  /// indistinguishable at these rotation speeds and halves the power draw).
  final double maxFps;
  final String shaderAsset;

  static const AtlanhixGlobeConfig standard = AtlanhixGlobeConfig();
}

/// ─────────────────────────────────────────────────────────────────────
/// The widget.
/// ─────────────────────────────────────────────────────────────────────
class AtlanhixGlobeView extends StatefulWidget {
  const AtlanhixGlobeView({
    super.key,
    this.source,
    this.destination,
    this.state = GlobeVisualState.idle,
    this.config = AtlanhixGlobeConfig.standard,
    this.initialYaw,
    this.error = false,
  });

  /// The user's approximate origin (country centroid is fine). When null
  /// the globe stays calm and un-anchored — no fake home.
  final GlobeLocation? source;

  /// The selected node's location. Null = no destination yet.
  final GlobeLocation? destination;

  final GlobeVisualState state;
  final AtlanhixGlobeConfig config;

  /// Deterministic start yaw (tests); production randomizes.
  final double? initialYaw;

  /// Drives the error visual state (subtle rim breath, not a red screen).
  final bool error;

  @override
  State<AtlanhixGlobeView> createState() => AtlanhixGlobeViewState();
}

/// Public state (the backdrop needs to nudge the camera on node changes).
class AtlanhixGlobeViewState extends State<AtlanhixGlobeView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat();

  // Camera state (radians; yaw wraps).
  late double _yaw = widget.initialYaw ?? _randomYaw;
  double _pitch = 0.30;
  double _yawVelocity = 0;
  double _tiltVelocity = 0;

  // Route draw progress 0..1 and its target (1 when the route shows).
  double _routeT = 0;
  double _routeTarget = 0;
  // Source/destination appear 0..1 (staggered dots fade-in on connecting).
  double _sourceA = 0;
  double _destA = 0;

  // Destination transition: from → to with an eased t (no teleporting).
  GlobeLocation? _fromDest;
  GlobeLocation? _toDest;
  double _destMorph = 1; // 1 = settled on _toDest
  GlobeLocation? get _effectiveDest {
    if (_toDest == null) return null;
    if (_fromDest == null || _destMorph >= 1) return _toDest;
    // Great-circle interpolation between the old and new destination.
    final (la, lo) = slerpLatLon(
        _fromDest!.lat, _fromDest!.lon, _toDest!.lat, _toDest!.lon,
        Curves.easeInOutCubic.transform(_destMorph));
    return _toDest!.copyWith(lat: la, lon: lo);
  }

  // Focus: while a route exists, the camera gently centers on the arc.
  bool _hasFocus = false;
  double _focusYaw = 0;
  double _focusPitch = 0.30;

  // Gestures.
  bool _dragging = false;

  // Shader program (null → CPU fallback painter).
  ui.FragmentShader? _shader;
  ui.Image? _landMask;

  /// v0.5.5 §user-fix: the mask is baked ONCE and kept EVEN when the
  /// shader asset fails — the CPU fallback paints REAL CONTINENTS from
  /// it instead of a featureless gradient ball. (The old catch threw the
  /// bake away with the program, which is how "the globe never came / was
  /// too pale" looked on devices whose shader compile failed.)
  ui.Image? get landMask => _landMask ?? _landMaskOnly;
  ui.Image? _landMaskOnly;

  // Steady repaint throttle + route/packet phase advanced per tick.
  double _phase = 0; // 0..1 packets + pulses driver
  Duration _accum = Duration.zero;
  double get _minFrameMs => 1000 / widget.config.maxFps;

  // ── Monotonic shader clock (seconds) ──────────────────────────────────
  // Drives the planet shader's purely decorative sparkle channels (star
  // twinkle, city-light shimmer, error breath).
  //
  // v0.5.6 §globe-fix: this used to be fed straight from the wall clock —
  // `(DateTime.now().millisecondsSinceEpoch % 100000) / 1000` — which was
  // wrong three ways: it JUMPED BACKWARDS whenever the OS corrected the
  // clock or the device suspended, it POPPED every 100 s as the modulo
  // wrapped mid-twinkle, and it made every painted frame
  // non-deterministic (unusable in golden/widget tests). Accumulating dt
  // is smooth and monotonic, pauses along with the ticker when the app is
  // backgrounded, and [kShaderTimeWrap] only exists to keep float32
  // precision tight inside the shader — a wrap on a twinkle term is
  // imperceptible, unlike the old 100 s wall-clock pop.
  static const double kShaderTimeWrap = 1000.0;
  double _shaderTime = 0;

  /// Monotonic shader clock in seconds (see [_shaderTime]). Exposed so a
  /// test can prove the painter never samples the wall clock again.
  double get shaderTime => _shaderTime;
  double get shaderTimeWrap => kShaderTimeWrap;

  /// Route draw progress, 0..1. Exposed so a test can assert the state
  /// machine really retracts the arc — not merely that nothing threw.
  double get routeProgress => _routeT;

  late final _ThrottledListenable _throttle =
      _ThrottledListenable(_ctrl, _minFrameMs);

  static double get _randomYaw =>
      math.Random().nextDouble() * 2 * math.pi;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _routeTarget =
        widget.config.showRoute && _routeVisible ? 1 : 0;
    _sourceA = _routeTarget;
    _destA = _routeTarget;
    _ctrl.addListener(_tick);
    _loadAssets();
  }

  /// v0.5.6 §globe-fix: `disconnecting` used to count as "route visible",
  /// so the teardown kept drawing the full-strength arc while the tunnel
  /// was already going down. The spec for DISCONNECTING is "packet
  /// animation stops, route gradually fades, destination highlight fades" —
  /// so the route now retracts during teardown and only holds while there
  /// is something real to show. `error` deliberately KEEPS the route: a
  /// failed connect still shows where it was trying to reach.
  bool get _routeVisible =>
      widget.destination != null &&
      widget.state != GlobeVisualState.idle &&
      widget.state != GlobeVisualState.disconnecting;

  Future<void> _loadAssets() async {
    // v0.5.5 §user-fix: the TWO assets load INDEPENDENTLY now. The old
    // single try/catch made a shader-compile failure discard the baked
    // land mask too — the fallback then painted a blank gradient orb
    // ("همیشه نمی‌آید، اگر هم بیاید خیلی کم‌رنگ است").
    ui.Image? mask;
    try {
      mask = await landMaskImage();
    } catch (_) {
      mask = null; // bake failure is survivable — gradient fallback
    }
    try {
      final program =
          await ui.FragmentProgram.fromAsset(widget.config.shaderAsset);
      if (!mounted) return;
      setState(() {
        _shader = program.fragmentShader();
        _landMask = mask;
      });
    } catch (_) {
      // CPU fallback keeps the visuals alive (test VMs, old GPUs) — now
      // with real continents via [landMask].
      if (!mounted) return;
      setState(() {
        _landMask = null;
        _landMaskOnly = mask;
      });
    }
  }

  @override
  void didUpdateWidget(covariant AtlanhixGlobeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // State transitions that end a route stop the focus pull.
    if (widget.state != oldWidget.state) {
      _routeTarget =
          widget.config.showRoute && _routeVisible ? 1 : 0;
    }
    // Destination changed → smooth great-circle morph (no teleport).
    final d = widget.destination;
    final cur = _toDest;
    if (d?.lat != cur?.lat || d?.lon != cur?.lon) {
      if (d == null) {
        _fromDest = cur;
        _toDest = null;
        _destMorph = cur == null ? 1 : 0;
      } else if (cur != null) {
        _fromDest = cur;
        _toDest = d;
        _destMorph = 0;
      } else {
        _fromDest = null;
        _toDest = d;
        _destMorph = 1;
      }
      _hasFocus = false; // re-acquire after the morph
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Battery: stop the ticker entirely when backgrounded.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _ctrl.stop();
      // v0.5.6 §globe-fix: drop the dt baseline too. Otherwise the first
      // frame after resume has to absorb the entire backgrounded interval
      // and fast-forwards rotation/packets (clamped, but it still lurches).
      _lastTickAt = null;
    } else if (state == AppLifecycleState.resumed && mounted) {
      _lastTickAt = null;
      // TickerMode gate: only resume when the widget tree allows it.
      // (value getter on the listenable — v3.35+ deprecates getNotifier,
      // but the pattern below reads through it without the deprecated
      // ``enabled`` field: simply resume; TickerMode gates the ticker
      // upstream anyway when the tree is disabled.)
      _ctrl.repeat();
    }
  }

  // v0.5.6 §globe-fix: last frame timestamp, used to derive a real `dt`.
  // The tick used to hardcode `dt = 1/60`, which silently rewrote the
  // animation speed on any device that is NOT 60 Hz (a 120 Hz phone ran
  // the globe at double speed, a 30 Hz throttled one at half) — and the
  // route-draw/fade constants were per-FRAME, not per-second, so the same
  // connect took different amounts of wall-clock time everywhere.
  DateTime? _lastTickAt;

  /// Seconds elapsed since the previous frame, clamped so a long stall
  /// (GC pause, a blocked frame) cannot teleport the animation forward.
  ///
  /// v0.5.6 §globe-fix: the source is deliberately the TICKER's frame
  /// delta, not `DateTime.now()`. Two reasons:
  ///   * the ticker is already gated by TickerMode and stopped on
  ///     background, so resuming starts from a clean baseline instead of
  ///     absorbing the whole backgrounded interval as one huge dt;
  ///   * under `flutter_test` the fake clock drives the ticker, so
  ///     `pump()` advances the animation deterministically — a wall-clock
  ///     read here advanced ~0 per test frame and the globe never moved,
  ///     which is exactly what broke the first attempt at this fix.
  /// Falls back to 60 Hz before the first tick.
  double _deltaSeconds() {
    final elapsed = _ctrl.lastElapsedDuration;
    final now = DateTime.now();
    final prev = _lastTickAt;
    _lastTickAt = now;
    if (prev == null) return 1 / 60.0;
    final wall = now.difference(prev).inMicroseconds / 1e6;
    // Prefer the ticker delta; fall back to wall time when it is absent
    // (very first frame after a resume).
    final raw = (elapsed != null && elapsed > Duration.zero)
        ? elapsed.inMicroseconds / 1e6
        : wall;
    if (raw <= 0) return 1 / 60.0;
    // 100 ms ≈ a heavy jank frame; beyond that we deliberately drop the
    // excess rather than jumping, so a 3-second stall doesn't fast-forward
    // the packet flow and the rotation.
    return raw.clamp(0.0, 0.1);
  }

  /// Frame-rate-independent exponential approach of [value] toward [target]
  /// at [rate] (per second), clamped so it can never overshoot. `rate` is
  /// converted from the historical per-frame coefficient as `rate60 * 60`.
  static double _approachStep(double value, double target, double rate,
      double dt) {
    final remaining = target - value;
    final step = (1 - math.exp(-rate * dt)) * remaining;
    return step.clamp(
        remaining < 0 ? remaining : 0.0, remaining > 0 ? remaining : 0.0);
  }

  void _tick() {
    // Fast animations (route draw, destination morph, gesture inertia)
    // advance every tick; STEADY rotation repaints are throttled below.
    final dt = _deltaSeconds();

    // Route draw progress (ease-out on the way in, slower fade out).
    // v0.5.6 §globe-fix: these were per-FRAME steps, so the draw took
    // ~0.9 s at 60 Hz but ~2.9 s at 30 Hz. Now expressed per second:
    // draw 0.035*60 ≈ 2.1/s, fade 0.012*60 ≈ 0.72/s (unchanged feel at
    // 60 Hz, correct everywhere else). `1 - exp(-rate*dt)` is the
    // frame-rate-independent form of the linear approach.
    // Draw is faster than fade.
    final rate = _routeTarget > _routeT ? 2.1 : 0.72;
    // v0.5.6 §globe-fix: `_approachStep` CLAMPS to the remaining distance.
    // The raw exponential form overshoots (routeT measured 1.044) and then
    // oscillates around the target forever, because the direction flips the
    // instant it passes. Clamping keeps it monotone and lets the epsilon
    // below park it exactly on target.
    _routeT += _approachStep(_routeT, _routeTarget, rate, dt);
    if ((_routeTarget - _routeT).abs() < 0.001) _routeT = _routeTarget;
    // Anchor dots: source first, destination staggered after.
    const anchorRate = 3.6; // 0.06 per frame at 60 Hz → per second
    _sourceA += _approachStep(
        _sourceA, _routeT > 0.02 ? 1.0 : 0.0, anchorRate, dt);
    _destA += _approachStep(
        _destA, _routeT > 0.30 ? 1.0 : 0.0, anchorRate, dt);

    // Destination morph.
    if (_destMorph < 1) {
      _destMorph = math.min(1, _destMorph + dt / 0.9);
    }

    // Gestures/inertia.
    if (!_dragging) {
      // v0.5.6 §globe-fix: velocities were stored per drag EVENT and then
      // decayed by a fixed 0.94 per frame — so flick speed depended on how
      // many pointer events the OS coalesced (a slow drag could out-fling a
      // fast one), and the decay ran at the display's frame rate. Now the
      // drag records rad/s and the decay is per-second.
      _yaw += _yawVelocity * dt;
      _pitch = (_pitch + _tiltVelocity * dt).clamp(-0.9, 0.9);
      _yawVelocity *= math.exp(-3.6 * dt); // 0.94^(1/60) per second
      _tiltVelocity *= math.exp(-6.3 * dt); // 0.90^(1/60) per second
      // Auto rotation resumes as inertia dies.
      if (widget.config.autoRotate && _yawVelocity.abs() < 0.0015) {
        _yaw += widget.config.rotationSpeed * dt;
      }
    }
    // Gentle pitch spring back toward the resting tilt.
    if (!_dragging) {
      _pitch += (0.30 - _pitch) * (1 - math.exp(-0.3 * dt));
    }

    // Focus pull toward the arc's midpoint once the route is mostly drawn.
    final dest = _effectiveDest;
    final src = widget.source;
    if (dest != null && src != null && _routeT > 0.55 && !_dragging) {
      final (mla, mlo) =
          slerpLatLon(src.lat, src.lon, dest.lat, dest.lon, 0.5);
      final fy = -mlo * math.pi / 180;
      final fp = -(mla.clamp(-60, 60).toDouble()) *
          math.pi /
          180 *
          0.9;
      if (!_hasFocus) {
        _hasFocus = true;
        // Take the SHORT way around the sphere.
        var dy = fy - _yaw;
        while (dy > math.pi) {
          dy -= 2 * math.pi;
        }
        while (dy < -math.pi) {
          dy += 2 * math.pi;
        }
        _focusYaw = _yaw + dy;
        _focusPitch = fp;
      } else {
        // v0.5.6 §globe-fix: the old line was `fy + (_focusYaw - fy) * 0`,
        // a no-op that read like a smoothing factor but discarded it —
        // it evaluated to plain `fy` and threw away the short-way base
        // established above. Holding the captured base is the intent.
        _focusPitch = fp;
      }
      // v0.5.6 §globe-fix: 0.02/frame was frame-rate dependent — the camera
      // snapped to focus twice as fast on a 120 Hz screen. 0.02*60 ≈ 1.2/s
      // keeps the same 60 Hz feel.
      final focus = 1 - math.exp(-1.2 * dt);
      _yaw += (_focusYaw - _yaw) * focus;
      _pitch += (_focusPitch - _pitch) * focus;
    }

    // Packet/pulse phase (only meaningful when connected): one full
    // source→destination traverse every 4 s, in real seconds.
    _phase = (_phase + dt / 4.0) % 1.0;
    // Shader clock (see [_shaderTime]): monotonic and bounded.
    _shaderTime = (_shaderTime + dt) % kShaderTimeWrap;

    _accum += const Duration(milliseconds: 16);
    if (_accum.inMilliseconds >= _minFrameMs) {
      _accum = Duration.zero;
      _throttle.ping();
    }
  }

  // ── Gestures ────────────────────────────────────────────────────────
  Offset? _lastDrag;
  DateTime? _lastDragAt;
  void _onDragStart(DragStartDetails d) {
    if (!widget.config.interactive) return;
    _dragging = true;
    _lastDrag = d.localPosition;
    _lastDragAt = null; // first update establishes the interval baseline
    _hasFocus = false;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging || _lastDrag == null) return;
    final dx = d.localPosition.dx - _lastDrag!.dx;
    final dy = d.localPosition.dy - _lastDrag!.dy;
    _lastDrag = d.localPosition;
    _yaw -= dx * 0.006;
    _pitch = (_pitch + dy * 0.003).clamp(-0.9, 0.9);
    // v0.5.6 §globe-fix: store velocity in rad/SECOND, not rad-per-event.
    // `_onDragUpdate` is driven by pointer events whose coalescing the OS
    // controls, so a slow drag could previously fling harder than a fast
    // one (and a fast one barely at all). Dividing by the real elapsed
    // time makes the throw proportional to how fast the finger actually
    // moved; a zero-length interval falls back to the event value.
    // v0.5.6 §globe-fix: convert the per-event delta into rad/SECOND using
    // real elapsed time, so a throw matches how fast the finger moved.
    // Clamped to [1/240 s, 100 ms] so a burst of coalesced events (or a
    // zero-length interval) cannot divide into an absurd fling velocity.
    final now = DateTime.now();
    final dt = _lastDragAt == null
        ? 1 / 60.0
        : (now.difference(_lastDragAt!).inMicroseconds / 1e6)
            .clamp(1 / 240.0, 0.1);
    _lastDragAt = now;
    _yawVelocity = -dx * 0.006 / dt;
    _tiltVelocity = dy * 0.003 / dt;
  }

  void _onDragEnd(DragEndDetails d) {
    _dragging = false;
    _lastDrag = null;
    _lastDragAt = null;
    // Inertia comes from the velocities already set; auto-rotation resumes
    // when they decay below the threshold in _tick.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.removeListener(_tick);
    _throttle.dispose();
    _ctrl.dispose();
    // v0.5.6 §globe-fix: release the GPU program. `FragmentShader` holds a
    // native GL program; it was never disposed, so every rebuild that
    // swapped this widget out (tab change, node morph rebuild) leaked one.
    // The land-mask image is NOT disposed here — `landMaskImage()` caches a
    // single shared instance for the whole app, so disposing it would break
    // every other globe on screen.
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.config.interactive
          ? SystemMouseCursors.move
          : MouseCursor.defer,
      child: GestureDetector(
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        child: ClipRect(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _GlobeScenePainter(
                repaint: _throttle,
                state: this,
                ext: ThemeExt.of(context),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

/// Throttled repaint gate (forwards at most one ping per min-frame).
class _ThrottledListenable extends ChangeNotifier {
  _ThrottledListenable(this._source, this.minFrameMs) {
    _source.addListener(_onTick);
  }
  final Listenable _source;
  final double minFrameMs;
  DateTime _last = DateTime.now();

  void _onTick() {
    ping();
  }

  void ping() {
    final now = DateTime.now();
    if (now.difference(_last).inMilliseconds >= minFrameMs.floor() - 1) {
      _last = now;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _source.removeListener(_onTick);
    super.dispose();
  }
}

/// ─────────────────────────────────────────────────────────────────────
/// The scene painter: shader planet underneath + CPU overlay for the
/// route/anchors/packets (overlay needs screen-space 2D, not GLSL).
/// ─────────────────────────────────────────────────────────────────────
class _GlobeScenePainter extends CustomPainter {
  _GlobeScenePainter({
    required Listenable repaint,
    required this.state,
    required this.ext,
  }) : super(repaint: repaint);

  final AtlanhixGlobeViewState state;
  final ThemeExt ext;

  @override
  void paint(Canvas canvas, Size size) {
    final s = state;
    final cx = size.width / 2;
    final cy = size.height * 0.46;
    // v0.5.5 §user-fix ("کره بزرگ‌تر"): the reference sheet's MAIN VIEW
    // fills most of the frame height — 0.46/0.42 of the short side left
    // the planet a small coin in a big empty hero.
    final r = math.min(size.shortestSide * 0.60, size.height * 0.60);

    // ── 1) The planet body ────────────────────────────────────────────
    final mask = s.landMask;
    if (s._shader != null && mask != null) {
      final sh = s._shader!;
      final atmos = _atmosTarget(s.widget.state) *
          (s.widget.config.showAtmosphere ? 1 : 0.35);
      sh.setFloat(0, size.width);
      sh.setFloat(1, size.height);
      sh.setFloat(2, s._shaderTime); // uTime: monotonic, not wall-clock
      sh.setFloat(3, s._yaw);
      sh.setFloat(4, s._pitch);
      sh.setFloat(5, atmos);
      sh.setFloat(6, s.widget.error ? 1 : 0);
      sh.setFloat(7, -0.35); // light x (upper-left)
      sh.setFloat(8, -0.25); // light y
      sh.setImageSampler(0, mask);
      canvas.drawRect(
          Offset.zero & size, Paint()..shader = sh);
    } else {
      _paintFallbackPlanet(canvas, size, cx, cy, r);
    }

    // ── 2) Route + anchors + packets (CPU overlay) ────────────────────
    if (s.widget.config.showRoute && s._routeT > 0.01) {
      _paintRoute(canvas, size, cx, cy, r);
    }
    _paintOrbit(canvas, cx, cy, r);
  }

  double _atmosTarget(GlobeVisualState st) => switch (st) {
        GlobeVisualState.idle => 0.25,
        GlobeVisualState.connecting => 0.65,
        GlobeVisualState.connected => 0.85,
        GlobeVisualState.disconnecting => 0.45,
        GlobeVisualState.error => 0.5,
      };

  /// Projects a unit vector + lift to screen space using the CURRENT
  /// camera; null when the point is on the far backside.
  (Offset, double)? _project(
      double x, double y, double z, double lift, double cx, double cy,
      double r) {
    final yaw = state._yaw, pitch = state._pitch;
    final cy_ = math.cos(yaw), sy_ = math.sin(yaw);
    final x1 = x * cy_ + z * sy_;
    final z1 = -x * sy_ + z * cy_;
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final y2 = y * cp - z1 * sp;
    final z2 = y * sp + z1 * cp;
    if (z2 < -0.25) return null;
    final rr = r * lift;
    return (Offset(cx + x1 * rr, cy - y2 * rr), z2);
  }

  void _paintRoute(
      Canvas canvas, Size size, double cx, double cy, double r) {
    final src = state.widget.source;
    final dest = state._effectiveDest;
    if (src == null || dest == null) return;

    final t = Curves.easeOutCubic.transform(state._routeT.clamp(0.0, 1.0));
    final segs = arcSegmentsFor(src.lat, src.lon, dest.lat, dest.lon);
    final visibleSegs = (segs * t).ceil();

    // ── The arc path (elevated great-circle) ──────────────────────────
    final path = Path();
    var pen = false;
    for (var i = 0; i <= visibleSegs; i++) {
      final f = i / segs;
      final (la, lo) = slerpLatLon(src.lat, src.lon, dest.lat, dest.lon, f);
      final (vx, vy, vz) = globeVec(la, lo);
      final lift = arcLift(src.lat, src.lon, dest.lat, dest.lon, f);
      final p = _project(vx, vy, vz, lift, cx, cy, r);
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
    final routePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = ext.textPrimary.withValues(alpha: 0.88);
    canvas.drawPath(path, routePaint);

    // Subtle glow under the route (connected only).
    if (state.widget.state == GlobeVisualState.connected) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = ext.textPrimary.withValues(alpha: 0.10),
      );
    }

    // ── Packets: small light dots traveling src → dest ────────────────
    if (state.widget.config.showPacketFlow &&
        state.widget.state == GlobeVisualState.connected) {
      const packetCount = 4;
      for (var k = 0; k < packetCount; k++) {
        final f =
            (state._phase + k / packetCount) % 1.0;
        if (f > t) continue;
        final (la, lo) =
            slerpLatLon(src.lat, src.lon, dest.lat, dest.lon, f);
        final (vx, vy, vz) = globeVec(la, lo);
        final lift = arcLift(src.lat, src.lon, dest.lat, dest.lon, f);
        final p = _project(vx, vy, vz, lift, cx, cy, r);
        if (p == null) continue;
        final fade = (p.$2 + 1) / 2;
        canvas.drawCircle(
          p.$1,
          1.8,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.25 + 0.55 * fade),
        );
      }
    }

    // ── Anchors: source (home) + destination (exit) with pulses ───────
    _paintAnchor(canvas, src, state._sourceA, false, cx, cy, r,
        isSource: true);
    if (state._destA > 0.01) {
      _paintAnchor(
          canvas, dest, state._destA, true, cx, cy, r,
          isSource: false);
    }
  }

  void _paintAnchor(Canvas canvas, GlobeLocation loc, double alpha,
      bool active, double cx, double cy, double r,
      {required bool isSource}) {
    final (vx, vy, vz) = globeVec(loc.lat, loc.lon);
    final p = _project(vx, vy, vz, 1.012, cx, cy, r);
    if (p == null || p.$2 < -0.05) return;
    // v0.5.6 §globe-fix: the source pin was `ext.success` (a saturated mint
    // green), which fought the brand sheet — the spec calls for black /
    // deep navy / cool gray / white with at most a whisper of cyan, and
    // explicitly rules out "green VPN-style UI". Both pins now read as
    // cool white; the destination keeps a slightly larger halo and the
    // error tint when the tunnel failed, so the two ends stay
    // distinguishable without introducing a second hue.
    final color = state.widget.error && !isSource
        ? ext.error
        : (isSource ? ext.textSecondary : ext.textPrimary);
    final phase = state._phase;
    final pulse = isSource
        ? 1.0
        : (state.widget.state == GlobeVisualState.connected ? 1.0 : 0.4);
    final haloR = (active ? 12 : 8) + 3.5 * math.sin(phase * 2 * math.pi) * pulse;
    canvas.drawCircle(
        p.$1, haloR, Paint()..color = color.withValues(alpha: 0.14 * alpha));
    canvas.drawCircle(
        p.$1, 2.6, Paint()..color = color.withValues(alpha: 0.95 * alpha));
    // Hairline stem so the pin reads as attached to the surface.
    canvas.drawLine(
      p.$1,
      p.$1 + const Offset(0, 7),
      Paint()
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.35 * alpha),
    );
  }

  /// Optional orbital ring: thin, slow, mostly behind the planet.
  void _paintOrbit(Canvas canvas, double cx, double cy, double r) {
    if (!state.widget.config.showOrbit) return;
    final tilt = 0.42;
    final ringR = r * 1.28;
    final path = Path();
    var pen = false;
    for (var i = 0; i <= 72; i++) {
      final a = i / 72 * 2 * math.pi + state._yaw * 0.3;
      final x0 = math.cos(a) * ringR;
      final y0 = math.sin(a) * ringR * math.sin(tilt);
      final z0 = math.sin(a) * ringR * math.cos(tilt);
      // Camera yaw affects the ring too (rotates with the planet family).
      final p = _project(x0 / ringR, 0, z0 / ringR, ringR / r, cx, cy, r);
      if (p == null || p.$2 < 0) {
        pen = false;
        continue;
      }
      final pt = Offset(p.$1.dx, p.$1.dy + y0 * 0.4);
      if (!pen) {
        path.moveTo(pt.dx, pt.dy);
        pen = true;
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = ext.textSecondary.withValues(alpha: 0.10),
    );
  }

  /// CPU fallback planet (shader unavailable): REAL CONTINENTS from the
  /// baked land mask (v0.5.5 §user-fix — the old version was three limp
  /// radial gradients, which is exactly the "pale ghost ball" users
  /// reported), plus the rim sweep and the night-lights channel.
  void _paintFallbackPlanet(
      Canvas canvas, Size size, double cx, double cy, double r) {
    final atmos = _atmosTarget(state.widget.state);
    // Halo.
    canvas.drawCircle(
      Offset(cx, cy),
      r * 1.35,
      Paint()
        ..shader = ui.Gradient.radial(Offset(cx, cy), r * 1.35, [
          ext.textPrimary.withValues(alpha: 0.16 * atmos),
          ext.textPrimary.withValues(alpha: 0.03 * atmos),
          const Color(0x00000000),
        ], [0.70, 0.88, 1.0]),
    );
    final mask = state.landMask;

    // ── Continents (mask clip): REAL land shapes scrolling with yaw ──
    // The equirectangular mask wraps horizontally; shifting its source
    // rect by the yaw fraction scrolls the continents through the disc —
    // a cheap hemisphere projection that reads as a ROTATING planet.
    if (mask != null) {
      final bodyRect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
      final mw = mask.width.toDouble();
      final mh = mask.height.toDouble();
      // Longitude scroll (wraps) + a small latitude offset from pitch.
      final lonShift =
          ((state._yaw / (2 * math.pi)) % 1.0) * mw;
      final latShift = (state._pitch / math.pi) * mh * 0.5;
      // White continent cutout: alpha ← mask R channel (ColorFilter
      // matrix — paint.color alone never tints a drawImage). The 0.42
      // coefficient folds the layer opacity into the matrix (Paint has
      // no standalone alpha setter for this shape).
      const landFilter = ColorFilter.matrix(<double>[
        0, 0, 0, 0, 1, // R' = 1 (white)
        0, 0, 0, 0, 1, // G' = 1
        0, 0, 0, 0, 1, // B' = 1
        0.42, 0, 0, 0, 0, // A' = mask R × 0.42
      ]);
      // Warm night-lights cutout: alpha ← mask G channel.
      const lightFilter = ColorFilter.matrix(<double>[
        0, 0, 0, 0, 1.00, // warm white R
        0, 0, 0, 0, 0.88, // G
        0, 0, 0, 0, 0.62, // B
        0, 0.30, 0, 0, 0, // A' = mask G × 0.30
      ]);
      void drawWrapped(Paint paint) {
        final x0 = lonShift;
        final src1 = Rect.fromLTWH(x0, 0, mw - x0, mh);
        final src2 = Rect.fromLTWH(0, 0, x0, mh);
        final dstW = bodyRect.width * ((mw - x0) / mw);
        final dy = latShift;
        canvas.drawImageRect(
            mask,
            src1,
            Rect.fromLTRB(bodyRect.left, bodyRect.top + dy,
                bodyRect.left + dstW, bodyRect.bottom + dy),
            paint);
        canvas.drawImageRect(
            mask,
            src2,
            Rect.fromLTRB(bodyRect.left + dstW, bodyRect.top + dy,
                bodyRect.right, bodyRect.bottom + dy),
            paint);
      }

      canvas.save();
      canvas.clipPath(Path()..addOval(bodyRect));
      drawWrapped(Paint()
        ..filterQuality = FilterQuality.low
        ..colorFilter = landFilter);
      drawWrapped(Paint()
        ..filterQuality = FilterQuality.low
        ..colorFilter = lightFilter
        ..blendMode = BlendMode.plus);
      // Night wash: keep the disc DARK like the reference — the lower-
      // right hemisphere sinks to near-black, the upper-left (under the
      // key light) stays readable.
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(cx - r * 0.45, cy - r * 0.45),
            r * 2.1,
            [
              const Color(0x00000000),
              const Color(0xD8030508),
              const Color(0xF0020407),
            ],
            [0.0, 0.55, 1.0],
          ),
      );
      canvas.restore();
    } else {
      // Body.
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(cx - r * 0.35, cy - r * 0.4),
            r * 1.7,
            [
              const Color(0xFF1A2028),
              const Color(0xFF0C0F14),
              const Color(0xFF05070A),
            ],
            [0.0, 0.55, 1.0],
          ),
      );
    }
    // Rim light (upper-left → lower-right sweep) — STRONGER now: this is
    // the reference's signature white crescent.
    canvas.drawCircle(
      Offset(cx, cy),
      r - 0.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..shader = ui.Gradient.sweep(
          Offset(cx, cy),
          [
            Colors.white.withValues(alpha: 0.85 * atmos),
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.0),
          ],
          [0.0, 0.25, 1.0],
          TileMode.clamp,
          -2.4,
          2.4,
        ),
    );
  }

  @override
  bool shouldRepaint(_GlobeScenePainter old) => old.state != state;
}
