import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../application/connection_controller.dart';
import '../../application/dependencies.dart';
import '../../core/android_node_support.dart';
import '../../settings/app_settings.dart';
import '../../domain/entities/health.dart';
import '../../domain/entities/proxy_profile.dart';
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';
import '../widgets/galaxy_background.dart';
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
    });
    // v0.4.1 §5: single authoritative state — on Android the VPN session is
    // the source of truth; mirror its native phases into the dashboard UI.
    if (widget.deps.vpnSession.controller.isAndroid) {
      _vpnSub = widget.deps.vpnSession.states.listen((_) {
        if (!mounted) return;
        final vs = widget.deps.vpnSession;
        setState(() {
          _phase = vs.uiPhase;
          _active = vs.selectedNode;
          if (vs.lastLatencyMs != null) _latencyMs = vs.lastLatencyMs;
        });
      });
      // Selection changed without a phase event (tap while disconnected):
      // repaint so the tapped node appears the moment it is tapped.
      _selectionSub = widget.deps.vpnSession.selectionChanged.listen((_) {
        if (!mounted) return;
        setState(() {
          _active = widget.deps.vpnSession.selectedNode;
        });
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
    final phaseWord = switch (_phase) {
      ConnectionPhase.connected => l.connected,
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
      } else {
        if (widget.deps.vpnSession.controller.isAndroid) {
          final ok = await widget.deps.vpnSession.connect();
          if (!ok && mounted) {
            final vpn = widget.deps.vpnSession;
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
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(NexusSpacing.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── HERO (v0.5.0 §user — the mockup): the traffic graph now
              // LIVES ON the moon artwork (same Stack), compact 320 px so
              // the power pill stays above the fold; a TOTAL TRAFFIC pill
              // sits top-left and the phase word + node card stay pinned.
              SizedBox(
                height: 320,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Moon artwork (unchanged fall-through to the painted
                    // galaxy when the asset is missing).
                    ShaderMask(
                      shaderCallback: (r) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFFFFFFFF),
                          Color(0xFFFFFFFF),
                          Color(0x00FFFFFF),
                        ],
                        stops: [0.0, 0.62, 1.0],
                      ).createShader(r),
                      blendMode: BlendMode.dstIn,
                      child: Image.asset(
                        'assets/brand/moon_hero.png',
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        // v0.5.0 §lag: the artwork is 1536×1024 but the hero
                        // paints at ~900×320 logical (~3× on a phone). Decode
                        // at the DEVICE pixel size — a full-res decode costs
                        // ~6 MB + GPU upload on every app start and every
                        // memory-pressure reload, for pixels that are
                        // downscaled away.
                        cacheWidth: 1200,
                        errorBuilder: (_, __, ___) => const GalaxyBackground(),
                      ),
                    ),
                    // ── TOTAL TRAFFIC pill (mockup top-left): cumulative
                    // session usage over the icon, current down+up speed
                    // under it. Glass pill, rides the artwork.
                    Positioned(
                      top: 10,
                      left: 4,
                      child: _TotalTrafficPill(
                          downBps: _down.last, upBps: _up.last),
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
              const SizedBox(height: 18),
              // ── NARROW POWER PILL (mockup bottom bar) — full width,
              // hairline ring + power glyph + LIVE localized label. ──
              _PowerPill(
                connected: connected,
                busy: busy,
                label: connected ? l.disconnect : l.connect,
                onToggle: toggle,
              ),
              const SizedBox(height: 20),
              // v0.4.7 §user: QUICK SETTINGS stays, but the CURRENT NODE card
              // and QUICK ACTIONS row are gone — node identity now lives in
              // the Nodes tab, and the power pill above is the single CTA.
              const SizedBox(height: 16),
              // v0.4.4 mockup: RECOMMENDED NODES — top 3 by measured
              // latency (never made up); tap selects AND connects.
              _sectionCard(
                context,
                title: l.recommendedNodes,
                child: _RecommendedNodes(deps: widget.deps, phase: _phase,
                    selectedId: (_onAndroid
                        ? widget.deps.vpnSession.selectedNode?.id
                        : null)),
              ),
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

  Widget _sectionCard(BuildContext context,
      {required String title, required Widget child}) {
    final c = ThemeExt.of(context);
    return Container(
      padding: const EdgeInsets.all(NexusSpacing.lg),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(Localizations.localeOf(context).languageCode == 'fa'
              ? title
              : title.toUpperCase(),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// RECOMMENDED NODES rows: REAL measured latency only — nodes never
/// probed sort last. (v0.4.7 §user: the old QUICK SETTINGS pills and
/// their doc comment were removed with the section itself.)
class _RecommendedNodes extends StatelessWidget {
  const _RecommendedNodes(
      {required this.deps, required this.phase, this.selectedId});

  final AppDependencies deps;
  final ConnectionPhase phase;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final l = AppLocalizations.of(context)!;
    final nodes = deps.profiles.all.where((p) => p.port > 0).toList();
    if (nodes.isEmpty) {
      return Text(l.noNodes,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.textMuted));
    }
    final ranked = [...nodes]..sort((a, b) {
      final la = deps.healthStore.statsOf(a.id)?.lastLatencyMs ?? (1 << 30);
      final lb = deps.healthStore.statsOf(b.id)?.lastLatencyMs ?? (1 << 30);
      return la.compareTo(lb);
    });
    final top = ranked.take(3).toList();
    final connected = phase == ConnectionPhase.connected;
    return Column(
      children: [
        for (final (i, p) in top.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          _row(context, p, connected && p.id == selectedId,
              () => _pick(context, p)),
        ],
      ],
    );
  }

  Future<void> _pick(BuildContext context, ProxyProfile p) async {
    // Select immediately (UI ticks at once), then connect.
    if (deps.vpnSession.controller.isAndroid) {
      if (!AndroidNodeSupport.isRunnable(p)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${p.name}: ${AndroidNodeSupport.notRunnableReason(p) ?? 'cannot run on this device'}')));
        return;
      }
      deps.vpnSession.selectNode(p);
      final ok = await deps.vpnSession.connect();
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AndroidNodeSupport.connectErrorHint(
                    deps.vpnSession.lastError) ??
                'Connection failed')));
      }
    } else {
      await deps.connection.connect(p);
    }
  }

  Widget _row(BuildContext context, ProxyProfile p, bool isConnected,
      VoidCallback onTap) {
    final c = ThemeExt.of(context);
    final l = AppLocalizations.of(context)!;
    final stats = deps.healthStore.statsOf(p.id);
    final lat = stats?.lastLatencyMs;
    final latColor = lat == null
        ? c.textMuted
        : lat < 300
            ? c.success
            : lat < 900
                ? c.warning
                : c.error;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
      child: InkWell(
        borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c.success.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.success.withValues(alpha: 0.4)),
                ),
                child: Icon(Icons.bolt, size: 18, color: c.success),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                      isConnected ? l.connected : l.tapToConnect,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                              color: isConnected ? c.success : c.textMuted,
                              letterSpacing: 0.4),
                    ),
                  ],
                ),
              ),
              if (isConnected)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: c.accent),
                  ),
                  child: Text(l.connected.toUpperCase(),
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(
                              color: c.accent, fontWeight: FontWeight.w700)),
                )
              else if (lat != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: c.border),
                  ),
                  child: Text('$lat ms',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: latColor)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border.withValues(alpha: 0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.show_chart, size: 18, color: c.textPrimary),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('TOTAL TRAFFIC',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: c.textSecondary,
                        letterSpacing: 1.2,
                        fontSize: 9,
                      )),
              Text(
                '${_DashboardScreenState.fmtSpeed(downBps)} ↓  '
                '${_DashboardScreenState.fmtSpeed(upBps)} ↑',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
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
          onTap: busy ? null : onToggle,
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
                if (busy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                else
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
