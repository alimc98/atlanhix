import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../application/dependencies.dart';
import '../application/connection_controller.dart';
import '../domain/entities/proxy_profile.dart';
import '../domain/errors/app_error.dart';
import '../localization/generated/app_localizations.dart';
import '../theme/theme.dart';
import '../settings/app_settings.dart';
import '../platform/android_vpn.dart' show AndroidVpnPhase;
import 'screens/dashboard_screen.dart';
import 'screens/nodes_screen.dart';
import 'screens/warp_screen.dart'; // reached via Settings -> /warp
import 'screens/routing_editor_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/common_widgets.dart';
import 'widgets/atlanhix_logo.dart';
import 'widgets/dashboard_globe.dart' show GlobeAnchor, GlobeAnchorKind;
import 'widgets/globe_backdrop.dart';

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
  StreamSubscription? _sub;
  StreamSubscription? _vpnSub;
  AppSettings? _settings;

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
  }

  @override
  void dispose() {
    _sub?.cancel();
    _vpnSub?.cancel();
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
    final screens = <Widget>[
      DashboardScreen(deps: widget.deps),
      NodesScreen(deps: widget.deps),
      RoutingEditorScreen(
        routingRepo: widget.deps.routingSettingsRepo,
        routing: widget.deps.routingSettings,
        onChanged: () {
          // v0.4.1: routing edits apply on the NEXT connect (no live rewrite).
          if (isAndroid) widget.deps.vpnSession.pendingApply = true;
          if (mounted) setState(() {});
        },
      ),
      LogsScreen(deps: widget.deps),
      SettingsScreen(
        deps: widget.deps,
        themeMode: widget.themeMode,
        onThemeChanged: widget.onThemeChanged,
        onLocaleChanged: widget.onLocaleChanged,
      ),
    ];

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
        // point globe behind every screen; its wash shifts color when the
        // tunnel connects (the app visibly changes mood). The geo anchors
        // (home/exit fixes) ride along when the locator has them.
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
            return GlobeBackdrop(
              connected: connected,
              connecting: connecting,
              anchors: anchors,
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
                child: AnimatedBuilder(
                  animation: _slideCtrl,
                  builder: (context, child) {
                    final t =
                        Curves.easeOutCubic.transform(_slideCtrl.value);
                    final dir = _index >= _previousIndex ? 1.0 : -1.0;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Transform.translate(
                          offset: Offset(dir * (1 - t) * 40, 0),
                          child: Opacity(
                              opacity: t, child: screens[_index]),
                        ),
                      ],
                    );
                  },
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
                  // v0.5.0 §user: the appbar wordmark read ~50% too large on
                  // the phone — halved (15 → 10).
                  const AtlanhixWordmark(height: 10),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      Localizations.localeOf(context).languageCode == 'fa'
                          ? labels[_index]
                          : labels[_index].toUpperCase(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: StatusDot(
                      color: switch (_phase) {
                        ConnectionPhase.connected =>
                          ThemeExt.of(context).success,
                        ConnectionPhase.error => ThemeExt.of(context).error,
                        ConnectionPhase.connecting ||
                        ConnectionPhase.startingCore ||
                        ConnectionPhase.switching ||
                        ConnectionPhase.validating =>
                          ThemeExt.of(context).info,
                        _ => ThemeExt.of(context).textMuted,
                      },
                      label: _statusLabel(l),
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
          height: 68,
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
    final fa = Localizations.localeOf(context).languageCode == 'fa';
    final shown = fa ? label : label.toUpperCase();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 340),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        padding: EdgeInsets.symmetric(
            horizontal: selected ? 14 : 8, vertical: 6),
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
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 240),
              style: Theme.of(context).textTheme.labelSmall!.copyWith(
                    fontSize: selected ? 10 : 9,
                    color: selected ? colors.accent : colors.textMuted,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    letterSpacing: 0.4,
                  ),
              child: Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
