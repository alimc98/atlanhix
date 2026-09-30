// Re-exports so the main test files import one helper module.
export 'package:nexus/core/core_detector.dart'
    show CoreDetector, CoreKind, CoreBinaryKind;
export 'package:nexus/core/health/latency_tester.dart' show LatencyTester;
export 'package:nexus/core/health/test_scheduler.dart' show HealthStore;
export 'package:nexus/data/app_storage.dart' show JsonStore;
export 'package:nexus/data/profile_repository.dart' show ProfileRepository;
export 'package:nexus/data/secure_vault.dart' show InMemoryVault;
export 'package:nexus/domain/entities/proxy_profile.dart';
export 'package:nexus/routing/routing_models.dart';
export 'package:nexus/settings/routing_settings.dart';
export 'package:nexus/settings/app_settings.dart' show RoutingMode;
export 'package:nexus/core/health/test_scheduler.dart' show HealthStore;
export 'package:nexus/settings/runtime_config_bridge.dart';
export 'package:nexus/core/configgen/xray_config_generator.dart';
export 'package:nexus/core/configgen/singbox_config_generator.dart';
export 'package:nexus/core/runtime/binary_manager.dart';
export 'package:nexus/core/runtime/core_manager.dart';
export 'package:nexus/core/runtime/core_process.dart';
export 'package:nexus/core/runtime/core_runtime.dart';
export 'package:nexus/application/connection_controller.dart';

import 'dart:io';

import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/core/runtime/core_runtime.dart';
import 'package:nexus/data/app_storage.dart';
import 'package:nexus/data/profile_repository.dart';
import 'package:nexus/data/secure_vault.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/health/test_scheduler.dart' show HealthStore;
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/routing_models.dart';
import 'package:nexus/application/connection_controller.dart';

/// A node that CoreDetector/sing-box genuinely runs (hysteria2 + tls), so the
/// generated config contains a REAL hysteria2 outbound — no fakes.
ProxyProfile makeRunnableNode() => ProxyProfile(
      id: 'optin-node',
      name: 'opt-in test node',
      server: 'node.example.com',
      port: 443,
      protocol: ProxyProtocol.hysteria2,
      security: Security.tls,
      password: '[REDACTED]',
    );

/// Minimal binary manager: config generation never launches processes, but
/// CoreManager construction requires the object. inspect() reports a
/// not-available binary (config generation itself never inspects).
class StubBinaryManager extends BinaryManager {
  StubBinaryManager();

  @override
  Future<CoreBinaryInfo> inspect(CoreBinaryKind kind) async =>
      const CoreBinaryInfo(
        kind: CoreBinaryKind.singbox,
        status: 'not-found',
      );
}

/// Real ProfileRepository over a temp store — honest, no mocks.
Future<ProfileRepository> realProfileRepository() async {
  final dir = await Directory.systemTemp.createTemp('nexus_optin_repo');
  final store = JsonStore(directory: dir, schemaVersion: 1);
  await store.load();
  return ProfileRepository(store, InMemoryVault());
}

/// A ConnectionController with real dependencies — used to prove its default
/// routing profile is rule-less (opt-in) rather than a builtin profile.
Future<ConnectionController> makeController() async {
  final cores = CoreManager(
    binaryManager: StubBinaryManager(),
    workDir: await Directory.systemTemp.createTemp('nexus_optin_cores'),
  );
  await cores.prepare();
  return ConnectionController(
    repository: await realProfileRepository(),
    healthStore: HealthStore(),
    tester: LatencyTester(),
    detector: CoreDetector(),
    cores: cores,
  );
}

/// Real RoutingProfile factory for tests that need an enabled-style profile.
RoutingProfile enabledProfileForTest() => RoutingProfile(
      id: 'test-enabled',
      name: 'Enabled routing',
      rules: const [],
    );
