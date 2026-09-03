import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../application/dependencies.dart';
import '../../diagnostics/diagnostics_service.dart';
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';

/// Settings (§37): appearance, language, connection mode, about.
class SettingsScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
                    selected: themeMode == m,
                    onSelected: (_) => onThemeChanged(m),
                  ),
                ),
            ],
          ),
        ]),
        _section(context, l.language, [
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
                    onSelected: (_) => onLocaleChanged(loc),
                  ),
                ),
            ],
          ),
        ]),
        _section(context, l.connectionMode, [
          Text(
            'System proxy · TUN · Managed — see docs/PLATFORM_ARCHITECTURE.md',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: c.textSecondary),
          ),
        ]),
        _section(context, 'Diagnostics', [
          Text(
            'Collects effective core, engine states, real PIDs, ports, DNS, '
            'readiness, probe result and recent (redacted) logs.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => _runDiagnostics(context),
            icon: const Icon(Icons.bug_report_outlined),
            label: const Text('Run Diagnostics'),
          ),
        ]),
        _section(context, l.about, [
          Text('Atlanhix 0.3.0'),
          const SizedBox(height: 4),
          Text(
            'Flutter ${const String.fromEnvironment("FLUTTER_VERSION", defaultValue: "3.47")} · '
            'sing-box / Xray-core adapters · WARP · WireGuard · AmneziaWG · MasterDNSVPN',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: c.textSecondary),
          ),
        ]),
      ],
    );
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
      cores: deps.cores,
      routing: deps.connection.routing,
      dns: deps.connection.dns,
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
