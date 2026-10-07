import 'package:flutter/material.dart';

import '../../platform/android_vpn.dart';
import '../../settings/routing_settings.dart';

/// v0.4.1 §11/§12/§15 — installed-application routing picker.
///
/// Lists REAL installed apps from PackageManager (via the platform channel),
/// cached once per screen open. Each app gets DEFAULT / PROXY / DIRECT.
/// Semantics (see RoutingSettings.toAndroidAppLists):
///   * PROXY list non-empty  → allow-list mode: ONLY proxy apps ride the VPN
///   * otherwise             → exclude-list mode: DIRECT apps bypass the VPN
class AppsRoutingScreen extends StatefulWidget {
  const AppsRoutingScreen({
    super.key,
    required this.controller,
    required this.routingRepo,
    required this.routing,
    required this.onChanged,
  });

  final AndroidVpnController controller;
  final RoutingSettingsRepository routingRepo;
  final RoutingSettings routing;
  final VoidCallback onChanged;

  @override
  State<AppsRoutingScreen> createState() => _AppsRoutingScreenState();
}

/// First grapheme of an app label, uppercased — or '?' when the label is
/// null/empty. Never throws: `''.characters.first` would raise RangeError.
String _avatarInitial(String? name) {
  final trimmed = (name ?? '').trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.characters.first.toUpperCase();
}

class _AppsRoutingScreenState extends State<AppsRoutingScreen> {
  List<Map<String, dynamic>> _apps = [];
  bool _loading = true;
  String _error = '';
  String _query = '';
  bool _showSystem = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final apps = await widget.controller.installedApps();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loading = false;
      if (apps.isEmpty) _error = 'No apps reported by the platform (is this running on Android?)';
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.routing;
    final filtered = _apps.where((a) {
      final name = (a['name'] as String? ?? '').toLowerCase();
      final pkg = (a['package'] as String? ?? '').toLowerCase();
      if (!_showSystem && a['system'] == true) return false;
      return _query.isEmpty || name.contains(_query) || pkg.contains(_query);
    }).toList()
      ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Application routing'),
        actions: [
          IconButton(
            tooltip: 'Reload app list',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search by app name or package…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Direct: ${r.directApps.length} · Proxy: ${r.proxyApps.length}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: r.directApps.isEmpty && r.proxyApps.isEmpty
                      ? null
                      : () async {
                          await widget.routingRepo
                              .save(r..directApps.clear()..proxyApps.clear());
                          widget.onChanged();
                        },
                  child: const Text('Clear all'),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show system apps'),
                  value: _showSystem,
                  onChanged: (v) => setState(() => _showSystem = v),
                ),
              ],
            ),
          ),
          if (!r.enabled)
            const _ModeBanner(
              text: 'Routing is OFF (opt-in). These app lists are saved but '
                  'NOT applied — enable routing in the Routing screen first.',
            )
          else if (r.proxyApps.isNotEmpty)
            _ModeBanner(
              text: 'Allow-list mode: ONLY Proxy Apps ride the VPN — everyone '
                  'else is routed DIRECT by Android. Clear Proxy Apps to '
                  'return to exclude-list mode.',
              color: Theme.of(context).colorScheme.tertiary,
            )
          else if (r.directApps.isNotEmpty)
            const _ModeBanner(
              text: 'Exclude-list mode: Direct Apps bypass the VPN (Android '
                  'DIRECT); all other apps go through the tunnel.',
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error.isNotEmpty && _apps.isEmpty
                    ? Center(child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error, textAlign: TextAlign.center),
                      ))
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final a = filtered[i];
                          final pkg = a['package'] as String;
                          final state = r.directApps.contains(pkg)
                              ? AppRouteState.direct
                              : r.proxyApps.contains(pkg)
                                  ? AppRouteState.proxy
                                  : AppRouteState.def;
                          return ListTile(
                            leading: CircleAvatar(
                              // v0.5.6 §crash-fix: the `?? '?'` was placed
                              // AFTER `.characters.first`, so it was dead
                              // (`toUpperCase()` is non-nullable) AND an
                              // EMPTY app label threw RangeError inside the
                              // ListView item builder — a blank label is
                              // reachable (managed/OEM work profiles).
                              // The fallback now guards the string BEFORE
                              // indexing it, and an empty one yields '?'.
                              child: Text(_avatarInitial(a['name'] as String?)),
                            ),
                            title: Text(a['name'] as String? ?? pkg),
                            subtitle: Text(
                              pkg,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: SegmentedButton<AppRouteState>(
                              segments: const [
                                ButtonSegment(
                                    value: AppRouteState.def, label: Text('DEF')),
                                ButtonSegment(
                                    value: AppRouteState.proxy,
                                    label: Text('PROXY')),
                                ButtonSegment(
                                    value: AppRouteState.direct,
                                    label: Text('DIRECT')),
                              ],
                              selected: {state},
                              onSelectionChanged: (sel) async {
                                final s = sel.first;
                                r.directApps.remove(pkg);
                                r.proxyApps.remove(pkg);
                                if (s == AppRouteState.direct) {
                                  r.directApps.add(pkg);
                                } else if (s == AppRouteState.proxy) {
                                  r.proxyApps.add(pkg);
                                }
                                await widget.routingRepo.save(r);
                                widget.onChanged();
                                setState(() {});
                              },
                            ),
                          );
                        },
                      ),
          ),
          IranianAppsPresetBar(
            routingRepo: widget.routingRepo,
            routing: widget.routing,
            onChanged: widget.onChanged,
          ),
        ],
      ),
    );
  }
}

enum AppRouteState { def, proxy, direct }

class _ModeBanner extends StatelessWidget {
  const _ModeBanner({required this.text, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: (color ?? Theme.of(context).colorScheme.secondaryContainer)
              .withAlpha(60),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      );
}

/// §14 — Iranian apps preset: seeds suggestions into Direct Apps (data, not
/// hardcode; per-app enable/disable remains the user's).
class IranianAppsPresetBar extends StatelessWidget {
  const IranianAppsPresetBar({
    super.key,
    required this.routingRepo,
    required this.routing,
    required this.onChanged,
  });

  final RoutingSettingsRepository routingRepo;
  final RoutingSettings routing;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Iranian apps preset', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(IranianAppsPreset.sourceNote,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () async {
                    final picked = await showModalBottomSheet<List<String>>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => SizedBox(
                        height: MediaQuery.of(context).size.height * 0.7,
                        child: const _PresetSheet(),
                      ),
                    );
                    if (picked == null || picked.isEmpty) return;
                    // Explicit user action — merge into Direct Apps (no
                    // duplicates). Routing itself stays opt-in (enabled).
                    for (final pkg in picked) {
                      if (!routing.directApps.contains(pkg)) {
                        routing.directApps.add(pkg);
                      }
                    }
                    await routingRepo.save(routing);
                    onChanged();
                  },
                  child: const Text('Review preset'),
                ),
                OutlinedButton.icon(
                  // The DOMAIN side of "Iran rules → DIRECT": user picks it,
                  // never pre-set. Adding *.ir routes all Iranian domains
                  // direct once routing is enabled.
                  icon: const Icon(Icons.public),
                  label: Text(routing.directDomains.any((d) => d == '.ir')
                      ? '.ir → DIRECT (added)'
                      : '.ir domains → DIRECT'),
                  onPressed: routing.directDomains.any((d) => d == '.ir')
                      ? null
                      : () async {
                          routing.directDomains.add('.ir');
                          await routingRepo.save(routing);
                          onChanged();
                        },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Review-and-pick sheet for the Iranian apps preset. NOTHING is applied
/// until the user taps "Add selected (DIRECT)" — per the "no pre-defined
/// roles" rule: the preset is a suggestion, never a pre-set.
class _PresetSheet extends StatefulWidget {
  const _PresetSheet();

  @override
  State<_PresetSheet> createState() => _PresetSheetState();
}

class _PresetSheetState extends State<_PresetSheet> {
  final Set<String> _picked = {};

  @override
  Widget build(BuildContext context) {
    final apps = IranianAppsPreset.packageIds;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Iranian apps preset — ${apps.length} packages\n'
              'Selected: ${_picked.length}. Nothing changes until you tap Add.',
              style: Theme.of(context).textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: apps.length,
              itemBuilder: (context, i) {
                final pkg = apps[i];
                return CheckboxListTile(
                  dense: true,
                  value: _picked.contains(pkg),
                  title: Text(pkg, style: const TextStyle(fontSize: 13)),
                  onChanged: (v) => setState(() {
                    v == true ? _picked.add(pkg) : _picked.remove(pkg);
                  }),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _picked
                      ..clear()
                      ..addAll(apps);
                  }),
                  child: const Text('Select all'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _picked.isEmpty
                      ? null
                      : () {
                          Navigator.of(context).pop(_picked.toList());
                        },
                  child: Text('Add ${_picked.length} as DIRECT'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
