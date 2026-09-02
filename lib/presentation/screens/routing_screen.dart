import 'package:flutter/material.dart';
import '../../application/dependencies.dart';
import '../../localization/generated/app_localizations.dart';
import '../../routing/routing_models.dart';
import '../../theme/theme.dart';

/// Routing profiles & rules editor (§25, §17).
class RoutingScreen extends StatelessWidget {
  const RoutingScreen({super.key, required this.deps});

  final AppDependencies deps;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final profiles = deps.routingRep.all;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: profiles.length,
      itemBuilder: (context, i) {
        final p = profiles[i];
        final c = ThemeExt.of(context);
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
                    child: Text(p.name,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  if (p.isBuiltin)
                    Chip(label: Text(l.routingProfiles)),
                ],
              ),
              const SizedBox(height: 8),
              for (final r in p.rules.take(6))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(
                        switch (r.action) {
                          RoutingAction.direct => Icons.arrow_forward,
                          RoutingAction.proxy => Icons.vpn_key,
                          RoutingAction.warp => Icons.shield,
                          RoutingAction.block => Icons.block,
                          RoutingAction.chain => Icons.link,
                        },
                        size: 15,
                        color: ThemeExt.of(context).accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${r.matchType.name}: ${r.patterns.join(', ')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: c.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              if (p.rules.length > 6)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '+${p.rules.length - 6} …',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: c.textMuted),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
