import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/dependencies.dart';
import '../../diagnostics/diagnostics_service.dart';
import '../../localization/generated/app_localizations.dart';
import '../../settings/app_settings.dart';
import '../../theme/theme.dart';
import 'dns_scan_screen.dart';
import 'routing_editor_screen.dart';

/// v0.4.1 §7 — the REAL Settings screen. Every control reads and writes the
/// persistent [AppSettings] model (no hardcoded toggles); each save flows
/// through the RuntimeConfigBridge so it actually affects runtime behavior.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
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
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);
    final s = deps.appSettings;

    String dnsLabel(DnsModeUi m) => switch (m) {
          DnsModeUi.auto => 'Auto',
          DnsModeUi.system => 'System',
          DnsModeUi.remote => 'Remote (encrypted)',
          DnsModeUi.custom => 'Custom',
        };
    String ipv6Label(IpV6Mode m) => switch (m) {
          IpV6Mode.auto => 'Auto',
          IpV6Mode.on => 'On',
          IpV6Mode.off => 'Off',
        };

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ------------------------------------------------------ General
        _section(context, 'General', [
          SwitchListTile(
            title: const Text('Auto connect'),
            subtitle: const Text('Connect when the app starts'),
            value: s.autoConnect,
            onChanged: (v) => _save(s..autoConnect = v),
          ),
          SwitchListTile(
            title: const Text('Start on boot'),
            subtitle: const Text('Launch Atlanhix after device boot'),
            value: s.startOnBoot,
            onChanged: (v) => _save(s..startOnBoot = v),
          ),
          SwitchListTile(
            title: const Text('Keep VPN alive'),
            subtitle: const Text('Hold the TUN across app backgrounding'),
            value: s.keepVpnAlive,
            onChanged: (v) => _save(s..keepVpnAlive = v),
          ),
          SwitchListTile(
            title: const Text('Notifications'),
            subtitle: const Text('Show connection status notifications'),
            value: s.showNotifications,
            onChanged: (v) => _save(s..showNotifications = v),
          ),
        ]),
        _section(context, l.appearance, [
          Row(
            children: [
              for (final m in NexusThemeMode.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(switch (m) {
                      NexusThemeMode.dark => l.themeDark,
                      NexusThemeMode.light => l.themeLight,
                      NexusThemeMode.oled => l.themeOled,
                    }),
                    selected: themeMode == m,
                    onSelected: (_) => onThemeChanged(m),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            children: [
              for (final loc in const [Locale('en'), Locale('fa')])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(loc.languageCode == 'fa' ? 'فارسی' : 'English'),
                    selected:
                        Localizations.localeOf(context).languageCode ==
                            loc.languageCode,
                    onSelected: (_) => onLocaleChanged(loc),
                  ),
                ),
            ],
          ),
        ]),

        // ---------------------------------------------------------- VPN
        _section(context, 'VPN', [
          ListTile(
            dense: true,
            title: const Text('DNS mode'),
            trailing: DropdownButton<DnsModeUi>(
              value: s.dnsMode,
              items: [
                for (final m in DnsModeUi.values)
                  DropdownMenuItem(value: m, child: Text(dnsLabel(m))),
              ],
              onChanged: (m) => _save(s..dnsMode = m!),
            ),
          ),
          // v0.4.1 § user request: manual remote + domestic DNS entry,
          // plus a real scanner that probes candidates from THIS network.
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextFormField(
              key: ValueKey('rdns-${s.remoteDns}'),
              initialValue: s.remoteDns,
              decoration: const InputDecoration(
                labelText: 'Remote DNS (manual)',
                hintText: '1.1.1.1 · tls://dns.google · https://…/dns-query',
              ),
              onFieldSubmitted: (v) => _save(s..remoteDns = v.trim()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextFormField(
              key: ValueKey('ddns-${s.domesticDns}'),
              initialValue: s.domesticDns,
              decoration: const InputDecoration(
                labelText: 'Domestic DNS (for .ir names)',
                hintText: '178.22.122.100 (Shecan)',
              ),
              onFieldSubmitted: (v) => _save(s..domesticDns = v.trim()),
            ),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.search),
            title: const Text('Scan DNS resolvers'),
            subtitle: const Text(
                'Probe built-in + custom resolvers from this network'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => DnsScanScreen(
                settings: s,
                onSave: _save,
              ),
            )),
          ),
          if (s.dnsMode == DnsModeUi.custom)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextFormField(
                initialValue: s.dnsServers.join(', '),
                decoration: const InputDecoration(
                  labelText: 'DNS servers (comma separated IPs)',
                  hintText: '1.1.1.1, 8.8.8.8',
                ),
                onFieldSubmitted: (v) {
                  final ips = v
                      .split(',')
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList();
                  _save(s..dnsServers.clear()..dnsServers.addAll(ips));
                },
              ),
            ),
          ListTile(
            dense: true,
            title: const Text('IPv6'),
            trailing: SegmentedButton<IpV6Mode>(
              segments: const [
                ButtonSegment(value: IpV6Mode.auto, label: Text('Auto')),
                ButtonSegment(value: IpV6Mode.on, label: Text('On')),
                ButtonSegment(value: IpV6Mode.off, label: Text('Off')),
              ],
              selected: {s.ipv6},
              onSelectionChanged: (sel) => _save(s..ipv6 = sel.first),
            ),
          ),
          ListTile(
            dense: true,
            title: const Text('MTU'),
            subtitle: Text(s.mtu == 0 ? 'Auto (8500)' : '${s.mtu} bytes'),
            trailing: SizedBox(
              width: 110,
              child: TextFormField(
                key: ValueKey('mtu-${s.mtu}'),
                initialValue: s.mtu == 0 ? null : s.mtu.toString(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'Auto'),
                onFieldSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (v.trim().isEmpty) {
                    _save(s..mtu = 0);
                  } else if (n == null || n < 576 || n > 65535) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('MTU must be 576–65535, or empty for Auto')));
                  } else {
                    _save(s..mtu = n);
                  }
                },
              ),
            ),
          ),
          // v0.4.6 §user: WHICH fragment profile the TLS-Fragment pill uses
          // (Conservative is the safe default). Only shown while the pill is
          // on — hiding it when the feature is off matches the rest of the
          // screen's conditional-controls pattern (custom DNS fields etc.).
          if (s.tlsFragment)
            ListTile(
              dense: true,
              title: const Text('Fragment mode'),
              subtitle: Text(_fragmentPresetLabel(s.fragmentPreset)),
              trailing: DropdownButton<FragmentPreset>(
                value: s.fragmentPreset,
                items: [
                  for (final m in FragmentPreset.values)
                    DropdownMenuItem(
                        value: m, child: Text(_fragmentPresetLabel(m))),
                ],
                onChanged: (m) => _save(s..fragmentPreset = m!),
              ),
            ),
          // v0.4.7 §user: MANUAL dial — the user's own packets/length/
          // interval strings, straight onto the Xray fragment option.
          if (s.tlsFragment && s.fragmentPreset == FragmentPreset.manual) ...[
            ListTile(
              dense: true,
              title: const Text('Fragment packets'),
              subtitle: const Text("'tlshello' or '1-3'"),
              trailing: SizedBox(
                width: 130,
                child: TextFormField(
                  key: ValueKey('fp-${s.fragmentManualPackets}'),
                  initialValue: s.fragmentManualPackets,
                  onFieldSubmitted: (v) =>
                      _save(s..fragmentManualPackets = v.trim()),
                ),
              ),
            ),
            ListTile(
              dense: true,
              title: const Text('Fragment length'),
              subtitle: const Text('range, e.g. 100-200'),
              trailing: SizedBox(
                width: 130,
                child: TextFormField(
                  key: ValueKey('fl-${s.fragmentManualLength}'),
                  initialValue: s.fragmentManualLength,
                  onFieldSubmitted: (v) =>
                      _save(s..fragmentManualLength = v.trim()),
                ),
              ),
            ),
            ListTile(
              dense: true,
              title: const Text('Fragment interval (ms)'),
              subtitle: const Text('range, e.g. 10-20'),
              trailing: SizedBox(
                width: 130,
                child: TextFormField(
                  key: ValueKey('fi-${s.fragmentManualInterval}'),
                  initialValue: s.fragmentManualInterval,
                  onFieldSubmitted: (v) =>
                      _save(s..fragmentManualInterval = v.trim()),
                ),
              ),
            ),
          ],
          // v0.4.4 §user-5: TUN vs Proxy mode — explicit, persisted.
          ListTile(
            dense: true,
            title: const Text('Tunnel mode'),
            subtitle: Text(s.proxyMode
                ? 'Proxy — apps that honor the system proxy only'
                : 'TUN — full-device tunnel (recommended)'),
            trailing: SegmentedButton<bool>(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: false, label: Text('TUN')),
                ButtonSegment(value: true, label: Text('Proxy')),
              ],
              selected: {s.proxyMode},
              onSelectionChanged: (sel) => _save(s..proxyMode = sel.first),
            ),
          ),
          // v0.4.4 §user-4: the local mixed-proxy port (was hardcoded 2080).
          ListTile(
            dense: true,
            title: const Text('Local proxy port'),
            subtitle: Text(s.localPort == 0
                ? 'Auto (any free port)'
                : '${s.localPort} — TUN off + Proxy mode binds here'),
            trailing: SizedBox(
              width: 110,
              child: TextFormField(
                key: ValueKey('lport-${s.localPort}'),
                initialValue: s.localPort == 0 ? null : s.localPort.toString(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'Auto'),
                onFieldSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (v.trim().isEmpty) {
                    _save(s..localPort = 0);
                  } else if (n == null || n < 1 || n > 65535) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Port must be 1–65535, or empty for Auto')));
                  } else {
                    _save(s..localPort = n);
                  }
                },
              ),
            ),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Auto reconnect'),
            subtitle: const Text('Repair the tunnel after network loss'),
            value: s.autoReconnect,
            onChanged: (v) => _save(s..autoReconnect = v),
          ),
          ListTile(
            dense: true,
            title: const Text('Connection timeout'),
            subtitle: Text('${s.connectionTimeoutSeconds} s'),
            trailing: SizedBox(
              width: 90,
              child: TextFormField(
                key: ValueKey('ct-${s.connectionTimeoutSeconds}'),
                initialValue: s.connectionTimeoutSeconds.toString(),
                keyboardType: TextInputType.number,
                onFieldSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (n != null && n >= 3 && n <= 120) {
                    _save(s..connectionTimeoutSeconds = n);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Timeout must be 3–120 seconds')));
                  }
                },
              ),
            ),
          ),
          // v0.4.7 §user: Smart Switch re-test cadence (0 = connect-time only).
          ListTile(
            dense: true,
            title: const Text('Smart Switch test interval'),
            subtitle: Text(s.smartSwitchIntervalSeconds <= 0
                ? 'Off — test only at connect time'
                : '${s.smartSwitchIntervalSeconds} s'),
            trailing: SizedBox(
              width: 90,
              child: TextFormField(
                key: ValueKey('ss-${s.smartSwitchIntervalSeconds}'),
                initialValue: s.smartSwitchIntervalSeconds.toString(),
                keyboardType: TextInputType.number,
                onFieldSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (n != null && n >= 0 && n <= 3600) {
                    _save(s..smartSwitchIntervalSeconds = n);
                    deps.vpnSession.enableSmartSwitch();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Interval must be 0–3600 seconds')));
                  }
                },
              ),
            ),
          ),
        ]),

        // ------------------------------------------------------ Routing
        _section(context, 'Routing', [
          ListTile(
            leading: const Icon(Icons.route),
            title: Text('Mode: ${_modeLabel()}'),
            subtitle: const Text('Global or Rule-based routing'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed('/routing'),
          ),
          ListTile(
            leading: const Icon(Icons.apps),
            title: const Text('Application rules'),
            subtitle: Text(
                '${deps.routingSettings.directApps.length} direct · '
                '${deps.routingSettings.proxyApps.length} proxy apps'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed('/routing/apps'),
          ),
        ]),

        // --------------------------------------------------------- WARP
        _section(context, 'WARP', [
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            // v0.4.8 §user: the chain MODE is the single WARP authority —
            // the separate warpEnabled flag no longer exists.
            title: Text(s.warpChainMode == WarpChainMode.off
                ? 'Disabled'
                : 'Chained (${s.warpChainMode.name})'),
            subtitle: const Text('WARP registration & chaining'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed('/warp'),
          ),
        ]),

        // -------------------------------------------------- Diagnostics
        _section(context, 'Diagnostics', [
          SwitchListTile(
            dense: true,
            title: const Text('Traffic statistics'),
            value: s.trafficStats,
            onChanged: (v) => _save(s..trafficStats = v),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Connection logs'),
            value: s.connectionLogs,
            onChanged: (v) => _save(s..connectionLogs = v),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Debug logging'),
            subtitle: const Text('Verbose engine logs (larger output)'),
            value: s.debugLogging,
            onChanged: (v) => _save(s..debugLogging = v),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => _runDiagnostics(context),
            icon: const Icon(Icons.bug_report_outlined),
            label: const Text('Run Diagnostics'),
          ),
        ]),
        _section(context, l.about, [
          const Text('Atlanhix 0.4.1'),
          const SizedBox(height: 4),
          Text(
            'Flutter ${const String.fromEnvironment("FLUTTER_VERSION", defaultValue: "3.47")} · '
            'sing-box (libbox) engine · WARP · WireGuard · AmneziaWG · MasterDNSVPN',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: c.textSecondary),
          ),
        ]),
      ],
    );
  }

  String _modeLabel() {
    // OPT-IN: show Off until the user explicitly enables routing.
    if (!deps.routingSettings.enabled) return 'Off';
    final mode = deps.routingSettings.mode.name;
    return mode[0].toUpperCase() + mode.substring(1);
  }

  /// v0.4.6 §user: user-facing labels for the fragment intensity picker.
  String _fragmentPresetLabel(FragmentPreset m) => switch (m) {
        FragmentPreset.conservative =>
          'Conservative — tlshello 10-40, safest',
        FragmentPreset.defaultPreset => 'Default — tlshello 100-200, balanced',
        FragmentPreset.aggressive =>
          'Aggressive — 1-3 packets, hardest to detect',
        FragmentPreset.auto =>
          'Auto — try safe→strong on failure, remember the winner',
        FragmentPreset.manual => 'Manual — set packets/length/interval below',
      };

  Future<void> _save(AppSettings s) async {
    await deps.appSettingsRepo.save(s);
    // v0.4.7 §user: the fragment dial + preset live on the core manager —
    // persist AND propagate so the next start honors the change.
    deps.cores.fragmentPreset = s.fragmentPreset;
    deps.connection.fragmentPreset = s.fragmentPreset;
    deps.cores.fragmentManualPackets = s.fragmentManualPackets;
    deps.cores.fragmentManualLength = s.fragmentManualLength;
    deps.cores.fragmentManualInterval = s.fragmentManualInterval;
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    final c = ThemeExt.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Future<void> _runDiagnostics(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final report = await DiagnosticsService(
      cores: deps.cores,
      routing: deps.connection.routing,
      dns: deps.connection.dns,
    ).collect();
    final text = DiagnosticsService.renderText(report);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Diagnostics report'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: text)),
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    messenger.hideCurrentSnackBar();
  }
}
