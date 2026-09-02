import 'package:flutter/material.dart';
import '../../application/dependencies.dart';
import '../../core/logger.dart';
import '../../domain/entities/health.dart';
import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';
import '../widgets/common_widgets.dart';

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
  String _sortBy = 'latency';
  List<ProxyProfile> _profiles = const [];

  @override
  void initState() {
    super.initState();
    _profiles = widget.deps.profiles.all;
    widget.deps.profiles.changes.listen((p) {
      if (mounted) setState(() => _profiles = p);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);
    final nodes = _filterSort(_profiles);

    return Column(
      children: [
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
                      onConnect: () => widget.deps.connection.switchTo(p),
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
  });

  final ProxyProfile profile;
  final NodeHealthStats? stats;
  final VoidCallback onConnect;

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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
        child: InkWell(
          borderRadius: BorderRadius.circular(NexusSpacing.radiusInput),
          onTap: onConnect,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${profile.protocol.name} · ${profile.effectiveCore.name}'
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
                Text(
                  lat == null ? '—' : '$lat ms',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: latColor,
                        fontWeight: FontWeight.w600,
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
    );
  }
}
