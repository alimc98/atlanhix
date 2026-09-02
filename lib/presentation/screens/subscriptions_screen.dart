import 'package:flutter/material.dart';
import '../../application/dependencies.dart';
import '../../domain/entities/proxy_profile.dart';
import '../../domain/entities/subscription.dart';
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';

class SubscriptionsScreen extends StatelessWidget {
  const SubscriptionsScreen({super.key, required this.deps});

  final AppDependencies deps;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);

    return StreamBuilder<List<Subscription>>(
      stream: deps.subscriptions.changes,
      builder: (context, snapshot) {
        final items = snapshot.data ?? deps.subscriptions.all;
        return Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _addDialog(context),
            icon: const Icon(Icons.add),
            label: Text(l.addSubscription),
          ),
          body: items.isEmpty
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
                ),
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

