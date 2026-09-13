import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../data/app_storage.dart';
import '../data/profile_repository.dart';
import '../data/repositories.dart';
import '../data/secure_vault.dart';
import '../application/connection_controller.dart';
import '../application/subscription_service.dart';
import '../core/core_detector.dart';
import '../core/health/latency_tester.dart';
import '../core/health/test_scheduler.dart';
import '../core/runtime/binary_manager.dart';
import '../core/runtime/core_manager.dart';
import '../protocols/importer.dart';
import '../routing/builtin_profiles.dart';
import '../settings/app_settings.dart';
import '../settings/routing_settings.dart';
import '../settings/runtime_config_bridge.dart';
import '../settings/vpn_session.dart';
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
    deps.scheduler = TestScheduler(tester: deps.tester, store: deps.healthStore);
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
    );

    // v0.4.1 §2 — the Android VPN session owns the platform-channel
    // controller; Connect on Android routes through it, never the
    // desktop core path.
    deps.vpnSession = VpnSession(deps: deps);

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
  late final ConnectionController connection;
  late final SubscriptionService subscriptionService;
  late final WarpRepository warpRepo;
  late final WarpService warpService;
}

