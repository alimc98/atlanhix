import 'dart:async';

import '../../domain/entities/proxy_profile.dart';
import 'core_process.dart';

/// Engine-independent runtime lifecycle (Phase 1 contract).
abstract class CoreRuntime {
  CoreKind get coreKind;

  /// Write config files / allocate ports. Idempotent.
  Future<void> prepare();

  /// Engine-level validation (e.g. `sing-box check`, `xray run -test`).
  /// Must never leave a running process behind.
  Future<RuntimeValidation> validate();

  /// Start the engine. Resolves when the engine is accepting connections
  /// on its local inbound (readiness probe inside).
  Future<StartResult> start();

  Future<void> stop();
  Future<void> restart() async {
    await stop();
    await start();
  }

  RuntimeStatus get status;
  CoreExitEvent? get lastExit;

  /// Engine-measured delay for one upstream tag, when the engine supports it.
  Future<int?> testTag(String tag, {String url = _defaultTestUrl});
  Future<void> dispose();

  /// Health of the local inbound (TCP connect).
  Future<bool> inboundHealthy();

  /// Cumulative byte counters, when the engine exposes them.
  TrafficSnapshot? get traffic;
}

const _defaultTestUrl = 'https://www.gstatic.com/generate_204';

enum StartStatus { ok, binaryMissing, configInvalid, portConflict, failed }

class StartResult {
  const StartResult(this.status, {this.message, this.pid, this.startupMs});

  final StartStatus status;
  final String? message;
  final int? pid;
  final int? startupMs;

  bool get ok => status == StartStatus.ok;
}

class RuntimeValidation {
  const RuntimeValidation(this.ok, {this.message, this.output});

  final bool ok;
  final String? message;
  final String? output;
}

enum RuntimeStatus { idle, prepared, starting, running, stopping, stopped, crashed }

class TrafficSnapshot {
  const TrafficSnapshot({
    required this.upBytes,
    required this.downBytes,
  });

  final int upBytes;
  final int downBytes;
}

/// Shared helpers for runtimes.
mixin RuntimeLog on Object {
  Never _missing(String what) =>
      throw StateError('$runtimeType does not implement $what');
}
