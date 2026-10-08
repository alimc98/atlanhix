import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;
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
                  itemBuilder: (context, i) => _SubCard(
                    sub: items[i],
                    deps: deps,
                    onEdit: () => _editDialog(context, items[i]),
                  ),
                );
        if (embedded) {
          return Column(
            children: [
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      // v0.5.2 §user — IMPORT FROM CLIPBOARD: reads the
                      // clipboard; a URL becomes a subscription instantly.
                      TextButton.icon(
                        onPressed: () => _importFromClipboard(context),
                        icon: const Icon(Icons.content_paste, size: 18),
                        label: Text(l.fromClipboard),
                      ),
                      TextButton.icon(
                        onPressed: () => _addDialog(context),
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(l.addSubscription),
                      ),
                    ],
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

  /// v0.5.2 §user — IMPORT FROM CLIPBOARD: one tap, no dialog typing. An
  /// http(s) URL becomes a subscription; share links become nodes.
  Future<void> _importFromClipboard(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    String text = '';
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    } catch (_) {}
    text = text.trim();
    if (text.isEmpty) {
      // v0.5.6 §crash-fix: real async gap (Clipboard.getData is a platform
      // channel round trip) and the guards below already account for it —
      // this branch was the one that didn't. Worse than the equivalent in
      // nodes_screen: the `context` here is the StreamBuilder BUILDER's
      // context (see the call site), which is deactivated whenever the
      // stream rebuilds into a different branch, so this is not a narrow
      // window.
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.importFailed)));
      }
      return;
    }
    try {
      if (text.startsWith('http://') || text.startsWith('https://')) {
        final existing = deps.subscriptions.all
            .where((s) => s.url.trim() == text)
            .isNotEmpty;
        if (!existing) {
          await deps.subscriptionService.add(text);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l.importSuccess(1))));
          }
          return;
        }
      }
      final result = deps.importer.import(text);
      await deps.profiles.upsertMany(result.profiles);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.importSuccess(result.profiles.length))));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.importFailed)));
      }
    }
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

  /// v0.5.0 §user: edit an existing subscription — name, URL, auto-update
  /// toggle and the update interval in minutes (10/20/… as the user
  /// asked). An unchanged URL just saves; a changed URL resets the
  /// conditional-fetch cache and triggers an immediate refresh (service).
  Future<void> _editDialog(BuildContext context, Subscription sub) async {
    final l = AppLocalizations.of(context)!;
    final name = TextEditingController(text: sub.name);
    final url = TextEditingController(text: sub.url);
    final interval = TextEditingController(
        text: sub.updateIntervalMinutes.toString());
    var auto = sub.autoUpdate;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l.editSubscription),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration:
                      InputDecoration(labelText: l.subscriptionName),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: url,
                  decoration:
                      InputDecoration(labelText: l.subscriptionUrl),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.autoUpdate),
                  value: auto,
                  onChanged: (v) => setDialogState(() => auto = v),
                ),
                if (auto) ...[
                  const SizedBox(height: 4),
                  TextField(
                    controller: interval,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l.updateIntervalMinutesLabel,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(l.save)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final minutes = int.tryParse(interval.text.trim());
    await deps.subscriptionService.edit(
      sub.id,
      name: name.text,
      url: url.text,
      autoUpdate: auto,
      updateIntervalMinutes: minutes,
    );
  }
}

class _SubCard extends StatelessWidget {
  const _SubCard({
    required this.sub,
    required this.deps,
    required this.onEdit,
  });

  final Subscription sub;
  final AppDependencies deps;
  final VoidCallback onEdit;

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
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: l.edit,
                onPressed: onEdit,
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
              // v0.6.7 §sub-engine (user request): which engine this sub's
              // CONTENT selected — Clash payload → mihomo, plain sub → the
              // per-node auto matrix. Rows with a null override (imported
              // before this feature) show the global-Engine fallback text.
              _stat(context, l.subEngine, _engineLabel(l)),
            ],
          ),
          // v0.5.0 §user: auto-update state — interval and the next due
          // time, so the new per-subscription minutes field is visible
          // without opening the editor. Hidden while auto-update is off.
          if (sub.autoUpdate && sub.nextUpdate != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.update, size: 15, color: c.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${l.autoUpdate} · ${l.updateIntervalMinutesLabel}: '
                      '${sub.updateIntervalMinutes} · '
                      '${l.nextUpdate}: '
                      '${_fmtClock(sub.nextUpdate!, DateTime.now())}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: c.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          // v0.4.6 §user-3: which fragment mode actually WORKS for this
          // subscription — real attempt/win counts per rung inside a 30-day
          // freshness window, gathered from the AUTO ladder's real tunnel
          // probes. Hidden until there is evidence (no fabricated 0/0 rows).
          _FragmentStatsSection(sub: sub, deps: deps),
          // v0.4.7 §user: last-update screening summary — how many Xray-only
          // nodes (xhttp/mKCP) and how many carry stream-shape risks.
          // Hidden when the last update produced no findings.
          if (sub.screenXrayOnly > 0 || sub.screenRisky > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _ScreeningSummary(
                  xrayOnly: sub.screenXrayOnly, risky: sub.screenRisky),
            ),
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

  /// v0.6.7 §sub-engine: human label for this subscription's engine pick.
  String _engineLabel(AppLocalizations l) => switch (sub.coreOverride) {
        'mihomo' => l.subEngineMihomo,
        'auto' => l.subEngineAuto,
        _ => l.subEngineGlobal,
      };

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

  static String _fmtClock(DateTime t, DateTime now) {
    final d = t.difference(now);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return 'in ${d.inMinutes}m';
    if (d.inHours < 24) {
      return 'in ${d.inHours}h ${d.inMinutes % 60}m';
    }
    return 'in ${d.inDays}d';
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
      BuildContext context, ThemeExt c, FragmentLadderCache cache) {
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
    ThemeExt c, {
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

/// v0.4.7 §user: one-line screening summary of the last subscription update
/// — Xray-only node count (xhttp/mKCP need the Xray core) and how many
/// carry stream-shape risks. Redaction-safe: counts only, never hosts.
class _ScreeningSummary extends StatelessWidget {
  const _ScreeningSummary({required this.xrayOnly, required this.risky});

  final int xrayOnly;
  final int risky;

  @override
  Widget build(BuildContext context) {
    final c = ThemeExt.of(context);
    final l = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined,
              size: 15, color: c.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l.screeningSummary(xrayOnly, risky),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

