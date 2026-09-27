import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../data/app_storage.dart';
import '../core/logger.dart';
import '../data/profile_repository.dart';
import '../data/repositories.dart';
import '../data/secure_vault.dart';
import '../application/connection_controller.dart';
import '../application/real_delay_tester.dart';
import '../application/subscription_service.dart';
import '../core/core_detector.dart';
import '../core/fragmentation/fragment_ladder_cache.dart';
import '../core/health/latency_tester.dart';
import '../core/health/test_scheduler.dart';
import '../core/runtime/binary_manager.dart';
import '../core/runtime/clash_api_client.dart';
import '../core/runtime/core_manager.dart';
import '../core/runtime/singbox_runtime.dart';
import '../protocols/importer.dart';
import '../routing/builtin_profiles.dart';
import '../settings/app_settings.dart';
import '../settings/routing_settings.dart';
import '../settings/runtime_config_bridge.dart';
import '../settings/vpn_session.dart';
import '../platform/probe_engine.dart';
import '../platform/vault_factory.dart';
import '../warp/warp_http.dart';
import '../warp/warp_registrar.dart';

/// Composition root. Builds the object graph once at startup and hands
/// controllers to the UI; nothing in the UI constructs services itself.
class AppDependencies {
  AppDependencies._();

  // v0.5.0 §boot: per-stage stopwatch. Cold-boot complaints need MEASURED
  // stage weights, not guesses — every stage logs its ms under the 'boot'
  // tag (visible via logcat `grep ATX-DART \[boot\]`).
  static final Stopwatch _bootSw = Stopwatch()..start();
  static void _mark(String stage) {
    Logger.instance
        .info('boot', '$stage: ${_bootSw.elapsedMilliseconds} ms');
  }

  static Future<AppDependencies> bootstrap() async {
    final deps = AppDependencies._();
    _bootSw.reset();

    // v0.4 (§10/§22): storage must live inside the app sandbox on mobile
    // (secure per-app storage); desktop keeps APPDATA/HOME resolution.
    Directory baseDir;
    if (Platform.isAndroid || Platform.isIOS) {
      final support = await getApplicationSupportDirectory();
      baseDir = support;
    } else {
      baseDir = Directory(
          Platform.environment['APPDATA'] ??
              Platform.environment['HOME'] ??
              Directory.systemTemp.path);
    }
    deps.store = JsonStore(
        directory: Directory('${baseDir.path}${Platform.pathSeparator}.nexus'
            '${Platform.pathSeparator}data'),
        schemaVersion: 1);
    // v0.4.1 §41: OS-backed secure storage on mobile/desktop; memory only as
    // a test fallback. Fixes: profile credentials lost after app restart.
    deps.vault = createPlatformVault();
    await deps.store.load();
    _mark('store.load');

    deps.profiles = ProfileRepository(deps.store, deps.vault);
    deps.subscriptions = SubscriptionRepository(deps.store);
    deps.chains = ChainRepository(deps.store);
    deps.routingRep = RoutingRepository(deps.store);
    deps.settings = SettingsRepository(deps.store);
    // v0.4.1: the REAL settings models (§7/§9) — persisted, runtime-honored.
    deps.appSettingsRepo = AppSettingsRepository(deps.store);
    deps.routingSettingsRepo = RoutingSettingsRepository(deps.store);

    // v0.5.0 §boot: the six section loads are INDEPENDENT JsonStore reads
    // that previously ran sequentially; a parallel join shortens the tail.
    // NOTE: profiles.load() here is the FAST phase (store decode only, no
    // vault touch) — the deferred secret resolution rides
    // [deferredSecretResolution] which main.dart runs after the first paint.
    await Future.wait(<Future<void>>[
      deps.profiles.load(),
      deps.subscriptions.load(),
      deps.chains.load(),
      deps.routingRep.load(),
      deps.appSettingsRepo.load(),
      deps.routingSettingsRepo.load(),
    ]);
    _mark('repos.load');
    deps.appSettings = deps.appSettingsRepo.current;
    deps.routingSettings = deps.routingSettingsRepo.current;
    deps.configBridge = RuntimeConfigBridge(
      settings: deps.appSettings,
      routing: deps.routingSettings,
    );

    // v0.5.0 §release: resolve cores NEXT TO THE EXE first (the shipped
    // zip layout) and fall back to the CWD layout (dev runs from the repo
    // root). Directory.current alone broke the bundled zip when the user
    // launched the exe from another working directory (terminal/shortcut).
    Directory resolveCoresDir() {
      final exe = Platform.resolvedExecutable;
      final exeDir = File(exe).parent.path;
      final bundled = Directory(
          '$exeDir${Platform.pathSeparator}cores'
          '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
      if (bundled.existsSync()) return bundled;
      return Directory(
          '${Directory.current.path}${Platform.pathSeparator}cores'
          '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
    }

    deps.binaryManager = BinaryManager(
      // TODO(v0.3): read from Settings → Cores (user override dir).
      appDir: resolveCoresDir(),
    );
    deps.cores = CoreManager(
      binaryManager: deps.binaryManager,
      workDir: Directory('$baseDir/.nexus/runtime'),
      // v0.4.1 §2: on Android the front sing-box config MUST include the tun
      // inbound (libbox owns the tunnel via PlatformInterface.OpenTun).
      enableTun: Platform.isAndroid || Platform.isIOS,
    );

    deps.tester = LatencyTester();
    deps.healthStore = HealthStore();
    deps.scheduler = TestScheduler(tester: deps.tester, store: deps.healthStore)
      // v0.4.9 §user-fix (ping/sweep dead): the scheduler was CONSTRUCTED
      // but never started (its pump refuses every job while stopped) and
      // never told which profiles exist (jobs for unknown ids no-op) — so
      // every enqueue silently evaporated and no latency ever moved. Wire
      // both here, and keep the set fresh across add/remove/refresh.
      // v0.5.0 §user: the TCP-fallback probe rides the shared settings URL.
      ..testUrl = deps.appSettings.effectiveDelayTestUrl
      ..updateProfiles(deps.profiles.all)
      ..start();
    deps.profiles.changes.listen(deps.scheduler.updateProfiles);
    // v0.4.9 §user: REAL delay tester — the node list's test button and the
    // background sweep measure the END-TO-END URL delay through each node's
    // live outbound (engine delay test), never a bare TCP ping. Wired to the
    // front engine's Clash API; engine-off → honest null result.
    // v0.5.0 §user: the probe URL is the SHARED settings field now — the
    // node-list sweep, the Smart Switch ladder, the WARP watchdog and the
    // scheduler's TCP fallback all read the same value. An `http://` URL
    // (v2rayNG's default shape) skips the TLS handshake and reads ~100 ms
    // where the https default read ~900 ms.
    deps.realDelay = RealDelayTester(tester: deps.tester)
      ..probeUrl = deps.appSettings.effectiveDelayTestUrl
      ..engineDelayTest = (p) async {
        // v0.4.9 §device: on Android the engine runs INSIDE the VPN service
        // (libbox) — SingBoxRuntime._api is never constructed because there
        // is no child process, so `front.api` was always null and EVERY
        // node read as 'engine-off' (UI stayed '—'). The Clash API listener
        // itself is real though (127.0.0.1:9097 confirmed on device), so
        // build the client lazily when the port answers.
        var api = deps.cores.front.api;
        api ??= await _probeAndBuildClashApi(deps);
        if (api == null) return null; // engine off — honest 'engine-off'
        // v0.4.9 §user-fix: verify the tag EXISTS in the running config
        // first. A node filtered out of the pool (disabled / not runnable)
        // is simply not in the table — its delayTest would 404 and the old
        // code reported that as a REAL 5-second timeout. Honest null lets
        // the caller fall through to the transient engine instead.
        final tag = '${SingBoxRuntime.tagPrefix}${p.id}';
        final tags = await api.proxyTags();
        if (tags != null && !tags.contains(tag)) return null;
        final ms = await api.delayTest(
            tag,
            deps.realDelay.probeUrl,
            5000);
        if (ms == null) {
          // Engine IS running and the node tag exists, but the real URL
          // fetch failed within 5 s → a REAL dead/unreachable measurement.
          return ProbeResult(
              ok: false,
              latencyMs: null,
              errorKind: 'timeout',
              detail: 'engine delay test: no answer within 5s');
        }
        return ProbeResult(ok: true, latencyMs: ms);
      }
      // v0.4.9 §user: no VPN connected → the TRANSIENT probe engine boots
      // a consent-free libbox with the candidate nodes (proxy-only config)
      // so "test all nodes" works right after a fresh app open. The engine
      // stops itself after an idle gap — zero battery cost while idle.
      // v0.5.0 §perf-fix: the whole batch through ONE engine boot with
      // PARALLEL delay tests — the old serial per-node loop paid
      // (n × worst-case 5 s) per sweep chunk and, worse, a per-node
      // ensureUp rebuilt the Box for every new node id. One boot, then the
      // engine's own delay handler fans the measurements out concurrently.
      ..transientBatchTest = (batch) async {
        final ms = await ProbeEngine.instance
            .delayTestBatch(batch, deps.realDelay.probeUrl, 5000);
        if (ms.isEmpty) return const {};
        return {
          for (final p in batch)
            p.id: ms[p.id] == null
                ? ProbeResult(
                    ok: false,
                    latencyMs: null,
                    errorKind: 'timeout',
                    detail: 'probe engine: no answer within 5s')
                : ProbeResult(ok: true, latencyMs: ms[p.id]),
        };
      };
    deps.detector = CoreDetector();
    deps.importer = MultiFormatImporter();

    // v0.4 BUGFIX (Android device run): warpRepo must be initialized BEFORE
    // ConnectionController reads it — `late final` access during construction
    // threw LateInitializationError and killed bootstrap (white screen).
    deps.warpRepo = WarpRepository(deps.store, deps.vault);
    await deps.warpRepo.load();
    _mark('warpRepo.load');
    deps.warpService = WarpService(registrar: WarpRegistrar(http: HttpWarpApi()));

    deps.connection = ConnectionController(
      repository: deps.profiles,
      healthStore: deps.healthStore,
      tester: deps.tester,
      detector: deps.detector,
      cores: deps.cores,
      warpRepo: deps.warpRepo,
    );
    deps.subscriptionService = SubscriptionService(
      subscriptions: deps.subscriptions,
      profiles: deps.profiles,
      importer: deps.importer,
      // v0.4.7 §user: Happ-style carried routing — a subscription URL with
      // `?routing=<b64json>` converges its domain/CIDR rules onto the user's
      // routing settings after a successful fetch.
      currentRouting: () => deps.routingSettings,
      onCarriedRouting: (next) async {
        final problems = await deps.routingSettingsRepo.save(next);
        if (problems.isEmpty) {
          deps.routingSettings = next;
          Logger.instance.info('subs',
              'carried routing applied: ${next.proxyDomains.length} proxy · '
              '${next.directDomains.length} direct domains');
        }
      },
    );

    // v0.4.1 §2 — the Android VPN session owns the platform-channel
    // controller; Connect on Android routes through it, never the
    // desktop core path.
    deps.vpnSession = VpnSession(deps: deps);
    // v0.5.0 §user-fix ("میرم تلگرام، برمی‌گردم — انگار برنامه تازه باز شده"):
    // Android killed the app process in the background; the NATIVE VPN
    // service kept the tunnel. Restore the persisted selection + switch
    // choice SYNCHRONOUSLY here (store is already loaded) so the FIRST
    // paint shows the user's node — not "tap to connect" over a live tunnel.
    deps.vpnSession.restorePersistedState();
    // v0.4.9 §boot-speed ("سرعت بوت شدن برنامه کند است"): reconcile runs
    // WITHOUT blocking bootstrap. The native state read races the
    // platform-channel handshake and this await sat between repository
    // load and the first paint — while the shell itself re-syncs from
    // vpnSession.uiPhase on every build anyway. A stale CONNECTED pill
    // self-corrects a frame later; a blank shell for 300+ ms every open
    // was the worse trade.
    // v0.5.0 §user-fix: when the reconcile re-adopts a CONNECTED tunnel,
    // the runtime services (scheduler active node, WARP watchdog, Smart
    // Switch ladder) are re-armed too — a fresh process previously came
    // back to a live tunnel with a dead dashboard and no background logic.
    unawaited(deps.vpnSession.controller.reconcileWithNative().then((_) {
      deps.vpnSession.resumeRuntimeServices();
    }).catchError((_) {}));

    // v0.5.0 §user: subscription AUTO-UPDATE pump — `dueNow()` existed since
    // v0.4 but nothing ever called it. Kick the pump once right away (a
    // process killed for a day refreshes overdue subs on the next open,
    // AFTER the UI paints) and keep it ticking every 60 s.
    // v0.5.0 §boot-speed: run AFTER the first await boundary so the kick
    // (a network fetch per due sub) never contends with bootstrap's own
    // awaited I/O on the UI isolate.
    Future<void>.delayed(Duration.zero, () {
      deps.subscriptionService.startAutoUpdatePump();
    });

    // v0.4.6 WIRING: seed the TLS-Fragment pill into both engines at boot.
    // Runtime re-pushes happen per connect (VpnSession._connectProfile on
    // Android; the controller setter below on desktop) so a pill toggle
    // always takes effect on the NEXT connect without an app restart.
    deps.connection.tlsFragmentEnabled = deps.appSettings.tlsFragment;
    deps.cores.tlsFragmentEnabled = deps.appSettings.tlsFragment;
    deps.cores.fragmentPreset = deps.appSettings.fragmentPreset;
    deps.connection.fragmentPreset = deps.appSettings.fragmentPreset;
    // v0.4.7 §user: MANUAL fragment dial rides with the preset.
    deps.cores.fragmentManualPackets = deps.appSettings.fragmentManualPackets;
    deps.cores.fragmentManualLength = deps.appSettings.fragmentManualLength;
    deps.cores.fragmentManualInterval = deps.appSettings.fragmentManualInterval;
    // v0.4.6 §user: per-node winners of the fragment AUTO ladder. A node
    // that already climbed starts its next connect at the proven rung.
    // Exposed on deps too — the subscriptions screen renders the per-rung
    // win-rate stats from the same cache.
    deps.fragmentLadderCache = FragmentLadderCache(deps.store);
    deps.cores.fragmentLadder = deps.fragmentLadderCache;

    // Seed builtin routing profiles on first run.
    if (deps.routingRep.all.isEmpty) {
      for (final p in BuiltinRoutingProfiles.all()) {
        await deps.routingRep.upsert(p);
      }
    }
    _mark('bootstrap.total');
    if (kDebugMode) {
      // ignore: avoid_print
      print('Atlanhix bootstrap complete: ${deps.profiles.all.length} profiles');
    }
    return deps;
  }

  /// v0.5.0 §boot: the DEFERRED half of the profile load — the one-time
  /// Keystore/EncryptedSharedPreferences init (~2.5 s measured on the
  /// device) happens in HERE, off the launch path. main.dart fires it as
  /// an unawaited task right after the shell's first frame; the connect
  /// paths and the subscription updater all await it through the gate
  /// below, so a user who taps Connect within the first seconds simply
  /// waits for the resolution to finish first (measured milliseconds —
  /// the Keystore init already started and is not restarted).
  Future<void>? _secretsResolved;

  Future<void> get deferredSecretResolution =>
      _secretsResolved ??= _resolveSecretsNow();

  Future<void> _resolveSecretsNow() async {
    final sw = Stopwatch()..start();
    // Profile secrets + WARP secrets: BOTH pay the one-time Keystore init
    // (one process-wide cost, shared by these two calls).
    await Future.wait(<Future<void>>[
      profiles.resolveSecrets(),
      warpRepo.resolveSecrets(),
    ]);
    Logger.instance
        .info('boot', 'deferred secrets: ${sw.elapsedMilliseconds} ms');
  }

  /// v0.5.0 §test: a MINIMAL composition for widget tests — a temp-dir
  /// JsonStore + in-memory vault + profile repository, nothing else. The
  /// node editor only touches [profiles]; bootstrapping engines/daemons in
  /// a test would spawn processes and sockets for nothing.
  static Future<AppDependencies> bootstrapForTest() async {
    final deps = AppDependencies._();
    final dir = await Directory.systemTemp.createTemp('nexus_editor_test');
    deps.store = JsonStore(
        directory: Directory('${dir.path}${Platform.pathSeparator}data'),
        schemaVersion: 1);
    deps.vault = InMemoryVault();
    await deps.store.load();
    deps.profiles = ProfileRepository(deps.store, deps.vault);
    await deps.profiles.load();
    return deps;
  }

  late final JsonStore store;
  late final SecureVault vault;
  late final ProfileRepository profiles;
  late final SubscriptionRepository subscriptions;
  late final ChainRepository chains;
  late final RoutingRepository routingRep;
  late final SettingsRepository settings;
  // v0.4.1 — real settings + runtime bridge (§7/§9/§31).
  late final AppSettingsRepository appSettingsRepo;
  late final RoutingSettingsRepository routingSettingsRepo;
  late AppSettings appSettings;
  late RoutingSettings routingSettings;
  late RuntimeConfigBridge configBridge;
  // v0.4.1 §2 — the Android VPN session (platform-channel backed).
  late final VpnSession vpnSession;
  late final BinaryManager binaryManager;
  late final CoreManager cores;
  late final LatencyTester tester;
  late final HealthStore healthStore;
  late final TestScheduler scheduler;
  late final CoreDetector detector;
  late final MultiFormatImporter importer;
  // v0.4.9 §user: end-to-end URL delay tester for the node list.
  late final RealDelayTester realDelay;
  late final ConnectionController connection;
  late final SubscriptionService subscriptionService;
  late final WarpRepository warpRepo;
  late final WarpService warpService;

  /// v0.4.6 §user-3: per-node winners + per-subscription suggestions and
  /// rung win-rate stats of the fragment AUTO ladder (shared by CoreManager
  /// and the subscriptions screen).
  late final FragmentLadderCache fragmentLadderCache;

  /// Cached in-process Clash API client for the LIVE engine (Android libbox
  /// path never creates `front.api`; see engineDelayTest above).
  ///
  /// v0.4.9 §testall-fix: the cache is VALIDATED — after a disconnect the
  /// listener dies, and a stale client made every node read as a REAL
  /// 'timeout' dead (the worst lie: engine-off at least falls through).
  static ClashApiClient? _liveClashApi;

  /// Returns a working Clash API client when a listener answers on the
  /// configured port, null otherwise (engine off → 'engine-off' results).
  static Future<ClashApiClient?> _probeAndBuildClashApi(AppDependencies deps) async {
    final client0 = _liveClashApi;
    if (client0 != null && await client0.isAlive()) return client0;
    _liveClashApi = null;
    final client = ClashApiClient(
        port: deps.cores.front.apiPort,
        secret: deps.cores.front.clashSecret);
    if (await client.isAlive()) {
      return _liveClashApi = client;
    }
    return null;
  }

  /// v0.5.0 §user-fix: PUBLIC instance wrapper over the probe-and-cache
  /// client — the ONE shared access point to the live engine's Clash API
  /// (:9097 on Android, where `front.api` is always null). VpnSession's
  /// ladder probes AND its migration fast path both route through this now;
  /// before, the migrate path read the always-null getter and every smart
  /// switch degraded to a full disconnect/reconnect cycle.
  Future<ClashApiClient?> liveEngineApi() => _probeAndBuildClashApi(this);
}

