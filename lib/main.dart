import 'package:flutter/material.dart';
import 'application/dependencies.dart';
import 'localization/generated/app_localizations.dart';
import 'presentation/app_shell.dart';
import 'theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final deps = await AppDependencies.bootstrap();
  runApp(NexusApp(deps: deps));
}

class NexusApp extends StatefulWidget {
  const NexusApp({super.key, required this.deps});

  final AppDependencies deps;

  @override
  State<NexusApp> createState() => _NexusAppState();
}

class _NexusAppState extends State<NexusApp> {
  NexusThemeMode _mode = NexusThemeMode.dark;
  Locale _locale = const Locale('en');

  void setTheme(NexusThemeMode m) => setState(() => _mode = m);
  void setLocale(Locale l) => setState(() => _locale = l);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NEXUS',
      debugShowCheckedModeBanner: false,
      theme: NexusTheme.theme(NexusThemeMode.light, locale: _locale.toString()),
      darkTheme: NexusTheme.theme(_mode, locale: _locale.toString()),
      themeMode: _mode == NexusThemeMode.light ? ThemeMode.light : ThemeMode.dark,
      locale: _locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: AppShell(
        deps: widget.deps,
        onThemeChanged: setTheme,
        onLocaleChanged: setLocale,
        themeMode: _mode,
      ),
    );
  }
}
