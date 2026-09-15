import 'package:flutter/material.dart';

import 'application/dependencies.dart';
import 'core/engine_availability.dart';
import 'localization/generated/app_localizations.dart';
import 'platform/xray_bridge.dart';
import 'presentation/app_shell.dart';
import 'presentation/screens/warp_screen.dart';
import 'presentation/screens/apps_routing_screen.dart';
import 'presentation/screens/routing_diagnostics_screen.dart';
import 'presentation/screens/routing_editor_screen.dart';
import 'presentation/screens/routing_screen.dart';
import 'theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // v0.4.4 (§user: white screen at launch): do NOT await bootstrap before
  // runApp — that blocked the first frame (white) for seconds. Warm-up now
  // runs while the branded intro is on screen.
  final warmup = () async {
    final deps = await AppDependencies.bootstrap();
    // v0.4.3: learn the TRUTH about the Xray runtime (exec'd native binary
    // in the :xray process) before the UI paints a single badge.
    await XrayBridge.instance.probe();
    XrayCoreState.instance.setRuntimeLoaded(XrayBridge.instance.available);
    return deps;
  }();
  runApp(AtlanhixRoot(warmup: warmup));
}

/// Paints the intro immediately and swaps to the app the moment warm-up
/// resolves — the curtain never outstays the work.
class AtlanhixRoot extends StatelessWidget {
  const AtlanhixRoot({super.key, required this.warmup});

  final Future<AppDependencies> warmup;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppDependencies>(
      future: warmup,
      builder: (context, snap) {
        if (snap.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              backgroundColor: const Color(0xFF0A0B0E),
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Startup failed: ${snap.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFE8E9ED)),
                  ),
                ),
              ),
            ),
          );
        }
        if (!snap.hasData) {
          // Branded dark intro with the user-provided artwork — same paint
          // as the native launch window, so the transition is seamless.
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Container(
              color: const Color(0xFF0A0B0E),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.asset('assets/intro/splash_art.png',
                        fit: BoxFit.contain,
                        errorBuilder: (c, e, s) => const SizedBox(height: 120)),
                  ),
                  const SizedBox(height: 18),
                  const Text('ATLANHIX',
                      style: TextStyle(
                          color: Color(0xFFE8E9ED),
                          fontSize: 18,
                          letterSpacing: 6,
                          fontWeight: FontWeight.w300)),
                ],
              ),
            ),
          );
        }
        return AtlanhixApp(deps: snap.data!);
      },
    );
  }
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
        // v0.4.3: WARP demoted from a bottom tab to a Settings sub-page.
        '/warp': (ctx) => Scaffold(
              appBar: AppBar(),
              body: WarpScreen(deps: widget.deps),
            ),
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
