import 'package:flutter/material.dart';
import '../../application/dependencies.dart';
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';

/// WARP screen (§35): account status + generate/regenerate/export.
class WarpScreen extends StatelessWidget {
  const WarpScreen({super.key, required this.deps});

  final AppDependencies deps;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);
    final account = deps.warpRepo.account;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
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
                      Icon(Icons.shield_outlined, color: c.accent),
                      const SizedBox(width: 10),
                      Text(l.warpTitle,
                          style: Theme.of(context).textTheme.titleLarge),
                      const Spacer(),
                      StatusPill(
                        label: account == null ? l.warpNotRegistered : l.warpReady,
                        color: account == null ? c.textMuted : c.success,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (account == null)
                    Text(
                      l.warpNotRegistered,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: c.textSecondary),
                    )
                  else ...[
                    _row(context, l.warpStatus, account.endpointV4.isEmpty ? '—' : 'Registered'),
                    _row(context, 'Endpoint', account.endpointV4),
                    _row(context, 'IPv4', account.addressV4 ?? '—'),
                    _row(context, 'IPv6', account.addressV6 ?? '—'),
                    _row(context, l.warpLicense,
                        account.license == null || account.license!.isEmpty ? '—' : '••••'),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _generate(context),
                        icon: const Icon(Icons.key, size: 18),
                        label: Text(account == null
                            ? l.warpGenerate
                            : l.warpRegenerate),
                      ),
                      if (account != null)
                        OutlinedButton.icon(
                          onPressed: () async {
                            await deps.warpRepo.clear();
                          },
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: Text(l.delete),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l.warpStatus,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String k, String v) {
    final c = ThemeExt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(k,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: c.textMuted)),
          ),
          Expanded(
            child: Text(v, style: NexusTypography.monoStyle.copyWith(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<void> _generate(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final account = await deps.warpService.register();
      await deps.warpRepo.save(account);
      messenger.showSnackBar(
        SnackBar(content: Text('WARP OK: ${account.deviceId}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('WARP registration failed: $e')),
      );
    }
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
