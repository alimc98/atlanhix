import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'application/clipboard_import_service.dart';
import 'application/dependencies.dart';
import 'application/update_checker.dart';
import 'core/engine_availability.dart';
import 'core/logger.dart';
import 'localization/generated/app_localizations.dart';
import 'settings/app_settings.dart';
import 'platform/android_vpn.dart';
import 'platform/probe_engine.dart';
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
    // v0.4.9 §boot: deps (storage, repos, session) first — the shell can
    // paint as soon as THIS resolves. The engine handshakes below gate only
    // badges/capability text, so they ride behind unawaited and land while
    // the user is already looking at the UI (hundreds of ms earlier).
    final deps = await AppDependencies.bootstrap();
    unawaited(() async {
      // v0.4.3: learn the TRUTH about the Xray runtime (exec'd native binary
      // in the :xray process) before badges paint — but never blocking the
      // first interactive frame for it.
      await XrayBridge.instance.probe();
      XrayCoreState.instance.setRuntimeLoaded(XrayBridge.instance.available);
      // v0.4.9: arm the AmneziaWG gates from the libbox engine's
      // self-reported version (fork marker `-lx.`).
      await probeEngineVersion();
    }());
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

class _AtlanhixAppState extends State<AtlanhixApp>
    with WidgetsBindingObserver {
  AtlanhixThemeMode _mode = AtlanhixThemeMode.dark;
  Locale _locale = const Locale('en');
  bool _clipboardAsked = false;
  bool _warpOfferWired = false;
  DateTime? _updateCheckedAt;
  // v0.4.9 §user-fix (clipboard auto-detect): dialogs must resolve their
  // context INSIDE MaterialApp — this State's context sits ABOVE it, where
  // Localizations/ScaffoldMessenger/Navigator don't exist.
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  String? _lastClipboardOffer;
  bool _clipboardCheckInFlight = false;

  /// v0.4.9 §user-fix: stable hash of a clipboard payload for the
  /// PERSISTED offer memory (settings.clipboardOfferedHashes) — survives
  /// app restarts, unlike the session-only [_lastClipboardOffer].
  String _clipboardHash(String payload) =>
      crypto.sha256.convert(utf8.encode(payload.trim())).toString();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // v0.4.9 §user-fix (auto-detect never fired): the config/subscription
      // link is almost always copied in ANOTHER app — the one-shot boot
      // check can't see content copied afterwards. Re-check on every
      // return (deduped by clipboard content inside the presenter).
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _checkClipboardOnResume());
    }
    // v0.4.9 §battery: the transient probe engine exists ONLY for foreground
    // delay tests. Backgrounded with no live VPN it is a hidden Go runtime
    // with open sockets — shut it down the moment the app leaves the
    // foreground (the idle timer already stops it after 20 s anyway).
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      ProbeEngine.instance.stop();
    }
  }

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
    // v0.4.9 §user-fix: resolve localization INSIDE MaterialApp — the
    // State's own context can never see the LocalizationsScope (the old
    // `of(context)!` threw every time the rescue dialog was requested).
    final navCtx = _navKey.currentContext;
    if (navCtx == null) return false;
    final l = AppLocalizations.of(navCtx);
    if (l == null) return false;
    final go = await showDialog<bool>(
      context: navCtx,
      builder: (ctx) => AlertDialog(
        title: Text(l.warpOfferTitle),
        content: Text(l.warpOfferBody(
            nodeName,
            widget.deps.appSettings.warpAutoOfferThreshold)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.clipboardLater),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.warpOfferEnable),
          ),
        ],
      ),
    );
    return go == true;
  }

  Future<void> _offerUpdate() async {
    final info = await UpdateChecker().check(currentVersion: kAppVersion);
    if (info == null || !mounted) return;
    final navCtx = _navKey.currentContext;
    if (navCtx == null) return;
    // v0.4.9 §user-fix: same above-MaterialApp context bug — the `!` here
    // crashed whenever an update was actually available.
    final l = AppLocalizations.of(navCtx);
    if (l == null) return;
    final go = await showDialog<bool>(
      context: navCtx,
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

  ClipboardImportService _clipboardService() {
    final deps = widget.deps;
    return ClipboardImportService(
      importer: deps.importer,
      onAddNodes: (profiles) => deps.profiles.upsertMany(profiles),
      onAddSubscription: (url) async {
        final existing = deps.subscriptions.all
            .where((s) => s.url.trim() == url.trim())
            .firstOrNull;
        if (existing != null) return; // already added — idempotent offer
        await deps.subscriptionService.add(url);
      },
      // v0.4.9 §user-fix ("بازم میگه ادد کنم در حالی که ادد شده"): a
      // clipboard payload that is ALREADY inside the app never re-offers —
      // across app runs too, because this reads the LIVE repositories:
      //  * a subscription URL → matched against every added subscription,
      //  * share links → imported; the offer is skipped only when EVERY
      //    imported node matches an existing profile by identity hash
      //    (protocol|server|port|transport|security|credentials — cosmetics
      //    excluded), so a renamed/edited node still counts as known and
      //    one NEW link inside a pasted bundle still gets offered.
      knownPayload: (payload) {
        final p = payload.trim();
        // v0.4.9 §user-fix layer 2: this exact payload was ALREADY offered
        // (answered add/later) — persisted, so a restart never re-asks.
        if (widget.deps.appSettings.clipboardOfferedHashes
            .contains(_clipboardHash(p))) {
          return true;
        }
        if (p.startsWith('http://') || p.startsWith('https://')) {
          return deps.subscriptions.all
              .any((s) => s.url.trim() == p);
        }
        try {
          final result = deps.importer.import(p);
          final nodes = result.profiles;
          if (nodes.isEmpty) return false;
          final known = deps.profiles.all
              .map((n) => n.identityHash)
              .toSet();
          return nodes.every((n) => known.contains(n.identityHash));
        } catch (_) {
          return false;
        }
      },
    );
  }

  Future<void> _offerClipboardImport() async {
    final offer = await _clipboardService().peekOffer();
    if (offer == null || !mounted) return;
    await _presentClipboardOffer(_clipboardService(), offer);
  }

  /// v0.4.9 §user-fix: re-checked on every resume — the payload is copied
  /// in ANOTHER app, so the one-shot boot check can never see it.
  Future<void> _checkClipboardOnResume() async {
    if (_clipboardCheckInFlight) return;
    _clipboardCheckInFlight = true;
    try {
      // Focus (and Android's clipboard access rights) settle a beat after
      // the resume callback — read too early and the OS hands back empty.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      final offer = await _clipboardService().peekOffer();
      if (offer == null || !mounted) return;
      await _presentClipboardOffer(_clipboardService(), offer);
    } finally {
      _clipboardCheckInFlight = false;
    }
  }

  Future<void> _presentClipboardOffer(
      ClipboardImportService service, ClipboardOffer offer) async {
    // Same clipboard content already offered this session → don't nag.
    if (_lastClipboardOffer == offer.text) return;
    // v0.4.9 §user-fix layer 2 (persisted): offered before (any past run)
    // → never again.
    if (widget.deps.appSettings.clipboardOfferedHashes
        .contains(_clipboardHash(offer.text))) {
      _lastClipboardOffer = offer.text;
      return;
    }
    // v0.4.9 §fix (ROOT CAUSE): every dialog resource must resolve INSIDE
    // MaterialApp. The State's own context sits ABOVE it — localization
    // was null there, so the offer silently bailed EVERY time (the
    // device-crash guard below used to be a permanent dead end).
    final navCtx = _navKey.currentContext;
    if (navCtx == null || !mounted) return;
    final loc = AppLocalizations.of(navCtx);
    if (loc == null) return;
    _lastClipboardOffer = offer.text;
    final hash = _clipboardHash(offer.text);
    final action = await showDialog<String>(
      context: navCtx,
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
    // v0.4.9 §user-fix: the offer was ANSWERED — remember it forever so a
    // restart never shows the same payload's dialog again ("ادد شده، دوباره
    // نپرس"). Both answers (add AND later) are remembered: the user chose.
    final st = widget.deps.appSettings;
    if (!st.clipboardOfferedHashes.contains(hash)) {
      st.clipboardOfferedHashes = [
        ...st.clipboardOfferedHashes,
        hash,
      ].reversed.take(AppSettings.clipboardOfferLimit).toList().reversed
          .toList();
      await widget.deps.appSettingsRepo.save(st);
    }
    if (action == null || action == 'later' || !mounted) return;
    try {
      if (action == 'sub') {
        await service.onAddSubscription(offer.text);
      } else {
        final result = widget.deps.importer.import(offer.text);
        await service.onAddNodes(result.profiles);
      }
      final snCtx = _navKey.currentContext;
      if (mounted && snCtx != null) {
        ScaffoldMessenger.of(snCtx).showSnackBar(
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
      // v0.4.9 §user-fix: the key that lets lifecycle callbacks reach a
      // context INSIDE the app (dialogs/localization/snackbars).
      navigatorKey: _navKey,
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
