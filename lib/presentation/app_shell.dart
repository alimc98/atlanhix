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

class _AppShellState extends State<AppShell> {
  int _index = 0;
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
    super.dispose();
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
    final body = Row(
      children: [
        if (wide) _buildRail(labels),
        Expanded(child: screens[_index]),
      ],
    );

    return Scaffold(
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
      body: body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index.clamp(0, labels.length - 1),
              onDestinationSelected: (i) => setState(() => _index = i),
              height: 72,
              // v0.4.4 brand sheet: tiles on Surface, hairline Border,
              // rounded-square active indicator (not a soft blob).
              backgroundColor: ThemeExt.of(context).surface,
              indicatorColor: ThemeExt.of(context).accentSoft,
              indicatorShape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              shadowColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              labelBehavior:
                  NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                // v0.4.1 § user request: the mobile bar must expose ALL
                // sections — Settings (with the DNS tools) was desktop-only
                // before this, which read as "the app has no settings".
                for (var i = 0; i < labels.length; i++)
                  NavigationDestination(
                    icon: _navIcon(i, selected: false),
                    selectedIcon: _navIcon(i, selected: true),
                    label: labels[i],
                  ),
              ],
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
          Padding(
            padding: const EdgeInsets.all(16),
            child: ConnectButton(phase: _phase, onToggle: _toggleConnect),
          ),
        ],
      ),
    );
  }

  Widget _brand(ThemeExt colors) {
    // v0.4.7 §brand (sheet v2): stacked mark + wordmark block, with the
    // sheet's tagline "CONNECT BEYOND BORDERS" underneath — the full brand
    // lockup leads the rail exactly like the sheet's left column.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AtlanhixBrandBlock(height: 88),
          const SizedBox(height: 8),
          Image.asset(
            'assets/brand/tagline.png',
            height: 12,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
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
          onTap: () => setState(() => _index = i),
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
