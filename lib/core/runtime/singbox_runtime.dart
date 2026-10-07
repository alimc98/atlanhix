import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../configgen/singbox_config_generator.dart';
import '../../routing/routing_models.dart';
import '../../domain/entities/proxy_profile.dart';
import '../logger.dart';
import 'binary_manager.dart';
import 'clash_api_client.dart';
import 'core_process.dart';
import 'core_runtime.dart';

/// Real sing-box process supervision (Phases 1/4/5/24/26).
///
/// Pipeline: profiles → generator → `sing-box check` → `sing-box run` →
/// readiness (mixed inbound TCP + Clash API) → hot switching via selector →
/// traffic via /connections.
class SingBoxRuntime implements CoreRuntime {
  SingBoxRuntime({
    required this.binaryManager,
    required this.workDir,
    this.enableTun = false,
    String? clashSecret,
  }) : clashSecret = clashSecret ?? Ids.randomHex(12);

  final BinaryManager binaryManager;
  final Directory workDir;
  final bool enableTun;
  final String clashSecret;

  CoreBinaryInfo? _binary;
  ManagedProcess? _process;
  ClashApiClient? _api;
  int _mixedPort = 2080;

  /// v0.4.4 §user-4: local mixed port preference (settings.localPort). On
  /// Android this IS the final port (libbox uses the config as written);
  /// desktop still negotiates a free one from this preference.
  int get mixedPortPreference => _mixedPort;
  set mixedPortPreference(int p) {
    if (p >= 1 && p <= 65535) _mixedPort = p;
  }

  /// v0.4.4 §user-5: proxy mode = build WITHOUT the tun inbound.
  bool tunEnabled = true;

  /// v0.4.4 mockup pill: TLS fragmentation preference (settings-driven).
  bool tlsFragment = false;
  int _apiPort = 9097;
  File? _configFile;
  RuntimeStatus _status = RuntimeStatus.idle;
  CoreExitEvent? _lastExit;
  TrafficSnapshot? _traffic;
  Timer? _trafficTimer;
  StreamController<CoreExitEvent>? _exitEvents;
  final _stderrRing = <String>[];

  /// v0.5.6 §leak-fix: held so [collectLogs] can cancel the previous pair
  /// (see [_disposeLogSubs]).
  StreamSubscription<String>? _stderrSub;
  StreamSubscription<String>? _stdoutSub;

  Stream<CoreExitEvent> get onExit =>
      (_exitEvents ??= StreamController<CoreExitEvent>.broadcast()).stream;

  int get mixedPort => _mixedPort;
  int get apiPort => _apiPort;
  ClashApiClient? get api => _api;
  static const selectorTag = 'proxy';
  static const tagPrefix = 'node:';

  @override
  CoreKind get coreKind => CoreKind.singbox;

  @override
  RuntimeStatus get status => _status;

  @override
  CoreExitEvent? get lastExit => _lastExit;

  @override
  TrafficSnapshot? get traffic => _traffic;

  int? get lastPid => _process?.pid;

  @override
  Future<void> prepare() async {
    await workDir.create(recursive: true);
    _mixedPort = await PortAllocator.freePort(prefer: _mixedPort);
    _apiPort = await PortAllocator.freePort(prefer: 9097);
    _binary = await binaryManager.inspect(CoreBinaryKind.singbox);
    if (_binary!.status != 'available') {
      Logger.instance.warn('runtime',
          'sing-box binary ${_binary!.status} (${_binary!.path ?? 'not found'})');
    }
    _status = RuntimeStatus.prepared;
  }

  Map<String, dynamic> buildConfig(
    List<ProxyProfile> profiles, {
    required String selectedProfileId,
    required RoutingProfile routing,
    required DnsSettings dns,
    Map<String, ({String host, int port})> socksUpstreams = const {},
    ProxyProfile? warpProfile,
    bool chainWarpOutside = true,
    String? selectedWarpTag,
    List<String> bypassCidrs = const [],
  }) {
    return SingBoxConfigGenerator().generate(
      runnableProfiles: profiles,
      routing: routing,
      dns: dns,
      options: SingBoxOptions(
        mixedPort: _mixedPort,
        clashApiPort: _apiPort,
        clashApiSecret: clashSecret,
        enableTun: enableTun && tunEnabled,
        tlsFragment: tlsFragment,
      ),
      selectedTag: '$tagPrefix$selectedProfileId',
      socksUpstreams: socksUpstreams,
      warpProfile: warpProfile,
      chainWarpOutside: chainWarpOutside,
      selectedWarpTag: selectedWarpTag,
      bypassCidrs: bypassCidrs,
    );
  }

  Future<RuntimeValidation> validateAll({
    required List<ProxyProfile> profiles,
    required String selectedProfileId,
    required RoutingProfile routing,
    required DnsSettings dns,
    Map<String, ({String host, int port})> socksUpstreams = const {},
    ProxyProfile? warpProfile,
    bool chainWarpOutside = true,
  }) async {
    if (_binary == null || _binary!.status != 'available') {
      _binary = await binaryManager.inspect(CoreBinaryKind.singbox);
    }
    final b = _binary!;
    if (b.status != 'available') {
      return RuntimeValidation(false,
          message: 'sing-box engine is ${b.status}');
    }
    final cfg = buildConfig(profiles,
        selectedProfileId: selectedProfileId,
        routing: routing,
        dns: dns,
        socksUpstreams: socksUpstreams,
        warpProfile: warpProfile,
        chainWarpOutside: chainWarpOutside);
    final f = await _writeConfig(cfg);
    try {
      final r = await Process.run(b.path!, ['check', '-c', f.path],
              stdoutEncoding: utf8, stderrEncoding: utf8)
          .timeout(const Duration(seconds: 20));
      final ok = r.exitCode == 0;
      final out = '${r.stdout}${r.stderr}';
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
      return RuntimeValidation(ok,
          message: ok ? 'config valid' : _friendly(out), output: out);
    } catch (e) {
      return RuntimeValidation(false, message: 'validation failed: $e');
    }
  }

  /// Generates, validates and starts with all [profiles] loaded so selector
  /// hot-switching can swap between them without a restart.
  /// [socksUpstreams]: local SOCKS endpoints of external engines (Xray/MDVPN).
  /// [warpProfile]: materializes the WARP WireGuard endpoint for traffic
  /// chaining (v0.3.0 §8) — traffic flows through WARP per [chainWarpOutside].
  Future<StartResult> startWith({
    required List<ProxyProfile> profiles,
    required String selectedProfileId,
    required RoutingProfile routing,
    required DnsSettings dns,
    Map<String, ({String host, int port})> socksUpstreams = const {},
    ProxyProfile? warpProfile,
    bool chainWarpOutside = true,
  }) async {
    final sw = Stopwatch()..start();
    final validation = await validateAll(
        profiles: profiles,
        selectedProfileId: selectedProfileId,
        routing: routing,
        dns: dns,
        socksUpstreams: socksUpstreams,
        warpProfile: warpProfile,
        chainWarpOutside: chainWarpOutside);
    if (!validation.ok) {
      _status = RuntimeStatus.stopped;
      final detail = (validation.output ?? '')
          .split('\n')
          .where((l) => l.contains('ERROR') || l.contains('FATAL'))
          .take(2)
          .join(' | ');
      return StartResult(StartStatus.configInvalid,
          message: detail.isEmpty
              ? validation.message
              : '${validation.message} — $detail');
    }
    final cfg = buildConfig(profiles,
        selectedProfileId: selectedProfileId,
        routing: routing,
        dns: dns,
        socksUpstreams: socksUpstreams,
        warpProfile: warpProfile,
        chainWarpOutside: chainWarpOutside);
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
    collectLogs();

    // Exit watcher (Phase 26).
    unawaited(_process!.onExit.then((code) {
      _trafficTimer?.cancel();
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

    final ready = await _waitReady(timeout: const Duration(seconds: 15));
    if (!ready) {
      final tail = _stderrTail();
      await stop();
      final kind = classifyExit(-1, tail, sw.elapsed);
      return StartResult(
        kind == CoreExitKind.portConflict
            ? StartStatus.portConflict
            : StartStatus.failed,
        message: tail.isEmpty
            ? 'engine did not become ready (no stderr output; '
                'stdout tail: ${_stdoutTail()}'
            : tail,
        startupMs: sw.elapsedMilliseconds,
      );
    }
    _status = RuntimeStatus.running;
    _startTrafficPolling();
    return StartResult(StartStatus.ok,
        pid: _process!.pid, startupMs: sw.elapsedMilliseconds);
  }

  @override
  Future<StartResult> start() => startWith(
        profiles: const [],
        selectedProfileId: '',
        routing: RoutingProfile(id: 'empty', name: 'empty', rules: const []),
        dns: DnsSettings(mode: DnsMode.automatic),
      );

  Future<bool> _waitReady({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_process?.isRunning != true) return false;
      final api = _api ??= ClashApiClient(port: _apiPort, secret: clashSecret);
      if (await api.isAlive()) {
        try {
          final s = await Socket.connect(
              InternetAddress.loopbackIPv4, _mixedPort,
              timeout: const Duration(milliseconds: 500));
          s.destroy();
          return true;
        } catch (_) {/* keep polling */}
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }

  void _startTrafficPolling() {
    _trafficTimer?.cancel();
    // v0.3.2: seed the counters immediately instead of waiting for the first
    // 1 s tick — the E2E probe (sub-second) used to read null and crash on
    // the traffic-delta assertion.
    Future<void>.microtask(() async {
      final t0 = await (_api?.connections() ?? Future.value(null));
      if (t0 != null) _traffic = t0;
    });
    _trafficTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final t = await (_api?.connections() ?? Future.value(null));
      if (t != null) _traffic = t;
    });
  }

  String _stderrTail() => _stderrRing.take(12).join('\n');

  /// v0.4.6: recent stderr lines for ProbeError surfacing (read-only copy;
  /// the ring itself is only written by the log collector).
  List<String> debugStderrTail() => List.unmodifiable(_stderrRing);

  final _stdoutRing = <String>[];

  String _stdoutTail() => _stdoutRing.take(6).join(' | ');

  /// Attach log collection (call once after start).
  void collectLogs() {
    final p = _process;
    if (p == null) return;
    // v0.5.6 §leak-fix: cancel the previous pair. `collectLogs()` runs on
    // every connect AND on every fragment-ladder AUTO rung (up to 4× per
    // connect); the subscriptions used to be discarded, so each run left a
    // live pair retaining the ManagedProcess, its controllers and — via the
    // closure's capture of `this` — the whole runtime.
    _disposeLogSubs();
    _stderrRing.clear();
    _stdoutRing.clear();
    _stderrSub = p.stderrStream.listen((line) {
      _stderrRing.add(line);
      if (_stderrRing.length > 40) _stderrRing.removeAt(0);
      Logger.instance.debug('sing-box', line);
    });
    _stdoutSub = p.stdoutStream.listen((line) {
      _stdoutRing.add(line);
      if (_stdoutRing.length > 40) _stdoutRing.removeAt(0);
      Logger.instance.debug('sing-box', line);
    });
  }

  /// Release the stderr/stdout collectors. Safe to call repeatedly.
  void _disposeLogSubs() {
    _stderrSub?.cancel();
    _stdoutSub?.cancel();
    _stderrSub = null;
    _stdoutSub = null;
  }

  /// Phase 5: hot switch inside the running selector — no restart.
  Future<bool> switchToProfile(ProxyProfile p) async {
    final tag = '$tagPrefix${p.id}';
    final api = _api;
    if (_status != RuntimeStatus.running || api == null) return false;
    final ok = await api.select(selectorTag, tag);
    if (ok) {
      final now = await api.selectedOf(selectorTag);
      Logger.instance
          .info('runtime', 'switch → ${p.name} (active=$now, wanted=$tag)');
    }
    return ok;
  }

  @override
  Future<int?> testTag(String tag, {String url = _defaultTestUrl}) async =>
      _api?.delayTest(tag, url, 5000);

  @override
  Future<RuntimeValidation> validate() async {
    // Full config validation ran during startWith; re-check engine presence.
    final b = _binary ?? await binaryManager.inspect(CoreBinaryKind.singbox);
    return RuntimeValidation(b.status == 'available',
        message: b.status == 'available'
            ? 'engine available (${b.version})'
            : 'engine is ${b.status}');
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
          InternetAddress.loopbackIPv4, _mixedPort,
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
    _trafficTimer?.cancel();
    // v0.5.6 §leak-fix: drop the log collectors before the process dies.
    _disposeLogSubs();
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
    _api?.dispose();
    await _exitEvents?.close();
    _trafficTimer?.cancel();
  }

  Future<File> _writeConfig(Map<String, dynamic> cfg) async {
    await workDir.create(recursive: true);
    final f = File(
        '${workDir.path}${Platform.pathSeparator}singbox-runtime-${Ids.randomHex(4)}.json');
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(cfg),
        flush: true);
    return f;
  }

  static const _defaultTestUrl = 'https://www.gstatic.com/generate_204';

  static String _friendly(String engineOutput) {
    final o = engineOutput.toLowerCase();
    if (o.contains('unknown field') || o.contains('decode')) {
      return 'Configuration contains fields this sing-box version does not understand.';
    }
    if (o.contains('address already in use') || o.contains('bind')) {
      return 'Local port is already in use by another application.';
    }
    return 'sing-box rejected the configuration.';
  }
}
