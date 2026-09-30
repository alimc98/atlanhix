import 'dart:async';

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

  /// v0.5.6 §leak-fix: the Logger singleton's listener, so it can be
  /// cancelled in [dispose].
  StreamSubscription<LogLine>? _logSub;

  @override
  void initState() {
    super.initState();
    _lines = Logger.instance.buffer;
    // v0.5.6 §leak-fix: the subscription was discarded and this State had
    // NO dispose(). `Logger` is a process singleton, so every mount left a
    // live listener holding this State forever. Worse, `Logger.buffer`
    // returns `List.unmodifiable(_buffer)` — a FRESH copy of up to 2000
    // lines — so each retained listener allocated a full copy per log line.
    _logSub = Logger.instance.stream.listen((_) {
      if (mounted) setState(() => _lines = Logger.instance.buffer);
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _logSub = null;
    super.dispose();
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
