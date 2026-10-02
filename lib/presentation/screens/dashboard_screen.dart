import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../application/connection_controller.dart';
import '../../application/dependencies.dart';
import '../../core/android_node_support.dart';
import '../../core/net/geo_locator.dart';
import '../../settings/app_settings.dart';
import '../../settings/smart_switch.dart' show LadderProgress;
import '../../domain/entities/health.dart';
import '../../domain/entities/proxy_profile.dart';
import '../../platform/android_vpn.dart' show AndroidVpnPhase;
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';
import '../widgets/live_monitor.dart';
import '../widgets/traffic_graph.dart';

/// Main dashboard (§30): answers in 5 seconds — connected? which node?
/// healthy? how fast? what core?
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.deps});

  final AppDependencies deps;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  ProxyProfile? _active;
  int? _latencyMs;
  StreamSubscription? _sub;
  StreamSubscription? _trafficSub;
  StreamSubscription? _vpnSub;
  // Growable rings: the 1s ticker mutates them with removeAt(0)/add —
  // a fixed-length List.filled crashed with "Cannot remove from a
  // fixed-length list" the moment the tunnel connected (device log
  // 2026-09-17 20:12). Same length, same semantics, mutable.
  final _down = List<double>.of(List<double>.filled(60, 0));
  final _up = List<double>.of(List<double>.filled(60, 0));
  int? _lastUp; // for speed delta
  int? _lastDown;
  // v0.5.0 §user: TOTAL USAGE — cumulative bytes since the tunnel came up
  // (real engine counter deltas folded on every 1 Hz tick).
  int _sessionDownBytes = 0;
  int _sessionUpBytes = 0;
  Timer? _clock;
  // v0.4.1 §5: Android selection is authoritative and can change OUTSIDE the
  // state machine (tap while disconnected emits no VPN phase), so the
  // dashboard also listens to explicit selection events and re-reads
  // selectedNode — the tapped node shows immediately, BEFORE any connect.
  StreamSubscription? _selectionSub;
  StreamSubscription? _counterSub;
  StreamSubscription<HealthRecord>? _healthSub;

  // v0.5.2 §user — LIVE PRE-CONNECT LADDER: while the smart switch measures
  // the pool before connecting, the hero counts per-node progress
  // ("testing 5/11… 180 ms") instead of a bare "Connecting…". Starts and
  // finishes are sentinels on the same stream, so this state needs no
  // extra bookkeeping beyond the reset on disconnect.
  LadderProgress _ladder = LadderProgress.idle;
  StreamSubscription<LadderProgress>? _ladderSub;

  /// v0.5.3 §perf-fix: one-paint-per-frame coalescing flag (see the
  /// ladder subscription in initState).
  bool _ladderPaintScheduled = false;

  // v0.5.2 §globe — IP geolocation for the dashboard globe: the HOME fix
  // (device's direct IP) and the EXIT fix (tunnel egress). A host fix
  // resolves the selected node's server BEFORE the tunnel comes up so the
  // globe can pre-ping Romania while connecting.
  GeoFix? _homeFix;
  GeoFix? _exitFix;
  GeoFix? _hostFix; // provisional exit from the node's server hostname
  String? _geoHostKey; // which node server _hostFix was resolved for
  String? _exitIpHint; // last seen exit IP from the engine, when exposed
  bool _geoBusy = false;
  StreamSubscription<String>? _geoSub;

  // v0.5.2 §globe: the unfold intro now lives on the SHELL's backdrop
  // (the globe is the app background); the dashboard no longer owns it.

  bool get _onAndroid => widget.deps.vpnSession.controller.isAndroid;

  bool _appVisible = true;

  @override
  void initState() {
    super.initState();
    // v0.4.9 §battery: the 1 Hz clock below is the dashboard's heartbeat —
    // it must NOT keep waking a backgrounded app. Android already throttles
    // timers for hidden apps, but each fired tick still costs a wake; the
    // observer pauses/resumes the timer outright.
    WidgetsBinding.instance.addObserver(this);
    // v0.4.7 §user: tab switches UNMOUNT this screen (the shell builds
    // `screens[_index]` directly), so every stream subscription is lost
    // while away. Re-reading the authoritative state here restores the
    // truth the moment the user returns — "tapped connect, switched tab,
    // came back to DISCONNECTED" is gone.
    if (widget.deps.vpnSession.controller.isAndroid) {
      _phase = widget.deps.vpnSession.uiPhase;
      _active = widget.deps.vpnSession.selectedNode;
    } else {
      final snap = widget.deps.connection.state;
      _active = snap.activeProfile ?? _active;
      _phase = snap.phase;
    }
    _sub = widget.deps.connection.states.listen((s) {
      if (!mounted) return;
      setState(() {
        _phase = s.phase;
        _active = s.activeProfile;
        _latencyMs = s.latencyMs;
        if (s.phase == ConnectionPhase.disconnected) {
          // Reset the graphs on disconnect — honest empty state.
          for (var i = 0; i < 60; i++) {
            _down[i] = 0;
            _up[i] = 0;
          }
          _lastUp = null;
          _lastDown = null;
          _sessionDownBytes = 0;
          _sessionUpBytes = 0;
        }
      });
      // v0.5.2 §globe: the tunnel lifecycle drives the geo roles —
      // disconnect re-verifies HOME; connect resolves the EXIT.
      unawaited(_refreshGeo(
          connecting: s.phase != ConnectionPhase.disconnected));
    });
    // v0.4.1 §5: single authoritative state — on Android the VPN session is
    // the source of truth; mirror its native phases into the dashboard UI.
    if (widget.deps.vpnSession.controller.isAndroid) {
      _vpnSub = widget.deps.vpnSession.states.listen((_) {
        if (!mounted) return;
        final vs = widget.deps.vpnSession;
        final prev = _phase;
        setState(() {
          _phase = vs.uiPhase;
          _active = vs.selectedNode;
          if (vs.lastLatencyMs != null) _latencyMs = vs.lastLatencyMs;
        });
        // v0.5.2 §globe: phase transitions re-point the geo roles.
        if (_phase != prev) {
          unawaited(
              _refreshGeo(connecting: _phase != ConnectionPhase.disconnected));
        }
      });
      // Selection changed without a phase event (tap while disconnected):
      // repaint so the tapped node appears the moment it is tapped.
      _selectionSub = widget.deps.vpnSession.selectionChanged.listen((_) {
        if (!mounted) return;
        setState(() {
          _active = widget.deps.vpnSession.selectedNode;
        });
        // v0.5.2 §globe: a different node → its server pin pre-lights even
        // before the user connects (cached; zero cost on repeats).
        unawaited(_refreshGeo(connecting: true));
      });
    }
    // v0.5.0 §user-fix: the controller's counters are refreshed by the
    // native watcher — fold them the moment they land (not on our next
    // 1 s tick). On desktop the trafficStream already covers this; on
    // Android this keeps the graph glued to the native 2 s cadence.
    if (widget.deps.vpnSession.controller.isAndroid) {
      _counterSub =
          widget.deps.vpnSession.states.listen((_) => _foldAndroidCounters());
    }
    _trafficSub = widget.deps.connection.trafficStream.listen((t) {
      if (!mounted) return;
      setState(() {
        // Real speed = delta of engine counters (Phase 24).
        final upSpeed =
            _lastUp == null ? 0 : (t.upBytes - _lastUp!).clamp(0, 1 << 30);
        final downSpeed = _lastDown == null
            ? 0
            : (t.downBytes - _lastDown!).clamp(0, 1 << 30);
        _lastUp = t.upBytes;
        _lastDown = t.downBytes;
        _sessionUpBytes += upSpeed;
        _sessionDownBytes += downSpeed;
        _down..removeAt(0)..add(downSpeed.toDouble());
        _up..removeAt(0)..add(upSpeed.toDouble());
      });
    });
    // v0.4.9 §user-fix (latency chip never updated): the scheduler's
    // records reached HealthStore but nothing here listened — the health
    // figures only changed after an unrelated repaint.
    // v0.5.0 §user-fix ("پینگ توی داشبورد تکون نمی‌خوره"): the Android
    // chip followed ONLY the connect-time probe. The scheduler's 30 s
    // active-node monitor feeds the same store — mirror fresh records for
    // the SELECTED node into the chip so the number breathes.
    _healthSub = widget.deps.scheduler.results.listen((rec) {
      if (!mounted) return;
      final activeId = _onAndroid
          ? widget.deps.vpnSession.selectedNode?.id
          : _active?.id;
      if (rec.profileId == activeId && rec.ok && rec.latencyMs != null) {
        _latencyMs = rec.latencyMs;
      }
      // v0.5.0 §battery/lag: rebuild ONLY when this record belongs to the
      // active node's chip — a 40-node sweep previously repainted the whole
      // dashboard once per record for numbers it never displays.
      if (rec.profileId == activeId) setState(() {});
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      // v0.4.9 §battery: hidden app → no ticks, no redraws, no wakeups.
      if (!_appVisible || !mounted) return;
      _foldAndroidCounters();
      if (_phase == ConnectionPhase.connected) {
        setState(() {}); // session clock + metrics
      }
    });

    // v0.5.2 §globe — start with the persisted home fix (no boot cost; the
    // first paint already shows the pin from the LAST run) then refresh it.
    _geoSub = widget.deps.store.changes.listen((section) {
      if (section == 'geo') _restoreGeoCache();
    });
    _restoreGeoCache();

    // v0.5.2 §user: the ladder's progress stream keeps the latest event for
    // NEW subscribers too — a dashboard remounted mid-ladder (tab switch)
    // resumes the count instead of waiting for the next node to land.
    // v0.5.3 §perf-fix: the events arrive in PARALLEL completion order —
    // bursts of 6+ in one frame, each previously running a FULL-screen
    // setState (rebuild of the hero, graph, monitor…). Store the payload
    // and microtask-coalesce: at most ONE repaint per frame drains the
    // pending value (identical UI outcome, a fraction of the rebuilds).
    _ladderSub = widget.deps.vpnSession.smartLadderProgress.listen((p) {
      if (!mounted) return;
      _ladder = p;
      if (_ladderPaintScheduled) return;
      _ladderPaintScheduled = true;
      scheduleMicrotask(() {
        _ladderPaintScheduled = false;
        if (mounted) setState(() {});
      });
    });
  }

  /// v0.5.2 §globe: the LAST home fix persists in the JsonStore section
  /// `geo` — the globe shows the pin on the first paint of every run and
  /// only then re-verifies (one network call, once per IP rotation).
  void _restoreGeoCache() {
    final s = widget.deps.store.section('geo');
    if (s.isEmpty) return;
    final j = s['home'] as Map<String, dynamic>?;
    if (j == null || _homeFix != null) return;
    final lat = (j['lat'] as num?)?.toDouble();
    final lon = (j['lon'] as num?)?.toDouble();
    final cc = (j['countryCode'] as String?) ?? '';
    if (lat == null || lon == null || cc.isEmpty) return;
    _homeFix = GeoFix(
      lat: lat,
      lon: lon,
      countryCode: cc,
      countryName: (j['countryName'] as String?) ?? '',
      city: (j['city'] as String?) ?? '',
      ip: (j['ip'] as String?) ?? '',
    );
    if (mounted) setState(() {});
  }

  Future<void> _persistGeoCache(GeoFix f) async {
    try {
      await widget.deps.store.putSection('geo', {
        'home': {
          'lat': f.lat,
          'lon': f.lon,
          'countryCode': f.countryCode,
          'countryName': f.countryName,
          'city': f.city,
          'ip': f.ip,
        },
      });
    } on Exception catch (_) {
      // Persistence is best-effort decoration — never surface.
    }
  }

  /// v0.5.2 §globe — ONE resolver for both anchors.
  ///
  /// * On CONNECT (or selection): resolve the selected node's server host
  ///   immediately (provisional pin — "Romania is about to light up"), then
  ///   locate the tunnel EXIT once connected (honest egress),
  /// * On DISCONNECT: re-verify HOME (the direct IP) and clear the exit.
  /// Every step is best-effort: a dead network just leaves the globe calm.
  Future<void> _refreshGeo({required bool connecting}) async {
    if (_geoBusy) return;
    _geoBusy = true;
    try {
      final geo = widget.deps.geo;
      final active = _onAndroid
          ? widget.deps.vpnSession.selectedNode
          : _active;
      if (!connecting) {
        // DISCONNECTED: the direct-IP fix is the truth again.
        final fix = await geo.locateHome(force: _exitFix != null);
        if (fix != null && mounted) {
          setState(() => _homeFix = fix);
          unawaited(_persistGeoCache(fix));
        }
        if (mounted) setState(() => _exitFix = null);
        return;
      }
      // CONNECTING/CONNECTED: pin the node's server first (cheap, cached).
      final host = active?.server ?? '';
      if (host.isNotEmpty && host != _geoHostKey) {
        _geoHostKey = host;
        final hf = await geo.locateHost(host);
        if (hf != null && mounted) setState(() => _hostFix = hf);
      }
      // Then the honest tunnel-exit fix once the tunnel is actually up.
      if (_phase == ConnectionPhase.connected) {
        final fix = await geo.locateExit(
            force: _exitIpHint == null, exitIpHint: _exitIpHint);
        if (fix != null && mounted) {
          setState(() {
            _exitFix = fix;
            _exitIpHint = fix.ip.isNotEmpty ? fix.ip : _exitIpHint;
          });
        }
      }
    } on Exception catch (_) {
      // Geo is decorative: never break the dashboard over it.
    } finally {
      _geoBusy = false;
    }
  }

  /// v0.5.2 §user — the ladder's line for the GEO ROUTE chip: the LAST
  /// node tested with its ping, next to the Iran → Romania route text
  /// ("تست ۳/۱۱ · ۱۲۰ ms"). Silent for idle.
  String _ladderText(AppLocalizations l) {
    final lp = _ladder;
    return lp.lastMs == null
        ? l.ladderTesting(lp.done, lp.total)
        : l.ladderTestingMs(lp.done, lp.total, lp.lastMs!);
  }

  /// True while a lookup is in flight for the CURRENT role (the chip shows
  /// "Locating…" instead of pretending nothing is happening).
  bool get _geoPending => _geoBusy;

  /// v0.5.2 §globe — the anchor fixes now live on the shell's backdrop
  /// (the shell reads deps.geo directly). The dashboard keeps the CHIP's
  /// text resolution + the geo refresh lifecycle.

  /// Top-right chip text: honest state, no invented cities.
  String _geoChipLabel(AppLocalizations l) {
    if (_geoPending) return l.globeLocating;
    final exit = _exitFix;
    if (_phase == ConnectionPhase.connected) {
      if (exit != null) {
        final where = exit.hasCity
            ? exit.city
            : (exit.countryName.isNotEmpty
                ? exit.countryName
                : exit.countryCode);
        return l.globeConnectedVia(where);
      }
      return l.globeExitUnknown;
    }
    if (_phase == ConnectionPhase.disconnected) {
      final home = _homeFix;
      if (home != null) {
        final where = home.hasCity
            ? home.city
            : (home.countryName.isNotEmpty
                ? home.countryName
                : home.countryCode);
        return '${l.globeDirectConnection} · $where';
      }
      return l.globeDirectConnection;
    }
    // Connecting/validating with a host fix: "Bucharest connecting…".
    final host = _hostFix;
    if (host != null) {
      final where = host.hasCity
          ? host.city
          : (host.countryName.isNotEmpty ? host.countryName : host.countryCode);
      return '$where · ${l.globeConnectingYou}';
    }
    return l.globeConnectingYou;
  }

  /// v0.5.0 §user-fix ("وقتی برمی‌گردم گراف/پینگ تکون نمی‌خورن"): the
  /// Android engine counters live on the vpn controller, refreshed by the
  /// NATIVE watcher every 2 s — but the dashboard only folded them inside
  /// its own 1 s tick, which (a) waits up to a whole second after a resume
  /// and (b) — before the resume fix — folded the WHOLE background gap as
  /// one giant delta. Fold-on-listen: whenever the controller publishes
  /// fresher counters (watcher tick or reconcile), the numbers land on the
  /// graph immediately.
  void _foldAndroidCounters() {
    if (!_onAndroid) return;
    final c = widget.deps.vpnSession.controller;
    if (_lastUp == null || _lastDown == null) {
      // First sample after (re)attach — seed without a fake spike.
      _lastUp = c.upBytes;
      _lastDown = c.downBytes;
      return;
    }
    if (c.upBytes == _lastUp && c.downBytes == _lastDown) return; // not newer
    final upSpeed =
        (c.upBytes - _lastUp!).clamp(0, 1 << 30).toDouble();
    final downSpeed =
        (c.downBytes - _lastDown!).clamp(0, 1 << 30).toDouble();
    _lastUp = c.upBytes;
    _lastDown = c.downBytes;
    _sessionUpBytes += upSpeed.toInt();
    _sessionDownBytes += downSpeed.toInt();
    _down
      ..removeAt(0)
      ..add(downSpeed);
    _up
      ..removeAt(0)
      ..add(upSpeed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appVisible = state == AppLifecycleState.resumed;
    // While hidden: drop the chart samples instead of letting them pile up
    // with zero deltas, so a resume shows a fresh window (cosmetic + free).
    if (!_appVisible) {
      _lastUp = null;
      _lastDown = null;
    }
    // v0.5.0 §user-fix: on resume, seed from the CURRENT counters (the
    // native watcher may have kept polling while we were hidden — folding
    // the whole gap at once would draw a huge fake spike) and repaint NOW
    // instead of waiting for the next 1 s tick.
    if (_appVisible && mounted) {
      _lastUp = null;
      _lastDown = null;
      _foldAndroidCounters();
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _trafficSub?.cancel();
    _vpnSub?.cancel();
    _selectionSub?.cancel();
    _counterSub?.cancel();
    _healthSub?.cancel();
    _geoSub?.cancel();
    _ladderSub?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  static String _fmtSpeed(num bps) => fmtSpeed(bps);

  /// Public static: the [_TotalTrafficPill] formats with the SAME
  /// units/scale as the stat tiles (one truth for speed numbers).
  static String fmtSpeed(num bps) {
    if (bps > 1 << 20) return '${(bps / (1 << 20)).toStringAsFixed(1)} MB/s';
    if (bps > 1 << 10) return '${(bps / (1 << 10)).toStringAsFixed(0)} KB/s';
    return '$bps B/s';
  }


  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final l = AppLocalizations.of(context)!;
    // v0.4.1 §5: on Android the VpnSession's explicit selection IS the truth.
    // Read it on every build so the hero card reflects the TAPPED node
    // immediately — before any connect attempt, even while disconnected.
    final active = _onAndroid
        ? (widget.deps.vpnSession.selectedNode ?? _active)
        : _active;
    final connected = _phase == ConnectionPhase.connected;
    final coreInfo = active == null
        ? ''
        : '${active.protocol.name.toUpperCase()} · '
            '${_onAndroid ? AndroidNodeSupport.androidCoreLabel(active) : widget.deps.detector.resolve(active).core.name} · '
            '${active.server}';
    // v0.4.1: REAL active-core indicator — derived from the VPN session's
    // selected node and the on-device engine gating, never hardcoded.
    final activeCoreLabel = _onAndroid && active != null
        ? AndroidNodeSupport.coreDisplayName(widget.deps.vpnSession.activeCore)
        : null;
    // Honest error codes from the last connect attempt (node-selection).
    final lastErr = _onAndroid ? widget.deps.vpnSession.lastError : null;

    // v0.4.7 §brand (sheet v2) — the dashboard IS the mockup: the moon
    // artwork fills the hero as a fade-out backdrop, the phase word
    // (CONNECTED / …) sits under it, the active-node card rides ON the
    // artwork, the 3-metric stats row + hairline speed graph follow, and a
    // NARROW full-width power pill (Disconnect mockup) closes the hero.
    // v0.5.2 §user — LIVE LADDER READOUT: while the smart switch's
    // pre-connect ladder measures the pool, the phase word becomes the
    // per-node counter ("testing 5/11 · 180 ms"). A started run announces
    // itself; the FINISH sentinel (or a non-ladder connect) falls back to
    // the plain word — the count never outlives its run. startingCore /
    // switching keep the plain word (those phases run after the ladder).
    final ladderLive = (_phase == ConnectionPhase.connecting ||
            _phase == ConnectionPhase.validating) &&
        _ladder.total > 0 &&
        !_ladder.isFinish &&
        _ladder.id != LadderProgress.idle.id;
    final phaseWord = switch (_phase) {
      ConnectionPhase.connected => l.connected,
      ConnectionPhase.connecting ||
      ConnectionPhase.validating when ladderLive =>
        _ladder.lastMs == null
            ? l.ladderTesting(_ladder.done, _ladder.total)
            : l.ladderTestingMs(
                _ladder.done, _ladder.total, _ladder.lastMs!),
      ConnectionPhase.connecting ||
      ConnectionPhase.startingCore ||
      ConnectionPhase.switching ||
      ConnectionPhase.validating =>
        l.connecting,
      ConnectionPhase.error => l.connectionFailed,
      _ => l.disconnected,
    };
    final busy = const [
      ConnectionPhase.connecting,
      ConnectionPhase.startingCore,
      ConnectionPhase.switching,
      ConnectionPhase.disconnecting,
      ConnectionPhase.validating,
    ].contains(_phase);
    Future<void> toggle() async {
      if (connected) {
        if (widget.deps.vpnSession.controller.isAndroid) {
          await widget.deps.vpnSession.disconnect();
        } else {
          await widget.deps.connection.disconnect();
        }
        return;
      }
      // v0.6.2 §stop-fix (user report: "موقعی که توی کانکتینگ هست نمیشه
      // متوقف کرد"): while a connect is STILL IN FLIGHT the pill means
      // CANCEL. Before this, the tap re-entered the connect path (or, with
      // the pill disabled, did nothing at all) while the old run kept
      // probing — the button that was supposed to stop the attempt either
      // silently raced it or was dead, so the only way out was killing the
      // app. Both platforms own a real cancel now: the Android session
      // marks the in-flight attempt cancelled and supersedes the controller
      // run, the desktop controller bumps its run token.
      if (busy) {
        if (widget.deps.vpnSession.controller.isAndroid) {
          await widget.deps.vpnSession.disconnect();
        } else {
          await widget.deps.connection.disconnect();
        }
        return;
      }
      if (widget.deps.vpnSession.controller.isAndroid) {
        final ok = await widget.deps.vpnSession.connect();
        final vpn = widget.deps.vpnSession;
        // v0.6.2 §stop-fix: a connect the USER cancelled reports `false` too —
        // an error snackbar right after their own Stop reads as "the app kept
        // failing". Only a real engine/probe/permission failure fires it.
        final failed = vpn.controller.phase == AndroidVpnPhase.failed ||
            vpn.controller.phase == AndroidVpnPhase.permissionDenied ||
            vpn.controller.phase == AndroidVpnPhase.revoked;
        if (!ok && failed && mounted) {
          final req = vpn.selectedNode;
          final why = req == null
              ? ''
              : ' (${AndroidNodeSupport.notRunnableReason(req) ?? req.name} cannot run on this device)';
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(AndroidNodeSupport.connectErrorHint(vpn.lastError) ??
                  'Connection failed$why')));
        }
      } else {
        await widget.deps.connection.smartConnect();
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(NexusSpacing.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── HERO (v0.5.2 §globe — the mockup, third act): the point
              // cloud GLOBE replaces the moon artwork. The world map unfolds
              // onto the sphere on every connect (the Vercel spell), the
              // selected node's server pre-lights its pin, and once the
              // tunnel is up the great-circle ARC home → exit draws itself
              // (Iran → Romania). Traffic graph + pills ride it unchanged.
              SizedBox(
                height: 320,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // v0.5.2 §user: the HERO GLOBE moved to the APP BACKDROP
                    // (shell-level, visible through every screen). The hero
                    // keeps the geo chips + graph over the shared artwork.
                    // ── HERO TOP CHIPS ROW (v0.5.5 §user-fix: "GEO ROUTE
                    // هنوز با TOTAL TRAFFIC برخورد دارد"). v0.5.3 gave each
                    // chip its own maxWidth budget, but two independent
                    // budgets on two Stack anchors can still SUM past the
                    // hero on narrow/RTL screens — Flutter then overlaps
                    // them. They now share ONE LayoutBuilder row: TOTAL
                    // TRAFFIC hugs its content, GEO ROUTE gets ALL the
                    // remaining width and ellipsizes inside it. Same row →
                    // geometrically impossible to collide, at any width,
                    // any locale, with the ladder line visible or not.
                    // LTR-pinned: both labels are Latin; the mockup wants
                    // traffic top-left / route top-right in fa too.
                    Positioned(
                      top: 6,
                      left: 4,
                      right: 4,
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: LayoutBuilder(builder: (context, cons) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _TotalTrafficPill(
                                  downBps: _down.last, upBps: _up.last),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: _GeoRouteChip(
                                    label: _geoChipLabel(l),
                                    ladderText: _ladder.id !=
                                                LadderProgress.idle.id &&
                                            !_ladder.isFinish &&
                                            _ladder.total > 0
                                        ? _ladderText(l)
                                        : null,
                                  ),
                                ),
                              ),
                            ],
                          );
                        }),
                      ),
                    ),
                    // ── THE TRAFFIC GRAPH floats over the LOWER HALF of
                    // the moon (mockup: waves sit on the artwork, bottom
                    // anchored, transparent field — no own card). The
                    // painter's glass field is disabled via the transparent
                    // knob to let the moon show through.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 86,
                      // v0.5.0 §battery-fix: the tab switch UNMOUNTS the
                      // dashboard, but the hero still animates whenever any
                      // ancestor keeps it alive (wide layouts). TickerMode
                      // kills the 60 fps wave phase while the graph is
                      // offscreen regardless of parentage.
                      child: TickerMode(
                        enabled: _phase == ConnectionPhase.connected ||
                            _phase == ConnectionPhase.validating,
                        child: TrafficGraph(
                          downSamples: _down,
                          upSamples: _up,
                          height: 132,
                          transparentField: true,
                        ),
                      ),
                    ),
                    // Foreground: phase word + node card pinned to the
                    // bottom (unchanged, below the graph strip).
                    Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          phaseWord,
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(
                                color:
                                    connected ? c.success : c.textSecondary,
                                letterSpacing: 5,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: c.surface.withValues(alpha: 0.86),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: c.border),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.shield_outlined,
                                  size: 16,
                                  color:
                                      connected ? c.success : c.textMuted),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  active?.name ??
                                      (lastErr != null
                                          ? lastErr.toString()
                                          : l.tapToConnect),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(color: c.textPrimary),
                                ),
                              ),
                              Text(
                                _latencyMs == null ? '—' : '$_latencyMs ms',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelMedium
                                    ?.copyWith(
                                      color: (_latencyMs ?? 999) < 300
                                          ? c.success
                                          : c.warning,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        if (coreInfo.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            activeCoreLabel != null
                                ? '$coreInfo · $activeCoreLabel'
                                : coreInfo,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: c.textMuted),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (lastErr != null && active != null &&
                  AndroidNodeSupport.notRunnableReason(active) != null) ...[
                const SizedBox(height: 10),
                // Node-selection honesty: the tapped node cannot run on this
                // device — the reason is visible here and in the log.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.swap_horiz, size: 14, color: c.warning),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${active.name}: ${AndroidNodeSupport.notRunnableReason(active) ?? 'not runnable on Android'}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: c.warning),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              // ── STATS ROW (mockup: Download · Upload · Latency) + the
              // session USAGE tile the mockup's "Total usage" asked for —
              // cumulative bytes since the tunnel came up.
              Row(
                children: [
                  Expanded(
                    child: _HeroStat(
                        label: l.downloadSpeed,
                        value: _fmtSpeed(_down.last),
                        icon: Icons.south_rounded),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _HeroStat(
                        label: l.uploadSpeed,
                        value: _fmtSpeed(_up.last),
                        icon: Icons.north_rounded),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _HeroStat(
                        label: l.latency,
                        value: _latencyMs == null ? '—' : '$_latencyMs ms',
                        icon: Icons.bolt_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // v0.5.0 §user — TOTAL USAGE: cumulative up+down since the
              // connect (real engine counters, Phase 24). The old graph's
              // 216 px pushed the power pill below the fold; the graph now
              // lives ON the hero artwork instead.
              _UsageCard(
                  downBytes: _sessionDownBytes, upBytes: _sessionUpBytes),
              const SizedBox(height: 10),
              // v0.5.2 §user — LIVE MONITOR: battery %/temp + app CPU/RAM
              // (Android only; a no-op SizedBox elsewhere).
              const LiveMonitor(),
              const SizedBox(height: 18),
              // ── NARROW POWER PILL (mockup bottom bar) — full width,
              // hairline ring + power glyph + LIVE localized label. ──
              _PowerPill(
                connected: connected,
                busy: busy,
                label: connected
                    ? l.disconnect
                    : (busy ? l.cancel : l.connect),
                onToggle: toggle,
              ),
              const SizedBox(height: 20),
              // v0.4.7 §user: QUICK SETTINGS stays, but the CURRENT NODE card
              // and QUICK ACTIONS row are gone — node identity now lives in
              // the Nodes tab, and the power pill above is the single CTA.
              const SizedBox(height: 16),
              // v0.5.5 §user: RECOMMENDED NODES removed from the DASHBOARD
              // (the hero + power pill are the whole story here; node
              // identity/selection lives in the Nodes tab). The section
              // card wrapper stays for the remaining sections.
              const SizedBox(height: 32),
              // v0.4.9 §user: the FAST/SECURE/FREEDOM brand card is REMOVED
              // from the dashboard tail (the hero artwork carries the brand
              // identity now).
            ],
          ),
        ),
      ),
    );
  }
}

/// v0.5.5 §user: `_RecommendedNodes` was REMOVED with its dashboard
/// section ("recommended node از داشبورد حذف شود"). The Nodes tab is the
/// single place for node selection; nothing else referenced the class.
/// v0.4.7 §brand (sheet v2) — one of the three hero stat tiles
/// (Download GB/s · ms · uptime): hairline rounded tile, small muted icon
/// + label over a large value, exactly like the mockup's stat cards.
class _HeroStat extends StatelessWidget {
  const _HeroStat(
      {required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: c.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: c.textSecondary,
                        letterSpacing: 0.3,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: c.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

/// v0.5.0 §user — TOTAL TRAFFIC pill (the mockup's top-left glass chip):
/// the zigzag glyph + "TOTAL TRAFFIC" over the CURRENT down+up speed, and
/// the cumulative session usage as the small line under it. Rides the
/// hero artwork (Positioned, transparent glass).
class _TotalTrafficPill extends StatelessWidget {
  const _TotalTrafficPill({required this.downBps, required this.upBps});

  final double downBps;
  final double upBps;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    // v0.5.5 §fix: the chips share the hero's top row — the caller's
    // LayoutBuilder owns collision-freedom now. This pill just hugs its
    // content; the speed line ellipsizes if it ever gets cramped.
    return Container(
      // v0.6.0 §ui-fit (user: "سایز فونت total traffic و geo route رو کوچیک
      // کن که کنار هم جا بشن"): the pill compacted — smaller padding, icon
      // and VALUE font (13px instead of titleMedium's 16) so both pills fit
      // the hero top row side by side without the route text starving.
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border.withValues(alpha: 0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.show_chart, size: 14, color: c.textPrimary),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // v0.5.3 §fix: scale-down instead of ellipsis — the label
                // (13 caps letters) used to clip to "TOTAL TRA…" on narrow
                // screens; now it shrinks to fit the pill's budget.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('TOTAL TRAFFIC',
                      maxLines: 1,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: c.textSecondary,
                            letterSpacing: 1,
                            fontSize: 8,
                          )),
                ),
                Text(
                  '${_DashboardScreenState.fmtSpeed(downBps)} ↓  '
                  '${_DashboardScreenState.fmtSpeed(upBps)} ↑',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// v0.5.2 §globe — GEO ROUTE chip (hero top-right, mirroring the traffic
/// pill): where the tunnel exits ("Bucharest connected") / home ("Direct ·
/// Tehran") / locating. Same glass pill language as [_TotalTrafficPill].
/// v0.5.2 §user: while the smart switch's pre-connect ladder runs,
/// [ladderText] adds a THIRD live line under the route — the last node
/// tested and its ping ("تست ۳/۱۱ · ۱۲۰ ms") — so the Iran → Romania
/// journey visibly counts through the pool. Null hides the line.
class _GeoRouteChip extends StatelessWidget {
  const _GeoRouteChip({required this.label, this.ladderText});

  final String label;

  /// Live ladder readout; null = hidden (no ladder running).
  final String? ladderText;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    // v0.5.5 §fix: width comes from the hero's shared top row (Expanded →
    // tight bounded width). The chip fills that width, keeps its content
    // hugging the right edge and ellipsizes — no private budget that can
    // collide with the traffic pill anymore.
    return Container(
      // v0.6.0 §ui-fit: compacted in lockstep with [_TotalTrafficPill] —
      // see the note there.
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border.withValues(alpha: 0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.travel_explore, size: 14, color: c.textPrimary),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('GEO ROUTE',
                      maxLines: 1,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: c.textSecondary,
                            letterSpacing: 1,
                            fontSize: 8,
                          )),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                ),
                // v0.5.2 §user — the LIVE ladder line: crossfades in when
                // the sweep starts counting and out when it closes, so the
                // chip never jumps. The empty state keeps a zero-size box
                // (a plain SizedBox would go UNCONSTRAINED inside the
                // AnimatedSwitcher's stack and explode the layout).
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topLeft,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: ladderText == null
                        ? const SizedBox(width: 0, height: 0)
                        : Padding(
                            key: ValueKey(ladderText),
                            padding: const EdgeInsets.only(top: 3),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.bolt_rounded,
                                    size: 12,
                                    color: c.success.withValues(alpha: 0.9)),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(
                                    ladderText!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: c.success,
                                          fontWeight: FontWeight.w600,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures()
                                          ],
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// v0.5.0 §user — TOTAL USAGE card: the mockup's "Total usage". Cumulative
/// up+down bytes since the tunnel came up (real counter deltas), a compact
/// full-width strip under the stats row.
class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.downBytes, required this.upBytes});

  final int downBytes;
  final int upBytes;

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final fa = Localizations.localeOf(context).languageCode == 'fa';
    final total = downBytes + upBytes;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.data_usage_rounded, size: 16, color: c.textMuted),
          const SizedBox(width: 8),
          Text(fa ? 'مصرف کل' : 'Total usage',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: c.textSecondary,
                    letterSpacing: 0.4,
                  )),
          const Spacer(),
          Text(_fmtBytes(downBytes),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: c.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Icon(Icons.south_rounded, size: 12, color: c.textMuted),
          const SizedBox(width: 12),
          Text(_fmtBytes(upBytes),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: c.textSecondary, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Icon(Icons.north_rounded, size: 12, color: c.textMuted),
          const SizedBox(width: 12),
          Text(_fmtBytes(total),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: c.textPrimary,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// v0.4.7 §brand (sheet v2) — the narrow full-width power pill that closes
/// the dashboard hero (the mockup's "⏻ DISCONNECT" bar): hairline ring on
/// dark surface, power glyph left, LIVE localized label tracked out. The
/// whole bar is the tap target; busy swaps the glyph for a spinner.
class _PowerPill extends StatelessWidget {
  const _PowerPill({
    required this.connected,
    required this.busy,
    required this.label,
    required this.onToggle,
  });

  final bool connected;
  final bool busy;
  final String label;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          // v0.6.2 §stop-fix: never disabled. While connecting a tap CANCELS
          // the in-flight attempt (the label reads Cancel, the glyph is a
          // stop square next to the spinner) — the old `busy ? null :` left
          // the user with NO way to stop a connect that was already running.
          onTap: onToggle,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 58,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: connected
                    ? c.success
                    : Colors.white.withValues(alpha: 0.15),
                width: connected ? 1.4 : 1,
              ),
              boxShadow: connected
                  ? [
                      BoxShadow(
                        color: c.success.withValues(alpha: 0.18),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy) ...[
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                  const SizedBox(width: 8),
                  // v0.6.2 §stop-fix: what a tap does while connecting.
                  Icon(Icons.stop_rounded, size: 18, color: c.textPrimary),
                ] else
                  Icon(Icons.power_settings_new_rounded,
                      size: 20, color: connected ? c.success : c.textPrimary),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: connected ? c.success : c.textPrimary,
                        letterSpacing: 5,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
