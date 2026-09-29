import 'dart:async';
import 'dart:io';
import 'dart:math' show sqrt;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;
import '../../application/dependencies.dart';
import '../../application/node_usage.dart' show fmtBytes;
import '../../core/android_node_support.dart';
import '../../core/logger.dart';
import '../../core/node_core_choice.dart';
import '../../domain/entities/health.dart';
import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/warp_chain_card.dart';
import 'node_editor_screen.dart';
import 'subscriptions_screen.dart';

/// Node list (§31): information-dense, filterable, sortable.
class NodesScreen extends StatefulWidget {
  const NodesScreen({super.key, required this.deps});

  final AppDependencies deps;

  @override
  State<NodesScreen> createState() => _NodesScreenState();
}

enum _NodeFilter { all, healthy, fast }

class _NodesScreenState extends State<NodesScreen> {
  String _query = '';
  _NodeFilter _filter = _NodeFilter.all;
  /// v0.4.3: Subscriptions merged into this tab — 0 = nodes, 1 = subs.
  int _section = 0;
  /// v0.5.2 §user: per-subscription sub-tab filter (null = All).
  String? _subFilterId;
  String _sortBy = 'latency';
  List<ProxyProfile> _profiles = const [];
  String? _selectedId;
  StreamSubscription<void>? _selectionSub;
  StreamSubscription<HealthRecord>? _healthSub;
  StreamSubscription<void>? _smartSub;
  bool _healthCoalesce = false;

  @override
  void initState() {
    super.initState();
    _profiles = widget.deps.profiles.all;
    widget.deps.profiles.changes.listen((p) {
      if (mounted) setState(() => _profiles = p);
    });
    // v0.4.9 §user-fix (ping column never moved): Smart Switch was the ONLY
    // listener of the scheduler's results — background sweeps and the
    // active-node monitor recorded into HealthStore but this list never
    // repainted, so latency stayed stale until a manual re-test. Subscribe
    // → repaint on every record.
    // v0.5.0 §lag: coalesce the repaints. A 40-node batch sweep fires 40
    // records within a second — each one rebuilt+resorted the whole list.
    // One frame-boundary repaint per burst is visually identical.
    _healthCoalesce = false;
    _healthSub = widget.deps.scheduler.results.listen((_) {
      if (!mounted || _healthCoalesce) return;
      _healthCoalesce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _healthCoalesce = false;
        if (mounted) setState(() {});
      });
    });
    // v0.5.2 §user-fix ("پینگ‌ها بار اول نمیاد"): Smart Switch's sweeps,
    // its PRE-CONNECT ladder and the active rechecks write into HealthStore
    // DIRECTLY (they never pass scheduler.results). Subscribe to the
    // ladder's own measured stream — the first sweep's REAL pings now
    // repaint this list immediately.
    _smartSub = widget.deps.vpnSession.smartMeasured.listen((_) {
      if (!mounted || _healthCoalesce) return;
      _healthCoalesce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _healthCoalesce = false;
        if (mounted) setState(() {});
      });
    });
    // v0.4.1 §5: reflect the VPN session's explicit selection immediately —
    // the tapped node is shown as chosen on the dashboard BEFORE any connect.
    _selectedId = widget.deps.vpnSession.selectedNode?.id;
    _selectionSub =
        widget.deps.vpnSession.selectionChanged.listen((_) {
      // v0.4.4 fix: keep the local highlight in sync with the SESSION's
      // selection (device bug: the checkmark only appeared after leaving
      // and re-entering the tab because this stream never updated
      // _selectedId — only initState read it once).
      if (!mounted) return;
      setState(() => _selectedId = widget.deps.vpnSession.selectedNode?.id);
    });
  }

  @override
  void dispose() {
    _selectionSub?.cancel();
    _healthSub?.cancel();
    _smartSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);
    // v0.5.2 §user — per-subscription SUB-TABS: the segmented bar gains a
    // chip per subscription (its name) beside All; the list filters to that
    // subscription's nodes only.
    List<ProxyProfile> nodes;
    if (_section == 1) {
      nodes = _filterSort(_profiles);
    } else if (_subFilterId != null) {
      nodes = _filterSort(
          _profiles.where((p) => p.subscriptionId == _subFilterId).toList());
    } else {
      nodes = _filterSort(_profiles);
    }
    final fa = Localizations.localeOf(context).languageCode == 'fa';

    // v0.4.3: one tab instead of two — the WARP chain card rides at the top
    // of the node list (it modifies nodes), subscriptions live in a segment.
    if (_section == 1) {
      return Column(
        children: [
          _sectionBar(c, fa),
          Expanded(
            child: SubscriptionsScreen(
                deps: widget.deps, embedded: true),
          ),
        ],
      );
    }

    return Column(
      children: [
        _sectionBar(c, fa),
        // v0.4.7 §user: the SMART SWITCH card — a virtual "node" the user
        // taps to hand node choice to the app (default mode). Highlighted
        // while active; a tap on any concrete node de-activates it.
        _SmartSwitchCard(
          active: widget.deps.vpnSession.isSmartSwitchActive,
          onTap: () {
            // v0.4.8 §user: a REAL toggle — the Switch now turns the mode
            // OFF as well as ON (the old handler only ever re-enabled it,
            // so a node that was ON could never be switched off from the
            // card; device report "اسمارت سوییچ روش می‌زنی خاموش نمی‌شه").
            if (widget.deps.vpnSession.isSmartSwitchActive) {
              widget.deps.vpnSession.disableSmartSwitch();
            } else {
              widget.deps.vpnSession.enableSmartSwitch();
              setState(() => _selectedId = null);
            }
          },
        ),
        // v0.4.9 §user: the WARP card eats the panel — collapsed by default
        // (one-row header), expands only on tap so the node list gets its
        // space back.
        _CollapsibleWarpCard(deps: widget.deps),
        // v0.4.7 §brand (sheet v2): rounded search + pill filter chips + a
        // compact action row — the mockup's Nodes panel anatomy.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: c.border),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Icon(Icons.search, size: 20, color: c.textSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          onChanged: (v) => setState(() => _query = v),
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: c.textPrimary),
                          decoration: InputDecoration(
                            hintText: l.search,
                            hintStyle: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: c.textMuted),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Compact ghost actions kept from the functional layout —
              // clipboard / import / add / test-all.
              // v0.5.2 §user — IMPORT FROM CLIPBOARD: one tap imports the
              // clipboard's share links (no dialog, no typing).
              _GhostIconButton(
                  icon: Icons.content_paste_rounded,
                  tooltip: l.fromClipboard,
                  onTap: () => _importFromClipboard(context)),
              _GhostIconButton(
                  icon: Icons.download_rounded,
                  tooltip: l.import,
                  onTap: () => _showImportDialog(context)),
              const SizedBox(width: 6),
              _GhostIconButton(
                  icon: Icons.add,
                  tooltip: 'Add node manually',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          NodeEditorScreen(deps: widget.deps)))),
              const SizedBox(width: 6),
              _GhostIconButton(
                  icon: Icons.speed,
                  tooltip: l.testAllNodes,
                  busy: _sweeping,
                  onTap: _sweeping ? null : () => _runRealUrlSweep()),
            ],
          ),
        ),
        // Pill filter chips (sheet style): selected = lightened surface +
        // Accent text; idle = transparent + TextDim + hairline border.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Row(
            children: [
              for (final f in const [
                (_NodeFilter.all, 'filterAll'),
                (_NodeFilter.healthy, 'filterHealthy'),
                (_NodeFilter.fast, 'filterFast'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _filter = f.$1),
                    child: Container(
                      height: 32,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: _filter == f.$1
                            ? c.surfaceElevated
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color:
                              _filter == f.$1 ? c.accentSoft : c.border,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _filterLabel(l, f.$2),
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(
                              color: _filter == f.$1
                                  ? c.textPrimary
                                  : c.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _sortBy,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: c.textSecondary),
                  dropdownColor: c.surface,
                  icon: Icon(Icons.expand_more,
                      size: 18, color: c.textSecondary),
                  items: [
                    DropdownMenuItem(
                        value: 'latency', child: Text(l.sortByLatency)),
                    DropdownMenuItem(value: 'name', child: Text(l.sortByName)),
                    DropdownMenuItem(
                        value: 'stability', child: Text(l.sortByStability)),
                  ],
                  onChanged: (v) => setState(() => _sortBy = v ?? 'latency'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: nodes.isEmpty
              ? _EmptyNodes(onImport: () => _showImportDialog(context))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: nodes.length,
                  itemExtent: 72,
                  itemBuilder: (context, i) {
                    final p = nodes[i];
                    final s = widget.deps.healthStore.statsOf(p.id);
                    // v0.5.2 §user: lifetime usage attributed to this node.
                    final usage = widget.deps.nodeUsage.of(p.id);
                    return NodeTile(
                      profile: p,
                      stats: s,
                      selected: _selectedId == p.id,
                      isAndroid: Platform.isAndroid,
                      usageUp: usage.up,
                      usageDown: usage.down,
                      onConnect: () => _onNodeTap(context, p),
                      onCoreTap: () => _showCorePicker(context, p),
                      onEdit: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => NodeEditorScreen(
                                deps: widget.deps, profile: p)));
                        if (mounted) setState(() {});
                      },
                      onDelete: () => _confirmDelete(context, p),
                    );
                  },
                ),
        ),
        Text(
          '${nodes.length} ${l.nodesCount.toLowerCase()}',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: c.textMuted),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _sectionBar(ThemeExt c, bool fa) {
    // v0.5.2 §user — sub-tabs: All · <sub names…> under the Nodes segment.
    final subs = widget.deps.subscriptions.all;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<int>(
            segments: [
              ButtonSegment(
                  value: 0,
                  icon: const Icon(Icons.hub_outlined, size: 18),
                  label: Text(fa ? 'نودها' : 'Nodes')),
              ButtonSegment(
                  value: 1,
                  icon: const Icon(Icons.rss_feed_outlined, size: 18),
                  label: Text(fa ? 'اشتراک‌ها' : 'Subscriptions')),
            ],
            selected: {_section},
            onSelectionChanged: (v) => setState(() => _section = v.first),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          if (_section == 0 && subs.isNotEmpty) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _subChip(
                    label: fa ? 'همه' : 'All',
                    selected: _subFilterId == null,
                    onTap: () => setState(() => _subFilterId = null),
                  ),
                  for (final s in subs)
                    _subChip(
                      label: s.name.trim().isEmpty
                          ? (fa ? 'ساب ${s.id.substring(0, 4)}' : 'Sub ${s.id.substring(0, 4)}')
                          : s.name,
                      selected: _subFilterId == s.id,
                      onTap: () => setState(() => _subFilterId = s.id),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _subChip(
      {required String label, required bool selected, required VoidCallback onTap}) {
    final c = ThemeExt.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? c.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected ? c.accent : c.border.withValues(alpha: 0.7)),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected ? c.accent : c.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
          ),
        ),
      ),
    );
  }

  /// v0.4.9 §user: REAL URL sweep — every runnable node is tested
  /// END-TO-END (HTTP GET through the node's live outbound via the running
  /// engine), NOT with a bare TCP ping to the node IP. An Iran-internal
  /// tunnel IP answers TCP in 50 ms and still cannot fetch anything —
  /// exactly the "ping says alive, tunnel dead" bug. Results land in the
  /// shared HealthStore so the latency column, filters, sorting, Smart
  /// Switch and the fragment ladder all read the SAME real numbers.
  bool _sweeping = false;

  Future<void> _runRealUrlSweep() async {
    if (_sweeping) return;
    final runnable = widget.deps.profiles.all
        .where((p) =>
            p.enabled &&
            (!Platform.isAndroid || AndroidNodeSupport.isRunnable(p)))
        .toList();
    if (runnable.isEmpty) return;
    _sweeping = true;
    if (mounted) setState(() {});
    // v0.5.0 §perf-fix: the WHOLE runnable pool in ONE testBatch call. The
    // old chunk-of-6 loop re-entered the transient probe engine per chunk:
    // every chunk with a new node id REBUILT the Box (probeStart is a full
    // restart) and killed the in-flight measurements — sweeps took forever
    // and read suspicious numbers. One boot + parallel delay tests now;
    // 100+ nodes stay polite through the engine's own concurrency.
    final results = await widget.deps.realDelay.testBatch(runnable);
    final now = DateTime.now();
    for (final p in runnable) {
      final r = results[p.id];
      if (r == null || r.errorKind == 'engine-off') continue;
      widget.deps.healthStore.record(HealthRecord(
        profileId: p.id,
        at: now,
        ok: r.ok,
        latencyMs: r.latencyMs,
        errorKind: r.errorKind,
      ));
    }
    _sweeping = false;
    if (mounted) setState(() {});
  }

  List<ProxyProfile> _filterSort(List<ProxyProfile> all) {
    return all.where((p) {
      if (_query.isNotEmpty &&
          !p.name.toLowerCase().contains(_query.toLowerCase()) &&
          !p.server.toLowerCase().contains(_query.toLowerCase())) {
        return false;
      }
      final s = widget.deps.healthStore.statsOf(p.id);
      return switch (_filter) {
        _NodeFilter.all => true,
        _NodeFilter.healthy => s?.state == NodeHealth.healthy,
        _NodeFilter.fast => (s?.lastLatencyMs ?? 9999) < 300,
      };
    }).toList()
      ..sort((a, b) {
        final sa = widget.deps.healthStore.statsOf(a.id);
        final sb = widget.deps.healthStore.statsOf(b.id);
        switch (_sortBy) {
          case 'name':
            return a.name.compareTo(b.name);
          case 'latency':
            return (sa?.lastLatencyMs ?? 99999)
                .compareTo(sb?.lastLatencyMs ?? 99999);
          default:
            return (sb?.successRate ?? 0).compareTo(sa?.successRate ?? 0);
        }
      });
  }

  String _filterLabel(AppLocalizations l, String key) => switch (key) {
        'filterAll' => l.filterAll,
        'filterHealthy' => l.filterHealthy,
        _ => l.filterFast,
      };

  /// v0.4.1 node-selection: a tap is an EXPLICIT selection. On Android the
  /// node is recorded in the VpnSession first (dashboard reflects it
  /// immediately via [selectionChanged]), then the connect attempt starts.
  /// Non-runnable nodes are never silently skipped — they connect only via
  /// the explicit Connect ring (auto-pick), and the reason is shown inline.
  /// v0.4.7 §user — tapping a node ONLY SELECTS it (sheet v2 behavior):
  /// the dashboard's power button is the single connect control. Before
  /// this, a node tap auto-connected, so the user landed on the dashboard
  /// with the pill still reading CONNECT while the tunnel was already up —
  /// two competing connect controls, both confusing. Selection is instant
  /// and silent; connecting happens only via the dashboard pill.
  void _onNodeTap(BuildContext context, ProxyProfile p) {
    final vpn = widget.deps.vpnSession;
    final runnable = !Platform.isAndroid || AndroidNodeSupport.isRunnable(p);
    if (Platform.isAndroid) {
      if (runnable) vpn.selectNode(p);
      setState(() => _selectedId = runnable ? p.id : _selectedId);
    } else {
      // Desktop keeps an explicit selection too — no implicit switch.
      setState(() => _selectedId = p.id);
    }
    if (!runnable) {
      if (Platform.isAndroid && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${p.name}: ${AndroidNodeSupport.notRunnableReason(p) ?? 'not runnable on Android'} — cannot be tested on this device'),
          duration: const Duration(seconds: 4),
        ));
      }
      return;
    }
    if (!Platform.isAndroid) {
      // Desktop: selection alone never redials either — the dashboard
      // connect/smart-connect owns the tunnel lifecycle there as well.
      Logger.instance.info('node-tap',
          'selected ${p.name} (id=${p.id}) — connect via dashboard');
    }
  }

  /// v0.4.9 §user: per-node delete with confirmation. Also un-selects the
  /// node if it was the active selection so the dashboard never points at a
  /// ghost.
  Future<void> _confirmDelete(BuildContext context, ProxyProfile p) async {
    final l = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.delete),
        content: Text('${p.name} — ${l.delete}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel)),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.delete)),
        ],
      ),
    );
    if (ok != true) return;
    await widget.deps.profiles.remove(p.id);
    if (_selectedId == p.id) _selectedId = null;
    if (mounted) setState(() {});
  }

  /// v0.4.1 per-node core picker: Auto (default) / sing-box / AWG / Xray.
  /// Persisted via [ProxyProfile.userPinnedCore] so it survives restarts and
  /// drives CoreDetector.resolve() on every connect. Xray on Android is
  /// honest per the RUNTIME handshake: the exec'd binary ships in the APK
  /// and the :xray process reports it at boot — selectable when loaded,
  /// disabled with the reason when not (v0.4.9 §user fix).
  Future<void> _showCorePicker(BuildContext context, ProxyProfile p) async {
    final onAndroid = Platform.isAndroid;
    final xrayWarn = NodeCoreChoice.xrayWarning(p, onAndroid: onAndroid);
    // v0.4.9 §user: capability-aware picker — a core that CANNOT run the
    // node is disabled with the honest reason, per node type:
    //   * xhttp/mKCP (Xray-only transports): sing-box AND AWG disabled.
    //   * AWG nodes (amnezia params): sing-box AND Xray disabled.
    final isXrayOnly = p.transport == Transport.xhttp ||
        p.rawParams['type'] == 'mkcp' ||
        p.rawParams['type'] == 'kcp';
    final isAwgNode = p.amnezia?.isNotEmpty == true;
    final singBoxReason = isXrayOnly
        ? 'sing-box cannot run Xray-only transports (xhttp/mKCP)'
        : (isAwgNode
            ? 'plain sing-box strips the AWG obfuscation fields — the handshake degrades to WireGuard and dies'
            : null);
    final awgReason = !isAwgNode && p.protocol != ProxyProtocol.wireguard
        ? 'only WireGuard-family nodes carry AWG params'
        : (isXrayOnly ? 'xhttp/mKCP cannot run through a WireGuard-family engine' : null);
    final xrayCapable = xrayWarn == null || !onAndroid;
    final picked = await showModalBottomSheet<CoreKind>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(p.name,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            ListTile(
              leading: Icon(p.userPinnedCore == null ||
                      p.userPinnedCore == CoreKind.unknown
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: const Text('Auto (recommended)'),
              subtitle: Text(
                  'Detect the best engine for this node automatically'
                  '${p.amnezia?.isNotEmpty == true ? ' — AmneziaWG params detected, runs on the AWG engine' : ''}'),
              onTap: () => Navigator.pop(ctx, CoreKind.unknown),
            ),
            ListTile(
              enabled: singBoxReason == null,
              leading: Icon(p.userPinnedCore == CoreKind.singbox
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: const Text('sing-box'),
              subtitle: Text(singBoxReason ??
                  (onAndroid
                      ? 'The on-device engine — runs this node in-app'
                      : 'Force the sing-box core')),
              onTap:
                  singBoxReason != null ? null : () => Navigator.pop(ctx, CoreKind.singbox),
            ),
            // v0.4.9 §user: AmneziaWG pin — meaningful for WireGuard-family
            // nodes carrying AWG params (the forked libbox executes them).
            ListTile(
              enabled: awgReason == null,
              leading: Icon(p.userPinnedCore == CoreKind.amneziaWg
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: const Text('AmneziaWG'),
              subtitle: Text(awgReason ??
                  (isAwgNode
                      ? 'Run the AWG-obfuscated handshake (forked engine)'
                      : 'WireGuard node — set AWG params first (WARP card or an imported .conf)')),
              onTap:
                  awgReason != null ? null : () => Navigator.pop(ctx, CoreKind.amneziaWg),
            ),
            ListTile(
              enabled: xrayCapable && !isAwgNode,
              leading: Icon(p.userPinnedCore == CoreKind.xray
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: const Text('Xray'),
              subtitle: Text(isAwgNode
                  ? 'Xray cannot execute a WireGuard-family handshake'
                  : (xrayWarn ??
                      (onAndroid
                          ? 'Runs this node through the Xray core'
                          : 'Force the Xray core (separate process)')),
                  style: (xrayWarn != null || isAwgNode)
                      ? TextStyle(
                          color: Theme.of(ctx).colorScheme.error,
                          fontSize: 12)
                      : null),
              onTap: (xrayWarn != null && onAndroid) || isAwgNode
                  ? null
                  : () => Navigator.pop(ctx, CoreKind.xray),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final updated = p.copyWith(userPinnedCore: picked);
    await widget.deps.profiles.update(updated);
    setState(() {});
    if (context.mounted) {
      final label = NodeCoreChoice.labelFor(updated, onAndroid: onAndroid);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${p.name}: core set to $label'),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  /// v0.5.2 §user — IMPORT FROM CLIPBOARD: reads the clipboard and imports
  /// whatever it recognizes (share links / base64 / YAML / JSON) as nodes.
  /// One tap — the manual paste dialog stays for editing before import.
  Future<void> _importFromClipboard(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    String text = '';
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    } catch (_) {}
    text = text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.importFailed)));
      return;
    }
    try {
      final result = widget.deps.importer.import(text);
      await widget.deps.profiles.upsertMany(result.profiles);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.importSuccess(result.profiles.length))));
      }
    } on AppError catch (e) {
      Logger.instance.error('clipboard-import', e.userMessage);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${l.importFailed}: ${e.userMessage}')));
      }
    }
  }

  Future<void> _showImportDialog(BuildContext context) async {
    final controller = TextEditingController();
    final l = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.import),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: 'URI list · base64 · Clash YAML · JSON · .conf',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.import),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final text = controller.text.trim();
    if (text.isEmpty) return;
    try {
      final result = widget.deps.importer.import(text);
      await widget.deps.profiles.upsertMany(result.profiles);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.importSuccess(result.profiles.length))),
        );
      }
    } on AppError catch (e) {
      Logger.instance.error('import', e.userMessage);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l.importFailed}: ${e.userMessage}')),
        );
      }
    }
  }
}

class _EmptyNodes extends StatelessWidget {
  const _EmptyNodes({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.hub_outlined, size: 48, color: c.textMuted),
          const SizedBox(height: 12),
          Text(l.noNodes, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              l.noNodesHint,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: c.textSecondary),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.download_rounded),
            label: Text(l.import),
          ),
        ],
      ),
    );
  }
}

class NodeTile extends StatelessWidget {
  const NodeTile({
    super.key,
    required this.profile,
    required this.stats,
    required this.onConnect,
    required this.onCoreTap,
    this.onEdit,
    this.onDelete,
    this.selected = false,
    this.isAndroid = false,
    this.usageUp,
    this.usageDown,
  });

  final ProxyProfile profile;
  final NodeHealthStats? stats;
  final VoidCallback onConnect;
  /// v0.4.3: long-press (or menu) → edit this node's fields in place.
  final VoidCallback? onEdit;
  /// v0.4.9 §user: per-node delete (confirm dialog lives in the screen).
  final VoidCallback? onDelete;
  /// v0.4.1: tap on the core badge opens the per-node core picker
  /// (Auto / sing-box / AWG / Xray).
  final VoidCallback onCoreTap;
  final bool selected;
  final bool isAndroid;

  /// v0.5.2 §user — lifetime upload/download attributed to THIS node
  /// (delta accounting in NodeUsage). Null → hidden (no accounting).
  final int? usageUp;
  final int? usageDown;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final l = AppLocalizations.of(context)!;
    final lat = stats?.lastLatencyMs;
    final latColor = lat == null
        ? c.textMuted
        : lat < 300
            ? c.success
            : lat < 900
                ? c.warning
                : c.error;
    final healthColor = switch (stats?.state) {
      NodeHealth.healthy => c.success,
      NodeHealth.degraded => c.warning,
      NodeHealth.checking => c.info,
      NodeHealth.timeout ||
      NodeHealth.offline ||
      NodeHealth.blocked ||
      NodeHealth.coreError ||
      NodeHealth.configError =>
        c.error,
      _ => c.textMuted,
    };
    final healthLabel = switch (stats?.state) {
      NodeHealth.healthy => l.healthHealthy,
      NodeHealth.degraded => l.healthDegraded,
      NodeHealth.checking => l.healthChecking,
      NodeHealth.timeout => l.healthTimeout,
      NodeHealth.offline => l.healthOffline,
      NodeHealth.blocked => l.healthBlocked,
      NodeHealth.coreError => l.healthCoreError,
      NodeHealth.configError => l.healthConfigError,
      _ => l.healthUnknown,
    };
    // v0.4.1 §31: show WHICH core runs this node on this device. Non-runnable
    // nodes are marked honestly (never silently skipped) and dimmed — a tap
    // explains why instead of attempting a doomed connect.
    final reason = isAndroid ? AndroidNodeSupport.notRunnableReason(profile) : null;
    final runnable = reason == null;
    // v0.4.1 per-node core: the badge reflects the USER's selection
    // (auto/sing-box/Xray) when pinned; otherwise the honest platform label.
    final pinned = profile.userPinnedCore != null &&
        profile.userPinnedCore != CoreKind.unknown;
    final coreLabel = isAndroid
        ? (pinned
            ? NodeCoreChoice.labelFor(profile, onAndroid: true)
            : AndroidNodeSupport.androidCoreLabel(profile))
        : (pinned
            ? NodeCoreChoice.labelFor(profile, onAndroid: false)
            : profile.effectiveCore.name);
    final badgeText = isAndroid
        ? (pinned
            ? NodeCoreChoice.labelFor(profile, onAndroid: true)
            : AndroidNodeSupport.shortBadge(profile))
        : (pinned
            ? NodeCoreChoice.labelFor(profile, onAndroid: false)
            : profile.effectiveCore.name);
    final tileOpacity = runnable ? 1.0 : 0.55;

    // v0.5.0 §user-3: jitter + success rate under the latency — the same
    // composite inputs the Smart Switch ladder ranks on (latency on top,
    // stability beneath). Formatters live in [nodeMetricSubline] for tests.
    final statsSubLine = nodeMetricSubline(
      jitterMs: stats?.jitterMs,
      successRate: stats?.successRate,
    );

    return Opacity(
      opacity: tileOpacity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Material(
          color: selected ? c.accentSoft : c.surface,
          borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
          child: InkWell(
            borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
            onTap: onConnect,
            onLongPress: onEdit,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
                border: Border.all(
                  color: selected ? c.accent : Colors.transparent,
                  width: 1.5,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  // v0.4.4 mockup: green rounded mark per node row.
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: c.success.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: c.success.withValues(alpha: 0.4)),
                    ),
                    child: Icon(Icons.bolt, size: 18, color: c.success),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                profile.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                              ),
                            ),
                            if (selected) ...[
                              const SizedBox(width: 6),
                              Icon(Icons.check_circle,
                                  size: 14, color: c.accent),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          selected
                              ? 'CONNECTED · ${profile.protocol.name} · $coreLabel'
                              : '${l.tapToConnect} · ${profile.protocol.name} · $coreLabel'
                                  '${profile.security != Security.none ? ' · ${profile.security.name}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: selected ? c.accent : c.textMuted),
                        ),
                        // v0.5.2 §user — USAGE under each node: lifetime
                        // upload + download while THIS node carried traffic.
                        // Hidden when the accounting is unavailable.
                        if (usageUp != null && usageDown != null) ...[
                          const SizedBox(height: 1),
                          Text(
                            '↑ ${fmtBytes(usageUp!)}  ↓ ${fmtBytes(usageDown!)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: c.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: reason ??
                        'Core: $badgeText — tap to choose (Auto / sing-box / Xray)',
                    child: InkWell(
                      onTap: onCoreTap,
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          // v0.4.7 §palette: engine badge = neutral hairline pill
                          // (white ink on elevated surface) — the old purple
                          // `info` fill broke the six-token sheet palette.
                          color: runnable
                              ? c.surfaceElevated
                              : c.warning.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: runnable
                                ? c.border
                                : c.warning.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          badgeText,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: runnable ? c.textPrimary : c.warning,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.5,
                                  ),
                        ),
                      ),
                    ),
                  ),
                  // v0.5.0 §user-3: the metric column grew two lines —
                  // latency (top) + jitter · success rate (bottom). The
                  // Smart Switch now ranks on this same composite, so the
                  // list shows every input the ladder sees.
                  SizedBox(
                    width: 104,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          // v0.4.9 §user: a FAILED real test must be visible —
                          // '—' read as "never tested" and looked broken.
                          lat != null
                              ? '$lat ms'
                              : (stats == null ? '—' : '×'),
                          textAlign: TextAlign.end,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: lat == null && stats != null
                                        ? c.error
                                        : latColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          statsSubLine,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          textAlign: TextAlign.end,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Tooltip(
                    message: healthLabel,
                    child: StatusDot(color: healthColor),
                  ),
                  // v0.4.9 §user: per-node delete — a quiet ghost glyph so
                  // the row anatomy stays clean; confirmation lives in the
                  // screen (never delete on a single accidental tap).
                  if (onDelete != null)
                    Tooltip(
                      message: 'Delete node',
                      child: InkWell(
                        onTap: onDelete,
                        borderRadius: BorderRadius.circular(999),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.delete_outline,
                              size: 16, color: c.textSecondary),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// v0.5.0 §user-3 — the node row's stability subline: `±σ ms · 95% up`.
///
/// [jitterMs] is the VARIANCE (ms²) HealthStore computes over the last ≤5
/// samples — the tile shows its SQUARE ROOT (stdDev, ms) because that is
/// the number a human compares against the latency above it ("±40 ms" is
/// readable, "±1600" is not). Fewer than 2 samples → no jitter yet →
/// jitter is omitted rather than faked as `±0`.
/// [successRate] is the share of OK probes in the recent 20-sample window.
/// Null stats (never tested) → an empty subline; the latency cell above
/// already renders `—`/`×` for that story.
String nodeMetricSubline({int? jitterMs, double? successRate}) {
  final parts = <String>[];
  if (jitterMs != null) {
    final stdDev = sqrt(jitterMs);
    parts.add('±${stdDev >= 10 ? stdDev.round() : stdDev.toStringAsFixed(1)} ms');
  }
  if (successRate != null) {
    parts.add('${(successRate.clamp(0, 1) * 100).round()}% up');
  }
  return parts.join(' · ');
}

/// v0.4.7 §brand (sheet v2) — ghost icon action: 38dp round hit target,
/// TextDim glyph, hairline border on Surface. Replaces the loud
/// filledTonal buttons in the Nodes search row.
class _GhostIconButton extends StatelessWidget {
  const _GhostIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: CircleBorder(
            side: BorderSide(color: c.border, width: 1)),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 38,
            height: 38,
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(icon, size: 19, color: c.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// v0.4.7 §user — the SMART SWITCH virtual-node card (mockup-neutral,
/// sheet-styled): hairline card, auto-awesome glyph, name + one-liner.
/// Active = white ink + elevated fill (the sheet's selected language).
class _SmartSwitchCard extends StatelessWidget {
  const _SmartSwitchCard({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: active ? c.surfaceElevated : c.surface,
        borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
              border: Border.all(color: active ? c.textPrimary : c.border),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome,
                    size: 20,
                    color: active ? c.textPrimary : c.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SMART SWITCH',
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(
                                  color: active
                                      ? c.textPrimary
                                      : c.textSecondary,
                                  letterSpacing: 2,
                                  fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        'Auto-selects the best node and keeps testing — switches on its own',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: active,
                  onChanged: (_) => onTap(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// v0.4.9 §user: the WARP/chain card collapsed by default — a one-row
// header with a chevron; the full card only mounts when opened so the
// node list keeps its vertical space ("کادر کلودفلر خیلی بزرگ شده").
class _CollapsibleWarpCard extends StatefulWidget {
  const _CollapsibleWarpCard({required this.deps});
  final AppDependencies deps;

  @override
  State<_CollapsibleWarpCard> createState() => _CollapsibleWarpCardState();
}

class _CollapsibleWarpCardState extends State<_CollapsibleWarpCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final fa = Localizations.localeOf(context).languageCode == 'fa';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined,
                        size: 18, color: c.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          fa
                              ? 'کلودفلر WARP / زنجیره'
                              : 'Cloudflare WARP / chain',
                          style: TextStyle(color: c.textPrimary, fontSize: 13)),
                    ),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(Icons.expand_more,
                          size: 20, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
                child: WarpChainCard(deps: widget.deps, compact: true),
              ),
          ],
        ),
      ),
    );
  }
}