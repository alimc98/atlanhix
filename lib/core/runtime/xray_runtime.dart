import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core_detector.dart';
import '../configgen/xray_config_generator.dart';
import '../fragmentation/fragment_profiles.dart';
import '../../routing/routing_models.dart';
import '../../domain/entities/proxy_profile.dart';
import '../logger.dart';
import '../primitives.dart';
import 'binary_manager.dart';
import 'core_process.dart';
import 'core_runtime.dart';

/// Real Xray process supervision (Phase 3).
///
/// Pipeline: profile → XrayConfigGenerator → write temp config →
/// `xray run -test -c <cfg>` → `xray run -c <cfg>` → readiness probe
/// (SOCKS inbound TCP). Xray has no runtime control API, so switching
/// profiles restarts this process (Phase 5 policy).
class XrayRuntime implements CoreRuntime {
  XrayRuntime({
    required this.binaryManager,
    required this.workDir,
    int preferredPort = 2081,
    this.fragment,
  }) : _preferredPort = preferredPort;

  final BinaryManager binaryManager;
  final Directory workDir;
  final int _preferredPort;

  /// When non-null, fragmentation is injected into the generated config
  /// (Phase 21 — caller decides eligibility; see FragmentationEngine).
  FragmentProfile? fragment;

  CoreBinaryInfo? _binary;
  ManagedProcess? _process;
  int _localPort = 2081;
  File? _configFile;
  RuntimeStatus _status = RuntimeStatus.idle;
  CoreExitEvent? _lastExit;
  ProxyProfile? _profile;
  RoutingProfile _routing =
      RoutingProfile(id: 'empty', name: 'empty', rules: const []);
  StreamController<CoreExitEvent>? _exitEvents;
  final _stderrRing = <String>[];

  Stream<CoreExitEvent> get onExit =>
      (_exitEvents ??= StreamController<CoreExitEvent>.broadcast()).stream;

  int get localPort => _localPort;
  ProxyProfile? get currentProfile => _profile;

  @override
  CoreKind get coreKind => CoreKind.xray;

  @override
  RuntimeStatus get status => _status;

  @override
  CoreExitEvent? get lastExit => _lastExit;

  @override
  TrafficSnapshot? get traffic => null; // Xray stats API: future milestone

  @override
  Future<void> prepare() async {
    await workDir.create(recursive: true);
    _localPort = await PortAllocator.freePort(prefer: _preferredPort);
    _binary = await binaryManager.inspect(CoreBinaryKind.xray);
    _status = RuntimeStatus.prepared;
  }

  Map<String, dynamic> buildConfig(
      {required ProxyProfile profile, required RoutingProfile routing}) {
    return XrayConfigGenerator().generate(
      profile: profile,
      localSocksPort: _localPort,
      routing: routing,
      fragment: fragment,
    );
  }

  /// Writes the config and runs `xray run -test -c <cfg>` (Phase 3 gate:
  /// never start an invalid config).
  Future<RuntimeValidation> validateProfile({
    required ProxyProfile profile,
    required RoutingProfile routing,
  }) async {
    if (_binary == null || _binary!.status != 'available') {
      _binary = await binaryManager.inspect(CoreBinaryKind.xray);
    }
    final b = _binary!;
    if (b.status != 'available') {
      return RuntimeValidation(false, message: 'xray engine is ${b.status}');
    }
    final cfg = buildConfig(profile: profile, routing: routing);
    final f = await _writeConfig(cfg);
    try {
      final r = await Process.run(b.path!, ['run', '-test', '-c', f.path],
              stdoutEncoding: utf8, stderrEncoding: utf8)
          .timeout(const Duration(seconds: 20));
      final ok = r.exitCode == 0;
      final out = '${r.stdout}${r.stderr}';
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
      return RuntimeValidation(ok,
          message: ok
              ? 'config valid'
              : 'Xray rejected the configuration. '
                  'Check this node\'s parameters in the advanced view.',
          output: out);
    } catch (e) {
      return RuntimeValidation(false, message: 'validation failed: $e');
    }
  }

  /// Starts Xray for [profile]. Config must have passed [validateProfile].
  Future<StartResult> startProfile({
    required ProxyProfile profile,
    required RoutingProfile routing,
  }) async {
    final sw = Stopwatch()..start();
    _profile = profile;
    _routing = routing;
    final cfg = buildConfig(profile: profile, routing: routing);
    _configFile = await _writeConfig(cfg);
    final b = _binary!;
    _status = RuntimeStatus.starting;
    try {
      _process =
          await ManagedProcess.start(b.path!, ['run', '-c', _configFile!.path]);
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
    }));

    final ready = await _waitReady(timeout: const Duration(seconds: 8));
    if (!ready) {
      final tail = _stderrTail();
      await stop();
      return StartResult(
        StartStatus.failed,
        message: tail.isEmpty ? 'engine did not become ready' : tail,
        startupMs: sw.elapsedMilliseconds,
      );
    }
    _status = RuntimeStatus.running;
    return StartResult(StartStatus.ok,
        pid: _process!.pid, startupMs: sw.elapsedMilliseconds);
  }

  @override
  Future<StartResult> start() async {
    final p = _profile;
    if (p == null) {
      return StartResult(StartStatus.failed,
          message: 'no profile bound to XrayRuntime');
    }
    return startProfile(profile: p, routing: _routing);
  }

  Future<bool> _waitReady({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_process?.isRunning != true) return false;
      try {
        final s = await Socket.connect(
            InternetAddress.loopbackIPv4, _localPort,
            timeout: const Duration(milliseconds: 500));
        s.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    return false;
  }

  void _collectLogs() {
    final p = _process;
    if (p == null) return;
    _stderrRing.clear();
    p.stderrStream.listen((line) {
      _stderrRing.add(line);
      if (_stderrRing.length > 40) _stderrRing.removeAt(0);
      Logger.instance.debug('xray', line);
    });
    p.stdoutStream.listen((line) => Logger.instance.debug('xray', line));
  }

  String _stderrTail() => _stderrRing.take(12).join('\n');

  @override
  Future<int?> testTag(String tag, {String url = _defaultTestUrl}) async =>
      null; // no engine-side delay API; probes run through the inbound

  @override
  Future<RuntimeValidation> validate() async {
    final p = _profile;
    if (p == null) {
      return RuntimeValidation(false, message: 'no profile bound');
    }
    return validateProfile(profile: p, routing: _routing);
  }

  @override
  Future<void> restart() async {
    await stop();
    await start();
  }

  @override
  Future<bool> inboundHealthy() async {
    try {
      final s = await Socket.connect(
          InternetAddress.loopbackIPv4, _localPort,
          timeout: const Duration(milliseconds: 600));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    _status = RuntimeStatus.stopping;
    final p = _process;
    _process = null;
    if (p != null) await p.stop();
    try {
      if (_configFile != null && await _configFile!.exists()) {
        await _configFile!.delete();
      }
    } catch (_) {}
    _configFile = null;
    _status = RuntimeStatus.stopped;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _exitEvents?.close();
  }

  Future<File> _writeConfig(Map<String, dynamic> cfg) async {
    await workDir.create(recursive: true);
    final f = File(
        '${workDir.path}${Platform.pathSeparator}xray-runtime-${Ids.randomHex(4)}.json');
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(cfg),
        flush: true);
    return f;
  }

  static const _defaultTestUrl = 'https://www.gstatic.com/generate_204';
}
