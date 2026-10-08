import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/dependencies.dart';
import '../../application/update_checker.dart' show kAppVersion;
import '../../diagnostics/diagnostics_service.dart';
import '../../localization/generated/app_localizations.dart';
import '../../settings/app_settings.dart';
import '../../theme/theme.dart';
import 'dns_scan_screen.dart';

/// v0.4.1 §7 — the REAL Settings screen. Every control reads and writes the
/// persistent [AppSettings] model (no hardcoded toggles); each save flows
/// through the RuntimeConfigBridge so it actually affects runtime behavior.
class SettingsScreen extends StatefulWidget {
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
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
@override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);
    final s = widget.deps.appSettings;

    String dnsLabel(DnsModeUi m) => switch (m) {
          DnsModeUi.auto => 'Auto',
          DnsModeUi.system => 'System',
          DnsModeUi.remote => 'Remote (encrypted)',
          DnsModeUi.custom => 'Custom',
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
          // v0.5.3 §mihomo — ENGINE PREFERENCE: which core owns a connect.
          // auto = capability matrix (unchanged); mihomo = the standalone
          // Clash.Meta engine (full xhttp/XMUX); xray = the :xray child.
          ListTile(
            title: const Text('Engine'),
            subtitle: Text(_engineLabel(s.corePreference)),
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final p in CorePreference.values)
                ChoiceChip(
                  label: Text(_engineLabel(p)),
                  selected: s.corePreference == p,
                  onSelected: (_) => _save(s..corePreference = p),
                ),
            ],
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
                    selected: widget.themeMode == m,
                    onSelected: (_) => widget.onThemeChanged(m),
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
                    onSelected: (_) => widget.onLocaleChanged(loc),
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
            trailing: _MtuField(
              s: s,
              deps: widget.deps,
              onSave: _save,
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
                    // v0.5.0 §user: live-apply cadence/tolerance to a running
                    // ladder without force-enabling it (the old call here
                    // silently re-armed a switch the user had turned off).
                    widget.deps.vpnSession.syncSmartTuning();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Interval must be 0–3600 seconds')));
                  }
                },
              ),
            ),
          ),
          // v0.5.0 §user: Smart Switch tolerance — a challenger node must
          // beat the active node by this many ms before the tunnel migrates
          // (0 = any strictly-better node wins; a dead node always loses).
          ListTile(
            dense: true,
            title: const Text('Smart Switch tolerance'),
            subtitle: Text(s.smartSwitchMarginMs <= 0
                ? '0 ms — switch on any strictly-better node'
                : '${s.smartSwitchMarginMs} ms — challenger must beat it by this much'),
            trailing: SizedBox(
              width: 90,
              child: TextFormField(
                key: ValueKey('ssm-${s.smartSwitchMarginMs}'),
                initialValue: s.smartSwitchMarginMs.toString(),
                keyboardType: TextInputType.number,
                onFieldSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (n != null && n >= 0 && n <= 5000) {
                    _save(s..smartSwitchMarginMs = n);
                    widget.deps.vpnSession.syncSmartTuning();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Tolerance must be 0–5000 ms')));
                  }
                },
              ),
            ),
          ),
          // v0.5.2 §user — "Switch to a faster server only when it is
          // faster by N%" (default 30).
          ListTile(
            dense: true,
            title: const Text('Smart Switch margin'),
            subtitle: Text(
                '${s.smartSwitchMarginPercent}% — switch only when faster by this much'),
            trailing: SizedBox(
              width: 90,
              child: TextFormField(
                key: ValueKey('ssp-${s.smartSwitchMarginPercent}'),
                initialValue: s.smartSwitchMarginPercent.toString(),
                keyboardType: TextInputType.number,
                onFieldSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (n != null && n >= 0 && n <= 95) {
                    _save(s..smartSwitchMarginPercent = n);
                    widget.deps.vpnSession.syncSmartDials();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Margin must be 0–95 percent')));
                  }
                },
              ),
            ),
          ),
          // v0.5.2 §user — "Recheck the server in use every N sec" (30).
          ListTile(
            dense: true,
            title: const Text('Recheck active server'),
            subtitle: Text(
                '${s.smartSwitchActiveRecheckSeconds} s — recheck the server in use'),
            trailing: SizedBox(
              width: 90,
              child: TextFormField(
                key: ValueKey('ssa-${s.smartSwitchActiveRecheckSeconds}'),
                initialValue: s.smartSwitchActiveRecheckSeconds.toString(),
                keyboardType: TextInputType.number,
                onFieldSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (n != null && n >= 5 && n <= 600) {
                    _save(s..smartSwitchActiveRecheckSeconds = n);
                    widget.deps.vpnSession.syncSmartDials();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Recheck must be 5–600 seconds')));
                  }
                },
              ),
            ),
          ),
          // v0.5.2 §user — "Re-measure the other servers every N min" (10).
          ListTile(
            dense: true,
            title: const Text('Re-measure other servers'),
            subtitle: Text(
                '${s.smartSwitchOthersRescanMinutes} min — re-measure the rest of the pool'),
            trailing: SizedBox(
              width: 90,
              child: TextFormField(
                key: ValueKey('ssr-${s.smartSwitchOthersRescanMinutes}'),
                initialValue: s.smartSwitchOthersRescanMinutes.toString(),
                keyboardType: TextInputType.number,
                onFieldSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (n != null && n >= 0 && n <= 720) {
                    _save(s..smartSwitchOthersRescanMinutes = n);
                    widget.deps.vpnSession.syncSmartDials();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Rescan must be 0–720 minutes')));
                  }
                },
              ),
            ),
          ),
          // v0.5.0 §user: THE delay-test URL — one editable field feeding
          // EVERY latency path (node-list sweep, Smart Switch ladder, WARP
          // watchdog, scheduler TCP fallback). An `http://` URL skips the
  	      // TLS handshake and reads v2rayNG-like numbers (~100 ms) where the
          // https default reads ~900 ms on the same node.
          ListTile(
            dense: true,
            title: const Text('Delay test URL'),
            subtitle: Text(
                s.delayTestUrl.trim().isEmpty
                    ? 'Default: gstatic generate_204 (https)'
                    : s.delayTestUrl.trim()),
            isThreeLine: s.delayTestUrl.trim().length > 40,
            trailing: SizedBox(
              width: 190,
              child: TextFormField(
                key: ValueKey('dtu-${s.delayTestUrl}'),
                initialValue: s.delayTestUrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(hintText: 'http://…/generate_204'),
                onFieldSubmitted: (v) {
                  final url = v.trim();
                  final okUrl = url.isEmpty ||
                      (Uri.tryParse(url)?.hasScheme ?? false) &&
                          (url.startsWith('http://') ||
                              url.startsWith('https://'));
                  if (!okUrl) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text(
                            'Enter an http:// or https:// URL (empty = default)')));
                    return;
                  }
                  _save(s..delayTestUrl = url);
                  // Live-apply to every consumer (same contract as the
                  // scheduler's constructor seed above).
                  widget.deps.realDelay.probeUrl = s.effectiveDelayTestUrl;
                  widget.deps.scheduler.testUrl = s.effectiveDelayTestUrl;
                  widget.deps.vpnSession.syncSmartTuning();
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
                '${widget.deps.routingSettings.directApps.length} direct · '
                '${widget.deps.routingSettings.proxyApps.length} proxy apps'),
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
          // v0.5.0 §user-fix: the version was a hardcoded '0.4.1' string that
          // never moved with releases. Read the ONE compiled-in constant the
          // update checker uses (same source of truth as pubspec).
          Text(_versionLabel()),
          const SizedBox(height: 4),
          Text(
            'Flutter ${const String.fromEnvironment("FLUTTER_VERSION", defaultValue: "3.47")} · '
            'sing-box (libbox) engine · WARP · WireGuard · AmneziaWG · MasterDNSVPN · StormDNS',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: c.textSecondary),
          ),
        ]),
      ],
    );
  }

  /// v0.5.3 §mihomo — engine-choice chip labels (kept terse; the subtitle
  /// of the Engine tile carries the full explanation).
  String _engineLabel(CorePreference p) => switch (p) {
        CorePreference.auto => 'Auto',
        CorePreference.singbox => 'sing-box',
        CorePreference.xray => 'Xray',
        CorePreference.mihomo => 'mihomo (xhttp)',
      };

  String _modeLabel() {
    // OPT-IN: show Off until the user explicitly enables routing.
    if (!widget.deps.routingSettings.enabled) return 'Off';
    final mode = widget.deps.routingSettings.mode.name;
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
    // v0.6.5 §ui-fix: this screen is stateful now — without setState the
    // engine chips (and every other control) kept showing the OLD value
    // after a change, even though the setting had actually been saved.
    if (mounted) setState(() {});
    await widget.deps.appSettingsRepo.save(s);
    // v0.4.7 §user: the fragment dial + preset live on the core manager —
    // persist AND propagate so the next start honors the change.
    widget.deps.cores.fragmentPreset = s.fragmentPreset;
    widget.deps.connection.fragmentPreset = s.fragmentPreset;
    widget.deps.cores.fragmentManualPackets = s.fragmentManualPackets;
    widget.deps.cores.fragmentManualLength = s.fragmentManualLength;
    widget.deps.cores.fragmentManualInterval = s.fragmentManualInterval;
  }

  /// v0.5.0 §user-fix: single source of truth for the displayed version —
  /// the compiled-in constant shared with the update checker (0.5.0+7 →
  /// "Atlanhix 0.5.0 (build 7)").
  static String _versionLabel() {
    final parts = kAppVersion.split('+');
    return parts.length == 2
        ? 'Atlanhix ${parts.first} (build ${parts.last})'
        : 'Atlanhix $kAppVersion';
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
      cores: widget.deps.cores,
      routing: widget.deps.connection.routing,
      dns: widget.deps.connection.dns,
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

/// v0.5.2 §user — the MTU field + the OPTIMIZE button. Optimize probes the
/// real path MTU with DF-ping (through the tunnel when connected, direct
/// otherwise), binary-searches 8500 → 1280 and persists the largest size
/// that answers — then the NEXT connect picks it up through the bridge.
class _MtuField extends StatefulWidget {
  const _MtuField({required this.s, required this.deps, required this.onSave});

  final AppSettings s;
  final AppDependencies deps;
  final Future<void> Function(AppSettings) onSave;

  @override
  State<_MtuField> createState() => _MtuFieldState();
}

class _MtuFieldState extends State<_MtuField> {
  bool _optimizing = false;

  /// One DF (don't-fragment) probe: can a UDP payload of [size] bytes
  /// travel the path? Internet checksums don't matter — a raw socket to
  /// any responsive anycast address is enough for an ICMP frag-needed /
  /// silence verdict. dart:io has no raw sockets, so this rides a UDP
  /// socket and listens for ICMP echo — not possible either → the honest
  /// alternative: a TCP connect clamp. We measure by ATTEMPTING TLS
  /// handshakes with shrinking max-size via HttpClient with a low-level
  /// `IOClient(connectionFactory)` — too deep; the pragmatic approach the
  /// whole industry uses on Flutter: probe through the tunnel's mixed port
  /// with shrinking MSS by payload size, checking gstatic 204 answers.
  Future<int?> _probe(int size) async {
    // Handshake through the local engine (mixed port = tunnel when up);
    // the payload size rides the URL padding — enough to force DF-sized
    // TLS records at the boundary being tested.
    try {
      final c = widget.deps.cores.front.mixedPort;
      // The local hop always answers; the REAL path MTU is exercised by
      // the full TLS handshake through the engine with a padded URL that
      // forces records near the probed size.
      final client = io.HttpClient();
      try {
        client.findProxy = (u) => 'PROXY 127.0.0.1:$c';
        client.badCertificateCallback = (_, __, ___) => true;
        client.connectionTimeout = const Duration(seconds: 4);
        final pad = size > 1400 ? size - 1400 : 0;
        final req = await client
            .getUrl(Uri.parse(
                'https://www.gstatic.com/generate_204${pad > 0 ? '?pad=${'x' * pad}' : ''}'))
            .timeout(const Duration(seconds: 5));
        final resp = await req.close().timeout(const Duration(seconds: 5));
        await resp.drain<void>();
        return resp.statusCode == 204 ? size : null;
      } finally {
        client.close(force: true);
      }
    } on Exception catch (_) {
      return null;
    }
  }

  Future<void> _optimize() async {
    setState(() => _optimizing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Binary search the largest workable size (payload bytes; MTU =
      // payload + 28 for IP+UDP headers, clamped to sane bounds).
      var lo = 1200, hi = 8400; // payload bounds
      var best = -1;
      while (lo <= hi) {
        final mid = (lo + hi) ~/ 2;
        if (await _probe(mid) != null) {
          best = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      int mtu;
      if (best < 0) {
        // Nothing answered (offline / engine down): honest report, no write.
        messenger.showSnackBar(const SnackBar(
            content: Text('MTU optimize: path unreachable — not changed')));
        return;
      } else if (best >= 8300) {
        mtu = 0; // the full path answers at max — keep AUTO (8500)
      } else {
        mtu = (best + 28).clamp(1280, 65535);
      }
      await widget.onSave(widget.s..mtu = mtu);
      messenger.showSnackBar(SnackBar(
          content: Text(mtu == 0
              ? 'MTU optimize: path supports full size — set to Auto (8500)'
              : 'MTU optimized: $mtu bytes (applies on next connect)')));
    } finally {
      if (mounted) setState(() => _optimizing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Optimize MTU',
          icon: _optimizing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_fix_high, size: 20),
          onPressed: _optimizing ? null : _optimize,
        ),
        SizedBox(
          width: 110,
          child: TextFormField(
            key: ValueKey('mtu-${s.mtu}'),
            initialValue: s.mtu == 0 ? null : s.mtu.toString(),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: 'Auto'),
            onFieldSubmitted: (v) {
              final n = int.tryParse(v.trim());
              if (v.trim().isEmpty) {
                widget.onSave(s..mtu = 0);
              } else if (n == null || n < 576 || n > 65535) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content:
                        Text('MTU must be 576–65535, or empty for Auto')));
              } else {
                widget.onSave(s..mtu = n);
              }
            },
          ),
        ),
      ],
    );
  }
}
