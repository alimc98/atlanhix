import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../application/dependencies.dart';
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
  String _sortBy = 'latency';
  List<ProxyProfile> _profiles = const [];
  String? _selectedId;
  StreamSubscription<void>? _selectionSub;

  @override
  void initState() {
    super.initState();
    _profiles = widget.deps.profiles.all;
    widget.deps.profiles.changes.listen((p) {
      if (mounted) setState(() => _profiles = p);
    });
    // v0.4.1 §5: reflect the VPN session's explicit selection immediately —
    // the tapped node is shown as chosen on the dashboard BEFORE any connect.
    _selectedId = widget.deps.vpnSession.selectedNode?.id;
    _selectionSub =
        widget.deps.vpnSession.selectionChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _selectionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);
    final nodes = _filterSort(_profiles);
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
        WarpChainCard(deps: widget.deps),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: l.search,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: l.import,
                onPressed: () => _showImportDialog(context),
                icon: const Icon(Icons.download_rounded),
              ),
              // v0.4.3: manual node creation (pick protocol, fill fields).
              IconButton.filledTonal(
                tooltip: 'Add node manually',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => NodeEditorScreen(deps: widget.deps))),
                icon: const Icon(Icons.add),
              ),
              IconButton.filledTonal(
                tooltip: l.testAllNodes,
                onPressed: () {
                  widget.deps.scheduler
                      .updateProfiles(widget.deps.profiles.all);
                  widget.deps.scheduler.start();
                  widget.deps.scheduler.enqueueSweep();
                },
                icon: const Icon(Icons.speed),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              for (final f in const [
                (_NodeFilter.all, 'filterAll'),
                (_NodeFilter.healthy, 'filterHealthy'),
                (_NodeFilter.fast, 'filterFast'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_filterLabel(l, f.$2)),
                    selected: _filter == f.$1,
                    onSelected: (_) => setState(() => _filter = f.$1),
                  ),
                ),
              const Spacer(),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _sortBy,
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
                    return _NodeTile(
                      profile: p,
                      stats: s,
                      selected: _selectedId == p.id,
                      isAndroid: Platform.isAndroid,
                      onConnect: () => _onNodeTap(context, p),
                      onCoreTap: () => _showCorePicker(context, p),
                      onEdit: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => NodeEditorScreen(
                                deps: widget.deps, profile: p)));
                        if (mounted) setState(() {});
                      },
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: SegmentedButton<int>(
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
    );
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
  Future<void> _onNodeTap(BuildContext context, ProxyProfile p) async {
    final vpn = widget.deps.vpnSession;
    final runnable = !Platform.isAndroid || AndroidNodeSupport.isRunnable(p);
    if (Platform.isAndroid) {
      if (runnable) vpn.selectNode(p);
      setState(() {});
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
    if (Platform.isAndroid) {
      final ok = await vpn.connect(node: p);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Connection failed'
                '${AndroidNodeSupport.connectErrorHint(vpn.lastError) ?? ''}')));
      }
      return;
    }
    try {
      await widget.deps.connection.switchTo(p);
    } on AppError catch (e) {
      Logger.instance.error('node-tap', e.userMessage);
    }
  }

  /// v0.4.1 per-node core picker: Auto (default) / sing-box / Xray.
  /// Persisted via [ProxyProfile.userPinnedCore] so it survives restarts and
  /// drives CoreDetector.resolve() on every connect. Xray on Android is
  /// selectable but honest: it explains the platform limit (no exec() of
  /// downloaded binaries on Android ≥10; no mobile export in Xray) and
  /// connects will fail fast with CORE_NOT_RUNNABLE_ON_ANDROID rather than
  /// silently swapping cores.
  Future<void> _showCorePicker(BuildContext context, ProxyProfile p) async {
    final onAndroid = Platform.isAndroid;
    final xrayWarn = NodeCoreChoice.xrayWarning(p, onAndroid: onAndroid);
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
              subtitle: const Text(
                  'Detect the best engine for this node automatically'),
              onTap: () => Navigator.pop(ctx, CoreKind.unknown),
            ),
            ListTile(
              leading: Icon(p.userPinnedCore == CoreKind.singbox
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: const Text('sing-box'),
              subtitle: Text(onAndroid
                  ? 'The on-device engine — runs this node in-app'
                  : 'Force the sing-box core'),
              onTap: () => Navigator.pop(ctx, CoreKind.singbox),
            ),
            ListTile(
              enabled: xrayWarn == null || !onAndroid,
              leading: Icon(p.userPinnedCore == CoreKind.xray
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: const Text('Xray'),
              subtitle: Text(xrayWarn ??
                  (onAndroid
                      ? 'Runs this node through the Xray core'
                      : 'Force the Xray core (separate process)'),
                  style: xrayWarn != null
                      ? TextStyle(
                          color: Theme.of(ctx).colorScheme.error,
                          fontSize: 12)
                      : null),
              onTap: xrayWarn != null && onAndroid
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

class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.profile,
    required this.stats,
    required this.onConnect,
    required this.onCoreTap,
    this.onEdit,
    this.selected = false,
    this.isAndroid = false,
  });

  final ProxyProfile profile;
  final NodeHealthStats? stats;
  final VoidCallback onConnect;
  /// v0.4.3: long-press (or menu) → edit this node's fields in place.
  final VoidCallback? onEdit;
  /// v0.4.1: tap on the core badge opens the per-node core picker
  /// (Auto / sing-box / Xray).
  final VoidCallback onCoreTap;
  final bool selected;
  final bool isAndroid;

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
                          '${profile.protocol.name} · $coreLabel'
                          '${profile.security != Security.none ? ' · ${profile.security.name}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: c.textMuted),
                        ),
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
                          color: runnable
                              ? c.info.withValues(alpha: 0.12)
                              : c.warning.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: runnable
                                ? c.info.withValues(alpha: 0.4)
                                : c.warning.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          badgeText,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: runnable ? c.info : c.warning,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: Text(
                      lat == null ? '—' : '$lat ms',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: latColor,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Tooltip(
                    message: healthLabel,
                    child: StatusDot(color: healthColor),
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
