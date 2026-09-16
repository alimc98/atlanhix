import 'package:flutter/material.dart';
import '../../application/dependencies.dart';
import '../../core/fragmentation/fragment_ladder_cache.dart';
import '../../domain/entities/proxy_profile.dart';
import '../../domain/entities/subscription.dart';
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';

class SubscriptionsScreen extends StatelessWidget {
  /// v0.4.3: [embedded] renders without its own Scaffold/FAB so it can live
  /// inside the merged Nodes tab's segment control.
  const SubscriptionsScreen({super.key, required this.deps, this.embedded = false});

  final AppDependencies deps;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);

    return StreamBuilder<List<Subscription>>(
      stream: deps.subscriptions.changes,
      builder: (context, snapshot) {
        final items = snapshot.data ?? deps.subscriptions.all;
        final Widget content = items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.rss_feed, size: 48, color: c.textMuted),
                      const SizedBox(height: 12),
                      Text(l.noSubscription,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          l.noSubscriptionHint,
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: c.textSecondary),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: items.length,
                  itemBuilder: (context, i) =>
                      _SubCard(sub: items[i], deps: deps),
                );
        if (embedded) {
          return Column(
            children: [
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                  child: TextButton.icon(
                    onPressed: () => _addDialog(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l.addSubscription),
                  ),
                ),
              ),
              Expanded(child: content),
            ],
          );
        }
        return Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _addDialog(context),
            icon: const Icon(Icons.add),
            label: Text(l.addSubscription),
          ),
          body: content,
        );
      },
    );
  }

  Future<void> _addDialog(BuildContext context) async {
    final url = TextEditingController();
    final name = TextEditingController();
    final l = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.addSubscription),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: InputDecoration(labelText: l.subscriptionName),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: url,
                decoration: InputDecoration(labelText: l.subscriptionUrl),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.save)),
        ],
      ),
    );
    if (ok == true && url.text.trim().isNotEmpty) {
      await deps.subscriptionService
          .add(url.text.trim(), name: name.text.trim());
    }
  }
}

class _SubCard extends StatelessWidget {
  const _SubCard({required this.sub, required this.deps});

  final Subscription sub;
  final AppDependencies deps;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final l = AppLocalizations.of(context)!;
    final used = sub.info.usedBytes ?? 0;
    final total = sub.info.totalBytes ?? 0;
    final frac = sub.info.usedFraction ?? 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  sub.name.isEmpty ? sub.url : sub.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () => deps.subscriptionService.update(sub),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () async {
                  await deps.subscriptions.remove(sub.id);
                  await deps.profiles
                      .replaceSubscriptionProfiles(sub.id, const <ProxyProfile>[]);
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: frac,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
            backgroundColor: c.surfaceSunken,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _stat(context, l.usedTraffic, _fmt(used)),
              _stat(context, l.remainingTraffic,
                  total > 0 ? _fmt(total - used) : '—'),
              _stat(context, l.totalTraffic, total > 0 ? _fmt(total) : '—'),
              _stat(
                context,
                l.expires,
                sub.info.expireAt == null
                    ? l.neverExpires
                    : '${sub.info.expireAt!.difference(DateTime.now()).inDays}',
              ),
              _stat(context, l.nodesCount, '${sub.nodeCount}'),
            ],
          ),
          // v0.4.6 §user-3: which fragment mode actually WORKS for this
          // subscription — real attempt/win counts per rung inside a 30-day
          // freshness window, gathered from the AUTO ladder's real tunnel
          // probes. Hidden until there is evidence (no fabricated 0/0 rows).
          _FragmentStatsSection(sub: sub, deps: deps),
          if (sub.lastError != null) ...[
            const SizedBox(height: 8),
            Text(
              '${l.updateFailed}: ${sub.lastError}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: c.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: ThemeExt.of(context).textMuted, letterSpacing: 0.7)),
        const SizedBox(height: 2),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }

  static String _fmt(int bytes) {
    if (bytes > 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    if (bytes > 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    if (bytes > 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}

/// v0.4.6 §user-3: per-rung win rates for ONE subscription inside the
/// 30-day freshness window — chips for every rung with evidence (best rung
/// highlighted as the provider's pick), a reset action, and live refresh:
/// the JsonStore change stream fires after every recorded probe, so the
/// chips track reality even while the list sits open.
///
/// Stateful because the reset flow needs a BuildContext independent of the
/// card's build pass (async confirmation dialog → store mutation →
/// stream-driven rebuild).
class _FragmentStatsSection extends StatefulWidget {
  const _FragmentStatsSection({required this.sub, required this.deps});

  final Subscription sub;
  final AppDependencies deps;

  @override
  State<_FragmentStatsSection> createState() => _FragmentStatsSectionState();
}

class _FragmentStatsSectionState extends State<_FragmentStatsSection> {
  bool _resetting = false;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final cache = widget.deps.fragmentLadderCache;
    // Live refresh: JsonStore.changes fires a section key after every
    // recorded probe/reset, so open cards track reality without a re-visit.
    // Any store section may rebuild this cheap row — statsFor is a small
    // in-memory aggregation, no re-read, no filtering games that could
    // accidentally HIDE the row when an unrelated section fires.
    return StreamBuilder<String>(
      stream: widget.deps.store.changes,
      builder: (context, _) => _buildStats(context, c, cache),
    );
  }

  Widget _buildStats(
      BuildContext context, NexusColors c, FragmentLadderCache cache) {
    final stats = cache.statsFor(widget.sub.id);
    if (stats.isEmpty) return const SizedBox.shrink();

    const rungLabels = {
      'conservative': 'Conservative',
      'default': 'Default',
      'aggressive': 'Aggressive',
    };
    final best = cache.bestRungFor(widget.sub.id);
    final chips = <Widget>[];
    for (final entry in rungLabels.entries) {
      final pair = stats[entry.key];
      if (pair == null || pair[0] == 0) continue;
      final attempts = pair[0];
      final wins = pair[1];
      final isBest = best?.id == entry.key;
      chips.add(_rungChip(
        context,
        c,
        label: entry.value,
        rate: '$wins/$attempts',
        pct: wins / attempts,
        highlight: isBest,
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Fragment win rates '
                      '(last ${fragmentStatWindow.inDays} days)',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: c.textMuted, letterSpacing: 0.7),
                ),
              ),
              IconButton(
                tooltip: 'Reset fragment stats for this subscription',
                icon: _resetting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.restart_alt, size: 18),
                onPressed: _resetting ? null : () => _confirmReset(context),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(spacing: 8, runSpacing: 6, children: chips),
        ],
      ),
    );
  }

  Widget _rungChip(
    BuildContext context,
    NexusColors c, {
    required String label,
    required String rate,
    required double pct,
    required bool highlight,
  }) {
    final color =
        highlight ? c.success : (pct == 0 ? c.textMuted : c.textSecondary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:
            highlight ? c.success.withValues(alpha: 0.12) : c.surfaceSunken,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
            color: highlight ? c.success : c.border,
            width: highlight ? 1.2 : 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (highlight) ...[
            Icon(Icons.verified, size: 13, color: c.success),
            const SizedBox(width: 4),
          ],
          Text('$label $rate',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Future<void> _confirmReset(BuildContext dialogContext) async {
    final ok = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('Reset fragment stats?'),
        content: const Text(
            'Forget the recorded fragment probe results for this '
            'subscription (last 30 days). The AUTO ladder will re-learn '
            'from conservative on the next connect. Winners and suggestions '
            'are kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _resetting = true);
    try {
      await widget.deps.fragmentLadderCache.resetStatsFor(widget.sub.id);
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }
}

