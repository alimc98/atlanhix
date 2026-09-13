import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../application/dependencies.dart';
import '../application/connection_controller.dart';
import '../domain/entities/proxy_profile.dart';
import '../localization/generated/app_localizations.dart';
import '../theme/theme.dart';
import '../settings/app_settings.dart';
import '../platform/android_vpn.dart' show AndroidVpnPhase;
import 'screens/dashboard_screen.dart';
import 'screens/nodes_screen.dart';
import 'screens/subscriptions_screen.dart';
import 'screens/warp_screen.dart';
import 'screens/routing_editor_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/common_widgets.dart';

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
  StreamSubscription? _sub;
  StreamSubscription? _vpnSub;
  AppSettings? _settings;

  /// v0.4.1: on Android the VpnSession owns the connect lifecycle.
  static final bool isAndroid = Platform.isAndroid;

  static const _icons = [
    (Icons.dashboard_outlined, Icons.dashboard),
    (Icons.hub_outlined, Icons.hub),
    (Icons.rss_feed_outlined, Icons.rss_feed),
    (Icons.shield_outlined, Icons.shield),
    (Icons.alt_route_outlined, Icons.alt_route),
    (Icons.terminal_outlined, Icons.terminal),
    (Icons.settings_outlined, Icons.settings),
  ];

  @override
  void initState() {
    super.initState();
    _sub = widget.deps.connection.states.listen((s) {
      if (!mounted) return;
      setState(() {
        _phase = s.phase;
        _active = s.activeProfile;
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
    final labels = [
      l.navDashboard,
      l.navNodes,
      l.navSubscriptions,
      l.navWarp,
      l.navRouting,
      l.navLogs,
      l.navSettings,
    ];
    final screens = <Widget>[
      DashboardScreen(deps: widget.deps),
      NodesScreen(deps: widget.deps),
      SubscriptionsScreen(deps: widget.deps),
      WarpScreen(deps: widget.deps),
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
              title: Text(labels[_index]),
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
              height: 64,
              labelBehavior:
                  NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                // v0.4.1 § user request: the mobile bar must expose ALL
                // sections — Settings (with the DNS tools) was desktop-only
                // before this, which read as "the app has no settings".
                for (var i = 0; i < labels.length; i++)
                  NavigationDestination(
                    icon: Icon(_icons[i].$1),
                    selectedIcon: Icon(_icons[i].$2),
                    label: labels[i],
                  ),
              ],
            ),
      floatingActionButton: wide
          ? null
          : FloatingActionButton(
              onPressed: _toggleConnect,
              child: Icon(_phase == ConnectionPhase.connected
                  ? Icons.stop
                  : Icons.play_arrow),
            ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [colors.accent, colors.info],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.bolt, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          Text('ATLANHIX',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(letterSpacing: 1.2)),
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
                Icon(
                  selected ? _icons[i].$2 : _icons[i].$1,
                  size: 20,
                  color: selected ? colors.accent : colors.textSecondary,
                ),
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
        return l.connectionFailed;
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
