import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nexus/core/engine_availability.dart';
import 'package:nexus/core/logger.dart';

import 'binary_manager.dart';
import 'clash_api_client.dart';
import 'core_process.dart';
import 'core_runtime.dart';

/// v0.5.3 — the MIHOMO (Clash.Meta) runtime: the standalone third engine.
///
/// Shape: a managed CHILD PROCESS (`mihomo -d <workdir> -f config.json`),
/// exactly like the :xray daemon — never an in-process gomobile AAR (two
/// go runtimes in one process re-fight the go.Seq init, the same wall that
/// banned libv2ray next to libbox). Readiness is detected by POLLING THE
/// ENGINE'S OWN CLASH API (`GET /version`) — the same dialect the app's
/// RealDelayTester / SmartSwitch / migration code already speaks, so once
/// up, delay tests, node switching and traffic counters work with ZERO new
/// client code.
class MihomoRuntime {
  MihomoRuntime({
    required this.binaryManager,
    required this.workDir,
    this.mixedPort = 2080,
    this.apiPort = 9097,
    String? apiSecret,
  }) : apiSecret = apiSecret ?? '';

  final BinaryManager binaryManager;
  final Directory workDir;

  /// Mixed (HTTP+SOCKS) inbound the FRONT engine (or the OS proxy) dials.
  final int mixedPort;

  /// mihomo's native external-controller — the app's Clash API endpoint.
  final int apiPort;
  final String apiSecret;

  CoreBinaryInfo? _binary;
  ManagedProcess? _process;
  File? _configFile;
  RuntimeStatus _status = RuntimeStatus.idle;
  CoreExitEvent? _lastExit;
  StreamController<CoreExitEvent>? _exitEvents;
  final _stderrRing = <String>[];

  RuntimeStatus get status => _status;
  int? get lastPid => _process?.pid;
  CoreExitEvent? get lastExit => _lastExit;
  Stream<CoreExitEvent> get onExit =>
      (_exitEvents ??= StreamController<CoreExitEvent>.broadcast()).stream;

  /// Cached API client while the engine is up (re-created per start).
  ClashApiClient? _api;

  /// Live API client — null when not running. The SmartSwitch/delay-test
  /// path consumes this exactly like `cores.front.api` / :xray's client.
  ClashApiClient? get api => _status == RuntimeStatus.running ? _api : null;

  bool get isAvailable => _binary?.status == 'available';

  /// One-time binary discovery + version probe (boot-time).
  Future<void> prepare() async {
    await workDir.create(recursive: true);
    _binary = await binaryManager.inspect(CoreBinaryKind.mihomo);
    if (_binary!.status == 'available') {
      MihomoCoreState.instance.setRuntimeLoaded(true);
      Logger.instance.info('runtime',
          'mihomo ready: ${_binary!.path} v${_binary!.version}');
    } else {
      Logger.instance.info('runtime',
          'mihomo: ${_binary!.status} (${_binary!.path ?? 'not found'}) — '
          'engine disabled this run');
    }
  }

  /// Write the config the generator produced and START the engine.
  /// Returns ok + the API client on success.
  Future<StartResult> startWithConfig(Map<String, dynamic> config) async {
    final sw = Stopwatch()..start();
    _binary ??= await binaryManager.inspect(CoreBinaryKind.mihomo);
    final b = _binary!;
    if (b.status != 'available') {
      return StartResult(StartStatus.binaryMissing,
          message: 'mihomo engine is ${b.status}. See Settings → Cores.');
    }
    await workDir.create(recursive: true);
    _configFile =
        File('${workDir.path}${Platform.pathSeparator}mihomo_config.json');
    await _configFile!.writeAsString(jsonEncode(config), flush: true);

    _status = RuntimeStatus.starting;
    try {
      _process = await ManagedProcess.start(
        b.path!,
        ['-d', workDir.path, '-f', _configFile!.path],
      );
    } catch (e) {
      _status = RuntimeStatus.stopped;
      return StartResult(StartStatus.failed, message: 'failed to launch: $e');
    }
    _collectLogs();
    unawaited(_process!.onExit.then((code) {
      final tail = _stderrTail();
      final kind = classifyExit(code, tail, sw.elapsed);
      _lastExit = CoreExitEvent(
          kind: kind, exitCode: code, stderrTail: tail, uptime: sw.elapsed);
      if (_status == RuntimeStatus.running ||
          _status == RuntimeStatus.starting) {
        _status = RuntimeStatus.crashed;
        _exitEvents?.add(_lastExit!);
      }
      _api = null;
    }));

    final ready = await _waitApiReady(timeout: const Duration(seconds: 15));
    if (!ready) {
      final tail = _stderrTail();
      await stop();
      return StartResult(StartStatus.failed,
          message: 'mihomo API did not come up — ${tail.isEmpty ? _stdoutTail() : tail}');
    }
    _status = RuntimeStatus.running;
    _api = ClashApiClient(port: apiPort, secret: apiSecret);
    return StartResult(StartStatus.ok,
        pid: _process!.pid, startupMs: sw.elapsedMilliseconds);
  }

  /// Poll `GET /version` until the external controller answers.
  Future<bool> _waitApiReady({required Duration timeout}) async {
    final probe = ClashApiClient(port: apiPort, secret: apiSecret);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_process == null || !_process!.isRunning) return false;
      try {
        if (await probe.isAlive()) return true;
      } catch (_) {/* not up yet */}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<void> stop() async {
    final p = _process;
    _process = null;
    _api = null;
    if (p == null) {
      _status = RuntimeStatus.stopped;
      return;
    }
    try {
      await p.stop();
    } catch (_) {}
    _status = RuntimeStatus.stopped;
  }

  void _collectLogs() {
    _process!.stdoutStream.listen((l) {}, onDone: () {});
    _process!.stderrStream.listen((l) {
      _stderrRing.add(l);
      if (_stderrRing.length > 50) _stderrRing.removeAt(0);
    }, onDone: () {});
  }

  String _stderrTail() => _stderrRing.join('\n').trim();

  String _stdoutTail() => '';
}
