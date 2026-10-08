import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../application/dependencies.dart';
import '../application/connection_controller.dart';
import '../domain/entities/proxy_profile.dart';
import '../domain/errors/app_error.dart';
import '../localization/generated/app_localizations.dart';
import '../theme/theme.dart';
import '../platform/android_vpn.dart' show AndroidVpnPhase;
import 'screens/dashboard_screen.dart';
import 'tab_stage.dart';
import 'screens/nodes_screen.dart';
import 'screens/routing_editor_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/common_widgets.dart';
import 'widgets/atlanhix_logo.dart';
import 'widgets/dashboard_globe.dart' show GlobeAnchor, GlobeAnchorKind;
import 'widgets/globe_backdrop.dart';
import 'globe/globe_geo.dart';

/// Responsive shell: desktop sidebar (§52) / mobile bottom navigation (§51).
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.deps,
    required this.themeMode,
    required this.onThemeChanged,
    required this.onLocaleChanged,
  });

  final AppDependencies deps;
  final NexusThemeMode themeMode;
  final ValueChanged<NexusThemeMode> onThemeChanged;
  final ValueChanged<Locale> onLocaleChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  int _previousIndex = 0;
  late final AnimationController _slideCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    value: 1,
  );
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  ProxyProfile? _active;
  AppError? _lastError;
  StreamSubscription<void>? _sub;
  StreamSubscription<void>? _vpnSub;
  StreamSubscription<void>? _selSub;

  /// v0.4.1: on Android the VpnSession owns the connect lifecycle.
  static final bool isAndroid = Platform.isAndroid;

  // v0.5.0 §user: the five tab icons are the user's CLEANED brand tiles,
  // supplied as a DARK set (white-on-charcoal) and a LIGHT set (ink-on-
  // white). _BrandNavIcon picks the right set from the theme brightness.
  static const _navTabs = [
    'nav_dashboard',
    'nav_nodes',
    'nav_routing',
    'nav_logs',
    'nav_settings',
  ];

  // v0.6.4 §speed: memoized tab screens. Every shell setState (VPN phase
  // events, the header status pill, a tab move) used to allocate FRESH
  // instances of all five screens, so Flutter re-ran their entire build
  // methods for updates that only touch the header/pill/globe — while the
  // screens already subscribe to their own data streams and never asked
  // for that rebuild. Cached per real input:
  //   * SettingsScreen is re-made when the theme mode changes;
  //   * RoutingEditorScreen is NEVER cached — `deps.routingSettings` is
  //     replaced wholesale on subscription-carried routing, so a cached
  //     instance would show stale rules.
  NexusThemeMode? _screensThemeMode;
  Widget? _dashCache;
  Widget? _nodesCache;
  Widget? _logsCache;
  Widget? _settingsCache;

  List<Widget> _screens() {
    final themeMode = widget.themeMode;
    if (_screensThemeMode != themeMode) {
      _screensThemeMode = themeMode;
      _settingsCache = null;
    }
    return [
      _dashCache ??= DashboardScreen(
        deps: widget.deps,
        // v0.6.4 § redesign: the dashboard's two chevrons are real
        // navigation, wired here (the shell owns the tab index).
        onOpenNodes: () => _goTo(1),
        onOpenRouting: () => _goTo(2),
      ),
      _nodesCache ??= NodesScreen(deps: widget.deps),
      RoutingEditorScreen(
        routingRepo: widget.deps.routingSettingsRepo,
        routing: widget.deps.routingSettings,
        onChanged: () {
          // v0.4.1: routing edits apply on the NEXT connect (no live rewrite).
          if (isAndroid) widget.deps.vpnSession.pendingApply = true;
          if (mounted) setState(() {});
        },
      ),
      _logsCache ??= LogsScreen(deps: widget.deps),
      _settingsCache ??= SettingsScreen(
        deps: widget.deps,
        themeMode: themeMode,
        onThemeChanged: widget.onThemeChanged,
        onLocaleChanged: widget.onLocaleChanged,
      ),
    ];
  }

  /// Brand tile icon for tab [i]; [selected] controls opacity only.
  static Widget _navIcon(int i, {required bool selected}) => _BrandNavIcon(
        name: _navTabs[i],
        selected: selected,
      );

  @override
  void initState() {
    super.initState();
    _sub = widget.deps.connection.states.listen((s) {
      if (!mounted) return;
      setState(() {
        _phase = s.phase;
        _active = s.activeProfile;
        // v0.4.6: keep the last error so the status label can show WHY
        // (engine stderr tail) instead of a bare "Connection failed".
        _lastError = s.error;
      });
    });
    // v0.4.1 §5: on Android the VpnSession state machine is authoritative —
    // it overrides whatever the desktop controller reports.
    if (isAndroid) {
      _vpnSub = widget.deps.vpnSession.states.listen((_) {
        if (!mounted) return;
        setState(() {
          _phase = widget.deps.vpnSession.uiPhase;
          _active = widget.deps.vpnSession.selectedNode;
        });
      });
      _phase = widget.deps.vpnSession.uiPhase;
      _active = widget.deps.vpnSession.selectedNode;
    }
    // v0.5.4 §globe3d: the globe's DESTINATION previews the tapped node
    // the moment the user selects it (before any connect) — the session's
    // selection event moves the pin immediately on every platform.
    _selSub = widget.deps.vpnSession.selectionChanged.listen((_) {
      if (!mounted) return;
      final sel = widget.deps.vpnSession.selectedNode;
      if (sel?.id != _active?.id) setState(() => _active = sel);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _vpnSub?.cancel();
    _selSub?.cancel();
    _slideCtrl.dispose();
    super.dispose();
  }

  /// v0.5.2 §user — tab switch: play the slide EVERY time (restarting the
  /// controller from 0), remembering the direction the user moved.
  void _goTo(int i) {
    if (i == _index) return;
    setState(() {
      _previousIndex = _index;
      _index = i;
      _slideCtrl.forward(from: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final l = AppLocalizations.of(context)!;
    // v0.4.3: 7 tabs -> 5. Subscriptions merged into Nodes (segmented);
    // WARP merged into Settings (plus the inline chain card in Nodes/Dash).
    final labels = [
      l.navDashboard,
      l.navNodes,
      l.navRouting,
      l.navLogs,
      l.navSettings,
    ];
    final screens = _screens();

    // Settings -> WARP row pushes /warp; the shell owns the Navigator.
    // (registered in main.dart routes)
    final connected = _phase == ConnectionPhase.connected;
    final connecting = const [
      ConnectionPhase.connecting,
      ConnectionPhase.startingCore,
      ConnectionPhase.switching,
      ConnectionPhase.validating,
    ].contains(_phase);
    final body = Stack(
      fit: StackFit.expand,
      children: [
        // v0.5.2 §user — THE GLOBE IS THE APP BACKGROUND: one full-screen
        // 3D planet behind every screen. v0.5.4 §globe3d: the SOURCE is
        // the user's geo fix (country-level is fine) and the DESTINATION
        // is the selected node — resolved by host fix first, then the
        // country hints the node name/host carry. The route/flow animates
        // through the REAL connection phases (no invented VPN state).
        Positioned.fill(
          child: Builder(builder: (context) {
            final geo = widget.deps.geo;
            final home = geo.lastHome;
            final exit = connected ? geo.lastExit : null;
            final anchors = <GlobeAnchor>[
              if (home != null)
                GlobeAnchor(
                    lat: home.lat, lon: home.lon, kind: GlobeAnchorKind.home),
              if (exit != null)
                GlobeAnchor(
                    lat: exit.lat,
                    lon: exit.lon,
                    kind: GlobeAnchorKind.exit,
                    active: true),
            ];
            final src = home == null
                ? null
                : GlobeLocation(
                    lat: home.lat,
                    lon: home.lon,
                    label: home.hasCity ? home.city : home.countryName,
                    exact: true,
                  );
            // Provisional destination while connecting = the node's own
            // location; once connected the honest EXIT fix replaces it.
            final dest = exit != null
                ? GlobeLocation(
                    lat: exit.lat,
                    lon: exit.lon,
                    label: exit.hasCity ? exit.city : exit.countryName,
                    exact: true,
                  )
                : destinationForNode(_active, geo);
            return GlobeBackdrop(
              connected: connected,
              connecting: connecting,
              disconnecting: _phase == ConnectionPhase.disconnecting,
              error: _phase == ConnectionPhase.error,
              anchors: anchors,
              source: src,
              destination: dest,
            );
          }),
        ),
        Row(
          children: [
            if (wide) _buildRail(labels),
            Expanded(
              child: ClipRect(
                // v0.5.2 §user — SLIDE transition between tabs: a soft
                // directional slide driven by one 340 ms controller.
                // v0.5.3 §user-fix ("هر تب که عوض می‌کنم همه چیز از نو لود
                // می‌شود"): the screens now LIVE in an IndexedStack — their
                // State objects survive tab switches (LiveMonitor keeps its
                // sample, the dashboard keeps its graphs/stats, the nodes
                // list keeps its scroll). The slide animates the STACK's
                // transform; the hidden screens are simply OFFSTAGE (zero
                // paint cost, full state retention). TickerMode inside each
                // screen parks its animations while offstage.
                child: AnimatedBuilder(
                  animation: _slideCtrl,
                  builder: (context, child) {
                    final t =
                        Curves.easeOutCubic.transform(_slideCtrl.value);
                    final dir = _index >= _previousIndex ? 1.0 : -1.0;
                    return Transform.translate(
                      offset: Offset(dir * (1 - t) * 40, 0),
                      child: Opacity(opacity: t, child: child),
                    );
                  },
                  child: IndexedStack(
                    index: _index,
                    // v0.6.4 §battery: the IndexedStack keeps every tab ALIVE
                    // (state retention), which also keeps its timers running.
                    // Each screen learns here whether it is the on-stage tab
                    // and parks its periodic work while it is not.
                    children: [
                      for (var i = 0; i < screens.length; i++)
                        TabStageScope(
                          index: i,
                          active: i == _index,
                          child: screens[i],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );

    return Scaffold(
      // v0.5.2 §user: transparent scaffold — the globe backdrop (the
      // Stack's base layer in `body`) IS the page background now.
      backgroundColor: Colors.transparent,
      appBar: wide
          ? null
          : AppBar(
              // v0.4.4 brand sheet: geometric 'A' mark + wide-tracked
              // wordmark leads the header, page name follows.
              title: Row(
                children: [
                  // v0.6.4 § redesign: the mockup's two-line header —
                  // the wordmark stacked OVER the page name.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const AtlanhixWordmark(height: 13),
                      Text(
                        Localizations.localeOf(context).languageCode == 'fa'
                            ? labels[_index]
                            : labels[_index].toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              letterSpacing: 2.2,
                              fontSize: 9,
                              color: ThemeExt.of(context).textSecondary,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                ],
              ),
              actions: [
                // v0.6.4 § redesign: the header's status pill (the
                // mockup's ● Connected >" chip). It is a
                // control, not a label: a tap opens the Nodes tab.
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Center(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _goTo(1),
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            border:
                                Border.all(color: ThemeExt.of(context).border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              StatusDot(
                                color: switch (_phase) {
                                  ConnectionPhase.connected =>
                                    ThemeExt.of(context).success,
                                  ConnectionPhase.error =>
                                    ThemeExt.of(context).error,
                                  ConnectionPhase.connecting ||
                                  ConnectionPhase.startingCore ||
                                  ConnectionPhase.switching ||
                                  ConnectionPhase.validating =>
                                    ThemeExt.of(context).info,
                                  _ => ThemeExt.of(context).textMuted,
                                },
                                label: _statusLabel(l),
                              ),
                              const SizedBox(width: 2),
                              Icon(Icons.chevron_right_rounded,
                                  size: 16,
                                  color: ThemeExt.of(context).textSecondary),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
      body: body,      bottomNavigationBar: wide
          ? null
          : _ExpressiveNavBar(
              labels: labels,
              index: _index,
              onTap: (i) => _goTo(i),
            ),
      // v0.4.7 §user: the floating green play button is GONE — the
      // dashboard's power pill is the single connect control (sheet v2).
      // A second floating connect control competed with it and confused
      // state reading.
      floatingActionButton: null,
    );
  }

  Widget _buildRail(List<String> labels) {
    final colors = ThemeExt.of(context);
    return Container(
      width: 224,
      color: colors.surface,
      child: Column(
        children: [
          const SizedBox(height: 24),
          _brand(colors),
          const SizedBox(height: 16),
          for (var i = 0; i < labels.length; i++) _railItem(i, labels[i], colors),
          const Spacer(),
          // v0.5.0 §user: the circular white ConnectButton that sat here is
          // GONE — the dashboard's power pill is the single connect control
          // on every platform (same decision as v0.4.7 made for mobile).
        ],
      ),
    );
  }

  Widget _brand(ThemeExt colors) {
    // v0.5.0 §user: the NEW brand lockup leads the rail — the ATLANTHIX
    // wordmark (intro.png, same art the splash shows) over the theme-aware
    // wide-tracked logotype. The old stacked mark+wordmark block is gone.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Image.asset(
            'assets/brand/intro.png',
            height: 56,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 10),
          const AtlanhixWordmark(height: 11),
        ],
      ),
    );
  }

  Widget _railItem(int i, String label, ThemeExt colors) {
    final selected = _index == i;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? colors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
        child: InkWell(
          borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
          onTap: () => _goTo(i),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                _navIcon(i, selected: selected),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: selected ? colors.accent : colors.textPrimary,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _statusLabel(AppLocalizations l) {
    switch (_phase) {
      case ConnectionPhase.connected:
        return l.connected;
      case ConnectionPhase.error:
        // v0.4.6: surface the engine stderr tail (redacted, one line) —
        // "Connection failed — xray: lookup …: no such host" tells the
        // user what the engine actually said. Bounded so the sidebar
        // label stays sane; the full text lives in the Logs screen.
        final detail = _lastError?.likelyCauses.isNotEmpty == true
            ? _lastError!.likelyCauses.first
            : null;
        return detail == null || detail.isEmpty
            ? l.connectionFailed
            : '${l.connectionFailed} — $detail';
      case ConnectionPhase.connecting:
      case ConnectionPhase.startingCore:
      case ConnectionPhase.switching:
      case ConnectionPhase.validating:
        return l.connecting;
      default:
        return l.disconnected;
    }
  }

  Future<void> _toggleConnect() async {
    final c = widget.deps.connection;
    // v0.4.1 §2: on Android, connect flows through the VpnSession (real
    // VpnService.prepare → consent → TUN → engine → probe). The desktop
    // core path is not used on Android (no sing-box binary in-app).
    if (isAndroid) {
      final vpn = widget.deps.vpnSession;
      if (vpn.isConnected) {
        await vpn.disconnect();
      } else {
        final ok = await vpn.connect();
        if (!ok && mounted) {
          final phase = vpn.phase;
          final message = switch (phase) {
            AndroidVpnPhase.permissionDenied =>
              'VPN permission is required to establish the connection.',
            AndroidVpnPhase.revoked =>
              'VPN permission was revoked. Press Connect to grant it again.',
            _ => 'Connection failed: ${vpn.controller.lastErrorCode ?? ''}\n'
                '${vpn.controller.lastDetail ?? ''}',
          };
          _showConnectError(message, phase == AndroidVpnPhase.permissionDenied);
        }
      }
      if (mounted) setState(() {});
      return;
    }
    if (_phase == ConnectionPhase.connected) {
      await c.disconnect();
    } else {
      await c.smartConnect();
    }
  }

  void _showConnectError(String message, bool permissionIssue) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(permissionIssue ? 'VPN permission denied' : 'Connection failed'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _toggleConnect(); // §3 Retry
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// v0.4.7 §brand — one of the five brand-sheet nav tiles as a tab icon.
/// The artwork is baked white-on-charcoal; selection is expressed with
/// opacity (dim tile when idle, full tile when active) so a single asset
/// set serves both states and the tile's own charcoal stays visible on
/// the NavigationBar surface.
class _BrandNavIcon extends StatelessWidget {
  const _BrandNavIcon({required this.name, required this.selected});

  /// Asset base name under assets/brand/ — `_dark.png` / `_light.png` is
  /// appended per the ambient theme brightness (v0.5.0 §user).
  final String name;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Opacity(
      opacity: selected ? 1.0 : 0.55,
      child: Image.asset(
        'assets/brand/${name}_${dark ? 'dark' : 'light'}.png',
        width: 30,
        height: 30,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const SizedBox(width: 30, height: 30),
      ),
    );
  }
}

/// v0.5.2 §user — EXPRESSIVE PILL NAVIGATION BAR. A floating rounded bar
/// (hairline border, glass surface) whose active tab is a MORPHING pill:
/// the pill slides + stretches between destinations with a spring, the
/// active icon scales up gently and the label fades in. Pure Flutter
/// animation (no third-party dependency), theme-token only.
class _ExpressiveNavBar extends StatelessWidget {
  const _ExpressiveNavBar({
    required this.labels,
    required this.index,
    required this.onTap,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final l = AppLocalizations.of(context)!;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: Container(
          // v0.6.4 §ui-fix: the selected destination's icon scales to 1.12,
          // which pushed the pill past the old 68 px shell (an 11 px
          // "BOTTOM OVERFLOWED" stripe on every 420 dpi phone).
          height: 74,
          decoration: BoxDecoration(
            color: c.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(34),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: _PillDestination(
                    label: labels[i],
                    icon: _AppShellState._navIcon(i, selected: index == i),
                    selected: index == i,
                    colors: c,
                    onTap: () => onTap(i),
                    navLabel: l,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PillDestination extends StatelessWidget {
  const _PillDestination({
    required this.label,
    required this.icon,
    required this.selected,
    required this.colors,
    required this.onTap,
    required this.navLabel,
  });

  final String label;
  final Widget icon;
  final bool selected;
  final ThemeExt colors;
  final VoidCallback onTap;
  final AppLocalizations navLabel;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 340),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        padding: EdgeInsets.symmetric(
            horizontal: selected ? 14 : 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? colors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: selected ? colors.accent.withValues(alpha: 0.4) : Colors.transparent,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // The active icon breathes (gentle scale) via an implicit
            // animation — a soft handoff, not a jump.
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.92, end: selected ? 1.12 : 0.92),
              duration: const Duration(milliseconds: 340),
              curve: Curves.easeOutBack,
              builder: (context, s, child) =>
                  Transform.scale(scale: s, child: child),
              child: IconTheme.merge(
                data: IconThemeData(
                  size: 22,
                  color: selected ? colors.accent : colors.textMuted,
                ),
                child: icon,
              ),
            ),
            const SizedBox(height: 2),
            // v0.5.3 §fix (user: "das…" / "sett…" — labels truncated): the
            // UPPERCASE transform made Latin labels ~25% wider than the
            // 5-slot pill budget. Keep the ORIGINAL casing (the tab labels
            // are short words), drop the fixed font to 8.5/9.5, and allow
            // the text to scale down instead of ellipsizing.
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 240),
              style: Theme.of(context).textTheme.labelSmall!.copyWith(
                    fontSize: selected ? 9.5 : 8.5,
                    color: selected ? colors.accent : colors.textMuted,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    letterSpacing: 0.2,
                  ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, maxLines: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
