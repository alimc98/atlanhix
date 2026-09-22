import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'application/clipboard_import_service.dart';
import 'application/dependencies.dart';
import 'application/update_checker.dart';
import 'core/engine_availability.dart';
import 'core/logger.dart';
import 'localization/generated/app_localizations.dart';
import 'platform/android_vpn.dart';
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
    // v0.4.9: arm the AmneziaWG gates from the libbox engine's self-reported
    // version (fork marker `-lx.`) — same honesty contract as the Xray
    // handshake above.
    await probeEngineVersion();
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
          // v0.4.9 §user: the intro is ONE user-provided artwork (logo mark
          // + wordmark in a single image) — the previous two-image stack
          // (mark_square + tagline) is gone.
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Container(
              color: const Color(0xFF0A0B0E),
              alignment: Alignment.center,
              child: Image.asset(
                'assets/brand/intro.jpg',
                width: 280,
                fit: BoxFit.contain,
                errorBuilder: (c, e, s) => const SizedBox(height: 120),
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
  bool _clipboardAsked = false;
  bool _warpOfferWired = false;
  DateTime? _updateCheckedAt;

  void setTheme(AtlanhixThemeMode m) => setState(() => _mode = m);
  void setLocale(Locale l) => setState(() => _locale = l);

  void _refreshRouting() => setState(() {});

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // v0.4.7 §user: ONE clipboard prompt per app open, after the shell has
    // a Navigator (Happ/V2Box-style "add from clipboard?"). Post-first-frame
    // so the paste toast lands on a settled UI.
    if (!_clipboardAsked) {
      _clipboardAsked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _offerClipboardImport());
    }
    // v0.4.7 §user: the release checker — throttled to 24h, silent offline,
    // Download opens the release APK in the browser (no silent installs).
    final now = DateTime.now();
    if (_updateCheckedAt == null ||
        now.difference(_updateCheckedAt!) >= const Duration(hours: 24)) {
      _updateCheckedAt = now;
      WidgetsBinding.instance.addPostFrameCallback((_) => _offerUpdate());
    }
    // v0.4.8 §user: wire the WARP auto-rescue dialog ONCE — the session
    // calls [onWarpOffer] after N consecutive in-tunnel URL-test failures
    // ("this node looks filtered — chain WARP in front?").
    if (!_warpOfferWired) {
      _warpOfferWired = true;
      widget.deps.vpnSession.onWarpOffer = _offerWarpRescue;
    }
  }

  Future<bool> _offerWarpRescue(String nodeName) async {
    if (!mounted) return false;
    final l = AppLocalizations.of(context)!;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(ctx)!.warpOfferTitle),
        content: Text(AppLocalizations.of(ctx)!.warpOfferBody(
            nodeName,
            widget.deps.appSettings.warpAutoOfferThreshold)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.clipboardLater),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppLocalizations.of(ctx)!.warpOfferEnable),
          ),
        ],
      ),
    );
    return go == true;
  }

  Future<void> _offerUpdate() async {
    final info = await UpdateChecker().check(currentVersion: kAppVersion);
    if (info == null || !mounted) return;
    final l = AppLocalizations.of(context)!;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Update ${info.version}'),
        content: Text(
            'A newer Atlanhix release (${info.version}) is available. Open the download page?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.clipboardLater),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (go == true && mounted) {
      // v0.4.7 §user: open the release URL via the platform channel
      // (ACTION_VIEW) — no url_launcher dependency needed.
      try {
        await const MethodChannel('dev.atlanhix/vpn')
            .invokeMethod('openUrl', {'url': info.url});
      } catch (e) {
        Logger.instance.warn('update', 'openUrl failed: $e');
      }
    }
  }

  Future<void> _offerClipboardImport() async {
    final deps = widget.deps;
    // v0.4.9 §fix: NULL-SAFE localization — this callback fires from the
    // FIRST post-frame callback, where the Localizations delegate may not
    // have installed itself yet (device crash: "Null check operator used on
    // a null value" at the `!` right here). Localization is re-read AFTER
    // the async gap, null-guarded, before the dialog is shown.
    final service = ClipboardImportService(
      importer: deps.importer,
      onAddNodes: (profiles) => deps.profiles.upsertMany(profiles),
      onAddSubscription: (url) async {
        final existing = deps.subscriptions.all
            .where((s) => s.url.trim() == url.trim())
            .firstOrNull;
        if (existing != null) return; // already added — idempotent offer
        await deps.subscriptionService.add(url);
      },
    );
    final offer = await service.peekOffer();
    if (offer == null || !mounted) return;
    // Localization is available NOW (post-build, post-async-gap); bail
    // honestly when the delegate never arrived.
    final loc = AppLocalizations.of(context);
    if (loc == null) return;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.clipboardAddTitle),
        content: Text(loc.clipboardAddBody(offer.lineCount)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: Text(loc.clipboardLater),
          ),
          if (offer.kind == ClipboardPayloadKind.subscriptionUrl)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'sub'),
              child: Text(loc.clipboardAddSubscription),
            )
          else ...[
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'sub'),
              child: Text(loc.clipboardAddSubscription),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'nodes'),
              child: Text(loc.clipboardAddNodes),
            ),
          ],
        ],
      ),
    );
    if (action == null || action == 'later' || !mounted) return;
    try {
      if (action == 'sub') {
        await service.onAddSubscription(offer.text);
      } else {
        final result = deps.importer.import(offer.text);
        await service.onAddNodes(result.profiles);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✔')),
        );
      }
    } catch (e) {
      Logger.instance.error('clipboard-import', '$e');
    }
  }

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
