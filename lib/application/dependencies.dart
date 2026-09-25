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

  static Future<AppDependencies> bootstrap() async {
    final deps = AppDependencies._();

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

    deps.profiles = ProfileRepository(deps.store, deps.vault);
    deps.subscriptions = SubscriptionRepository(deps.store);
    deps.chains = ChainRepository(deps.store);
    deps.routingRep = RoutingRepository(deps.store);
    deps.settings = SettingsRepository(deps.store);
    // v0.4.1: the REAL settings models (§7/§9) — persisted, runtime-honored.
    deps.appSettingsRepo = AppSettingsRepository(deps.store);
    deps.routingSettingsRepo = RoutingSettingsRepository(deps.store);

    await deps.profiles.load();
    await deps.subscriptions.load();
    await deps.chains.load();
    await deps.routingRep.load();
    await deps.appSettingsRepo.load();
    await deps.routingSettingsRepo.load();
    deps.appSettings = deps.appSettingsRepo.current;
    deps.routingSettings = deps.routingSettingsRepo.current;
    deps.configBridge = RuntimeConfigBridge(
      settings: deps.appSettings,
      routing: deps.routingSettings,
    );

    deps.binaryManager = BinaryManager(
      // TODO(v0.3): read from Settings â†’ Cores (user override dir).
      appDir: Directory(
          '${Directory.current.path}${Platform.pathSeparator}cores'
          '${Platform.pathSeparator}${BinaryManager.platformDirName()}'),
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
      ..updateProfiles(deps.profiles.all)
      ..start();
    deps.profiles.changes.listen(deps.scheduler.updateProfiles);
    // v0.4.9 §user: REAL delay tester — the node list's test button and the
    // background sweep measure the END-TO-END URL delay through each node's
    // live outbound (engine delay test), never a bare TCP ping. Wired to the
    // front engine's Clash API; engine-off → honest null result.
    deps.realDelay = RealDelayTester(tester: deps.tester)
      ..probeUrl = 'https://www.gstatic.com/generate_204'
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
      ..transientBatchTest = (batch) async {
        // v0.4.9 §testall-fix: the sweep calls this per chunk of 6. The old
        // flow restarted the probe Box whenever the chunk's set differed
        // from the loaded one — every in-flight delay test died mid-sweep
        // (two "probe engine UP" lines one second apart in the device log)
        // and the WHOLE list painted ×. The engine now GROWS its union
        // (no restart when up), and this loop re-checks the table per node:
        // a node absent from the running config (dropped Xray node after a
        // failed child boot, or a grown-in tag that has not landed yet) is
        // answered honestly ('engine-off') instead of a fake 5 s timeout.
        final api = await ProbeEngine.instance.ensureUp(batch);
        if (api == null) return const {};
        final out = <String, ProbeResult>{};
        for (final p in batch) {
          final tag = '${SingBoxRuntime.tagPrefix}${p.id}';
          final tags = await api.proxyTags();
          if (tags == null || !tags.contains(tag)) {
            out[p.id] = ProbeResult(
                ok: false,
                latencyMs: null,
                errorKind: 'engine-off',
                detail: 'not in probe config');
            continue;
          }
          final ms = await api.delayTest(
              tag,
              deps.realDelay.probeUrl,
              5000);
          out[p.id] = ms == null
              ? ProbeResult(
                  ok: false,
                  latencyMs: null,
                  errorKind: 'timeout',
                  detail: 'probe engine: no answer within 5s')
              : ProbeResult(ok: true, latencyMs: ms);
        }
        return out;
      };
    deps.detector = CoreDetector();
    deps.importer = MultiFormatImporter();

    // v0.4 BUGFIX (Android device run): warpRepo must be initialized BEFORE
    // ConnectionController reads it — `late final` access during construction
    // threw LateInitializationError and killed bootstrap (white screen).
    deps.warpRepo = WarpRepository(deps.store, deps.vault);
    await deps.warpRepo.load();
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
    // v0.4.9 §boot-speed ("سرعت بوت شدن برنامه کند است"): reconcile runs
    // WITHOUT blocking bootstrap. The native state read races the
    // platform-channel handshake and this await sat between repository
    // load and the first paint — while the shell itself re-syncs from
    // vpnSession.uiPhase on every build anyway. A stale CONNECTED pill
    // self-corrects a frame later; a blank shell for 300+ ms every open
    // was the worse trade.
    unawaited(deps.vpnSession.controller.reconcileWithNative().catchError((_) {}));

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
    if (kDebugMode) {
      // ignore: avoid_print
      print('Atlanhix bootstrap complete: ${deps.profiles.all.length} profiles');
    }
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
}

