import 'package:flutter/material.dart';
import 'application/dependencies.dart';
import 'localization/generated/app_localizations.dart';
import 'presentation/app_shell.dart';
import 'theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final deps = await AppDependencies.bootstrap();
  runApp(AtlanhixApp(deps: deps));
}

class AtlanhixApp extends StatefulWidget {
  const AtlanhixApp({super.key, required this.deps});

  final AppDependencies deps;

  @override
  State<AtlanhixApp> createState() => _AtlanhixAppState();
}

class _AtlanhixAppState extends State<AtlanhixApp> {
  AtlanhixThemeMode _mode = AtlanhixThemeMode.dark;
  Locale _locale = const Locale('en');

  void setTheme(AtlanhixThemeMode m) => setState(() => _mode = m);
  void setLocale(Locale l) => setState(() => _locale = l);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Atlanhix',
      debugShowCheckedModeBanner: false,
      theme: AtlanhixTheme.theme(AtlanhixThemeMode.light, locale: _locale.toString()),
      darkTheme: AtlanhixTheme.theme(_mode, locale: _locale.toString()),
      themeMode: _mode == AtlanhixThemeMode.light ? ThemeMode.light : ThemeMode.dark,
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
