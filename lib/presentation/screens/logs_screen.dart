import 'package:flutter/material.dart';
import '../../application/dependencies.dart';
import '../../core/logger.dart';
import '../../localization/generated/app_localizations.dart';
import '../../theme/theme.dart';

/// Live log viewer (§42): filter, copy, clear; redacted upstream.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, required this.deps});

  final AppDependencies deps;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  String _query = '';
  List<LogLine> _lines = const [];

  @override
  void initState() {
    super.initState();
    _lines = Logger.instance.buffer;
    Logger.instance.stream.listen((_) {
      if (mounted) setState(() => _lines = Logger.instance.buffer);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final c = ThemeExt.of(context);
    final filtered = _query.isEmpty
        ? _lines
        : _lines.where((x) => x.message.toLowerCase().contains(_query)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _query = v.toLowerCase()),
                  decoration:
                      InputDecoration(hintText: l.search, isDense: true),
                ),
              ),
              IconButton(
                onPressed: () => setState(() => Logger.instance.clear()),
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: l.clearLogs,
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: BorderRadius.circular(NexusSpacing.radiusCard),
              border: Border.all(color: c.border),
            ),
            child: filtered.isEmpty
                ? Center(
                    child: Text('—',
                        style: TextStyle(color: c.textMuted)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(10),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final line = filtered[i];
                      final color = switch (line.level) {
                        LogLevel.error => c.error,
                        LogLevel.warn => c.warning,
                        LogLevel.info => c.textPrimary,
                        _ => c.textMuted,
                      };
                      return SelectableText.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${line.at.toIso8601String().substring(11, 19)} ',
                              style: NexusTypography.monoStyle.copyWith(
                                  fontSize: 11.5, color: c.textMuted),
                            ),
                            TextSpan(
                              text: '[${line.scope}] ',
                              style: NexusTypography.monoStyle.copyWith(
                                  fontSize: 11.5, color: c.accent),
                            ),
                            TextSpan(
                              text: line.message,
                              style: NexusTypography.monoStyle
                                  .copyWith(fontSize: 11.5, color: color),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
