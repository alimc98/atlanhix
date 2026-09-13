import 'package:flutter/material.dart';

import 'application/dependencies.dart';
import 'localization/generated/app_localizations.dart';
import 'presentation/app_shell.dart';
import 'presentation/screens/apps_routing_screen.dart';
import 'presentation/screens/routing_diagnostics_screen.dart';
import 'presentation/screens/routing_editor_screen.dart';
import 'presentation/screens/routing_screen.dart';
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

  void _refreshRouting() => setState(() {});

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
      // v0.4.1 §10/§11: named routes for the editable routing screens
      // (Settings → Routing → Applications/Mode/Domains/Networks).
      routes: {
        '/routing': (ctx) => RoutingEditorScreen(
              routingRepo: widget.deps.routingSettingsRepo,
              routing: widget.deps.routingSettings,
              onChanged: _refreshRouting,
            ),
        '/routing/apps': (ctx) => AppsRoutingScreen(
              controller: widget.deps.vpnSession.controller,
              routingRepo: widget.deps.routingSettingsRepo,
              routing: widget.deps.routingSettings,
              onChanged: _refreshRouting,
            ),
        '/routing/diagnostics': (ctx) =>
            RoutingDiagnosticsScreen(deps: widget.deps),
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/routing/legacy') {
          return MaterialPageRoute<void>(
            builder: (ctx) => RoutingScreen(deps: widget.deps),
          );
        }
        return null;
      },
      home: AppShell(
        deps: widget.deps,
        onThemeChanged: setTheme,
        onLocaleChanged: setLocale,
        themeMode: _mode,
      ),
    );
  }
}
