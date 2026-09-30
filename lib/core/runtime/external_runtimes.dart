import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../domain/entities/proxy_profile.dart';
import '../logger.dart';
import 'binary_manager.dart';
import 'core_process.dart';
import 'core_runtime.dart';

/// Base for engines that run as external daemons with a config file
/// (AmneziaWG-Go, MasterDNSVPN client). Lifecycle: detect binary →
/// write config → launch → readiness probe → supervise.
abstract class ExternalDaemonRuntime implements CoreRuntime {
  ExternalDaemonRuntime({
    required this.binaryManager,
    required this.workDir,
  });

  final BinaryManager binaryManager;
  final Directory workDir;

  CoreBinaryKind get binaryKind;
  List<String> launchArgs(File configFile);
  String configFileName();
  Map<String, dynamic> buildConfig();
  Duration get readinessTimeout => const Duration(seconds: 6);

  /// Probe that returns true when the daemon is serving.
  Future<bool> probe();

  CoreBinaryInfo? _binary;
  ManagedProcess? _process;
  File? _configFile;
  RuntimeStatus _status = RuntimeStatus.idle;
  CoreExitEvent? _lastExit;
  final List<String> _stderrRing = <String>[];
  StreamController<CoreExitEvent>? _exitEvents;

  /// v0.5.6 §leak-fix: held so the collectors can be cancelled. See
  /// [_disposeLogSubs].
  StreamSubscription<String>? _stderrSub;
  StreamSubscription<String>? _stdoutSub;

  Stream<CoreExitEvent> get onExit =>
      (_exitEvents ??= StreamController<CoreExitEvent>.broadcast()).stream;

  @override
  RuntimeStatus get status => _status;

  @override
  CoreExitEvent? get lastExit => _lastExit;

  CoreBinaryInfo? get binaryInfo => _binary;

  /// Subclass hook: write auxiliary files the daemon requires next to its
  /// config (e.g. MasterDNSVPN's resolvers file). No-op by default.
  Future<void> prepareSidecars() async {}

  /// PID of the daemon process while running (diagnostics §19); null when
  /// stopped. [ManagedProcess] PID is OS-real, never synthesized.
  int? get lastPid => _process?.pid;

  @override
  Future<void> prepare() async {
    await workDir.create(recursive: true);
    _binary = await binaryManager.inspect(binaryKind);
    if (_binary!.status == 'available') {
      _status = RuntimeStatus.prepared;
    } else {
      _status = RuntimeStatus.idle;
      Logger.instance.info('runtime', '${binaryKind.name}: ${_binary!.status}');
    }
  }

  bool get isAvailable => _binary?.status == 'available';

  Future<File> writeConfig() async {
    await workDir.create(recursive: true);
    final f =
        File('${workDir.path}${Platform.pathSeparator}${configFileName()}');
    final text = _configText();
    if (text != null) {
      await f.writeAsString(text, flush: true);
    } else {
      await f.writeAsString(
          const JsonEncoder.withIndent('  ').convert(buildConfig()),
          flush: true);
    }
    return f;
  }

  /// Override for text configs (TOML/INI). Null → JSON of buildConfig().
  String? _configText() => null;

  @override
  Future<StartResult> start() async {
    if (!isAvailable) {
      _binary = await binaryManager.inspect(binaryKind);
      if (!isAvailable) {
        return StartResult(StartStatus.binaryMissing,
            message: '${binaryKind.name} engine is not installed. See BUILD.md.');
      }
    }
    final sw = Stopwatch()..start();
    _configFile = await writeConfig();
    // Subclass hook (e.g. MasterDNSVPN needs a resolvers file sidecar).
    await prepareSidecars();
    _status = RuntimeStatus.starting;
    try {
      _process =
          await ManagedProcess.start(_binary!.path!, launchArgs(_configFile!));
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

    final deadline = DateTime.now().add(readinessTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_process?.isRunning != true) break;
      if (await probe()) {
        _status = RuntimeStatus.running;
        return StartResult(StartStatus.ok,
            pid: _process!.pid, startupMs: sw.elapsedMilliseconds);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final tail = _stderrTail();
    await stop();
    return StartResult(StartStatus.failed,
        message: tail.isEmpty ? 'daemon did not become ready' : tail,
        startupMs: sw.elapsedMilliseconds);
  }

  void _collectLogs() {
    final p = _process;
    if (p == null) return;
    // v0.5.6 §leak-fix: cancel the PREVIOUS pair first. These two
    // subscriptions were never stored, so every start() / restart() /
    // recoverEngine() stacked another live pair forever, retaining the
    // ManagedProcess, its two StreamControllers, and the closures (which
    // capture `this` → the whole runtime).
    _disposeLogSubs();
    _stderrRing.clear();
    _stderrSub = p.stderrStream.listen((line) {
      _stderrRing.add(line);
      if (_stderrRing.length > 40) _stderrRing.removeAt(0);
      Logger.instance.debug(binaryKind.name, line);
    });
    _stdoutSub =
        p.stdoutStream.listen((line) => Logger.instance.debug(binaryKind.name, line));
  }

  /// Release the stderr/stdout collectors. Safe to call repeatedly.
  void _disposeLogSubs() {
    _stderrSub?.cancel();
    _stdoutSub?.cancel();
    _stderrSub = null;
    _stdoutSub = null;
  }

  String _stderrTail() => _stderrRing.take(12).join('\n');

  @override
  Future<void> stop() async {
    _status = RuntimeStatus.stopping;
    final p = _process;
    _process = null;
    // v0.5.6 §leak-fix: stop collecting before the process goes away.
    _disposeLogSubs();
    if (p != null) await p.stop();
    _status = RuntimeStatus.stopped;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _exitEvents?.close();
  }

  @override
  Future<RuntimeValidation> validate() async {
    try {
      await writeConfig();
      return RuntimeValidation(isAvailable,
          message: isAvailable
              ? 'config generated; engine available (${_binary?.version})'
              : 'engine is ${_binary?.status ?? 'notInstalled'}');
    } catch (e) {
      return RuntimeValidation(false, message: 'config generation failed: $e');
    }
  }

  @override
  Future<void> restart() async {
    await stop();
    await start();
  }

  @override
  Future<bool> inboundHealthy() => probe();

  @override
  Future<int?> testTag(String tag, {String url = _defaultTestUrl}) async =>
      null; // external daemons: probe externally

  @override
  TrafficSnapshot? get traffic => null;

  static const _defaultTestUrl = 'https://www.gstatic.com/generate_204';
}

/// AmneziaWG runtime (Phase 15). Runs the external `amneziawg` userspace
/// daemon with the profile's AWG conf.
///
/// NOTE (documented limitation): AWG creates its own TUN interface — it does
/// not chain through sing-box. When an AWG profile is active, per-app
/// routing/chains are unavailable and the UI says so.
class AmneziaWgRuntime extends ExternalDaemonRuntime {
  AmneziaWgRuntime({required super.binaryManager, required super.workDir});

  ProxyProfile? profile;

  @override
  CoreBinaryKind get binaryKind => CoreBinaryKind.amneziaWg;

  @override
  CoreKind get coreKind => CoreKind.amneziaWg;

  @override
  String configFileName() => 'nexus-awg.conf';

  @override
  Map<String, dynamic> buildConfig() => throw UnimplementedError();

  @override
  String? _configText() {
    final p = profile;
    if (p == null) return null;
    final wg = p.wireguard;
    if (wg == null) return null;
    final b = StringBuffer('[Interface]\n')
      ..writeln('PrivateKey = ${wg.privateKey}');
    if (wg.addresses.isNotEmpty) {
      b.writeln('Address = ${wg.addresses.join(', ')}');
    }
    if (wg.dns.isNotEmpty) b.writeln('DNS = ${wg.dns.join(', ')}');
    if (wg.mtu != null) b.writeln('MTU = ${wg.mtu}');
    p.amnezia?.toConfLines().forEach((k, v) => b.writeln('$k = $v'));
    b..writeln()..writeln('[Peer]')..writeln('PublicKey = ${wg.peerPublicKey}');
    if (wg.preSharedKey != null) b.writeln('PresharedKey = ${wg.preSharedKey}');
    b
      ..writeln('AllowedIPs = ${wg.allowedIps.join(', ')}')
      ..writeln('Endpoint = ${wg.endpointHost}:${wg.endpointPort}');
    if (wg.persistentKeepalive != null) {
      b.writeln('PersistentKeepalive = ${wg.persistentKeepalive}');
    }
    return b.toString();
  }

  @override
  List<String> launchArgs(File configFile) => Platform.isWindows
      ? ['/installtunnelservice', configFile.path]
      : ['--config', configFile.path];

  @override
  Future<bool> probe() async => _process?.isRunning ?? false;
}

/// MasterDNSVPN runtime (Phase 16): external Go client, SOCKS5 output mode.
/// Atlanhix generates client_config.toml from the profile's rawParams; the
/// resulting localhost SOCKS5 is ingested by sing-box (chaining).
class MasterDnsVpnRuntime extends ExternalDaemonRuntime {
  MasterDnsVpnRuntime({
    required super.binaryManager,
    required super.workDir,
    this.socksPort = 18000,
  });

  /// Local SOCKS5 listen port (upstream default 18000). Mutable: CoreManager
  /// allocates a free port at prepare() to avoid parallel-test contention
  /// (v0.3.1 §21) and writes it into the generated config.
  int socksPort;

  /// v0.3.2 (live finding): tunnel establishment includes MTU probing over
  /// DNS round-trips (~10-30 s on real networks) BEFORE the SOCKS5 listener
  /// opens. The 6 s daemon default can never suffice for a DNS tunnel.
  @override
  Duration get readinessTimeout => const Duration(seconds: 60);
  ProxyProfile? profile;

  @override
  CoreBinaryKind get binaryKind => CoreBinaryKind.masterDnsVpn;

  @override
  CoreKind get coreKind => CoreKind.masterDnsVpn;

  @override
  String configFileName() => 'client_config.toml';

  @override
  Map<String, dynamic> buildConfig() => throw UnimplementedError();

  /// Escapes a TOML basic-string value. rawParams come from untrusted
  /// subscription content — a raw `"` `\` or newline could otherwise inject
  /// config keys or terminate the value early (v0.3.0 §21: untrusted profile
  /// content must not alter the config).
  static String tomlEscape(String v) => v
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r')
      .replaceAll('\t', '\\t');

  /// v0.3.1 — REAL MasterDnsVPN client schema (client_config.toml.simple).
  /// Upstream fields: DOMAINS (array), DATA_ENCRYPTION_METHOD (int),
  /// ENCRYPTION_KEY (inline string), PROTOCOL_TYPE ("SOCKS5"), LISTEN_IP,
  /// LISTEN_PORT (int). The shared secret NEVER lands in this file: it is
  /// handed to the client via the `-k` flag argument (§2/§22).
  @override
  String? _configText() {
    final p = profile;
    if (p == null) return null;
    final q = p.rawParams;
    String str(String k, [String d = '']) {
      final v = q[k];
      return v == null || v.isEmpty ? d : v;
    }

    final domains = (q['DOMAINS'] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (domains.isEmpty) domains.add(p.server);
    final method = int.tryParse(str('DATA_ENCRYPTION_METHOD', '1')) ?? 1;
    final listenPort = socksPort;

    final b = StringBuffer()
      ..writeln('# Generated by Atlanhix — MasterDNSVPN client config')
      ..writeln('# (schema: upstream client_config.toml.simple, v2026.x)')
      ..writeln(
          'DOMAINS = [${domains.map((d) => '"${MasterDnsVpnRuntime.tomlEscape(d)}"').join(', ')}]')
      ..writeln('DATA_ENCRYPTION_METHOD = $method')
      ..writeln('PROTOCOL_TYPE = "SOCKS5"')
      ..writeln('LISTEN_IP = "127.0.0.1"')
      ..writeln('LISTEN_PORT = $listenPort')
      ..writeln('MTU = ${int.tryParse(str('MTU', '1230')) ?? 1230}');
    final resolvers = (q['RESOLVERS'] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (resolvers.isNotEmpty) {
      b.writeln('RESOLVERS = [${resolvers.map((r) => '"${MasterDnsVpnRuntime.tomlEscape(r)}"').join(', ')}]');
    }
    return b.toString();
  }

  /// Generates the `client_resolvers.txt` accepted by `-resolvers`:
  /// one resolver per line, `host` or `host:port` (upstream format).
  Future<File> writeResolversFile(List<String> resolvers) async {
    await workDir.create(recursive: true);
    final f =
        File('${workDir.path}${Platform.pathSeparator}client_resolvers.txt');
    final lines = resolvers
        .map((r) => r.trim())
        .where((r) => r.isNotEmpty)
        .join('\n');
    await f.writeAsString('$lines\n');
    return f;
  }

  /// v0.3.1 (real-binary finding): the upstream client resolves its
  /// resolvers file relative to the config directory and REFUSES to start
  /// without it ("resolver file not found"). The config itself does not
  /// accept a RESOLVERS key — the file + `-resolvers` flag is the mechanism.
  @override
  Future<void> prepareSidecars() async {
    final q = profile?.rawParams ?? const {};
    var resolvers = (q['RESOLVERS'] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (resolvers.isEmpty) {
      // Sane defaults; public resolvers, upstream-format lines.
      resolvers = ['8.8.8.8', '1.1.1.1'];
    }
    final f = await writeResolversFile(resolvers);
    _resolversFile = f;
  }

  /// Written by [prepareSidecars]; handed to the client via `-resolvers`.
  File? _resolversFile;
  File? get resolversFile => _resolversFile;

  @override
  List<String> launchArgs(File configFile) {
    // v0.3.1 — REAL MasterDnsVPN Go client (cmd/client): flags are
    // `-config <path>` (alias `-c`), `-resolvers <path>`, `-log <path>`,
    // `-k <shared key>` (inline secret override), `-d <domains>`,
    // `-version`. The secret goes on the process argv (process-local),
    // NEVER into the config file or logs (§2/§22).
    final args = <String>['-config', configFile.path];
    if (_resolversFile != null) {
      args..add('-resolvers')..add(_resolversFile!.path);
    }
    final key = profile?.password;
    if (key != null && key.isNotEmpty) {
      args..add('-k')..add(key);
    }
    if (logPath != null && logPath!.isNotEmpty) {
      args..add('-log')..add(logPath!);
    }
    return args;
  }

  /// Optional client log file (diagnostics, §19).
  String? logPath;

  /// Readiness = a real SOCKS5 greeting exchange on the local endpoint.
  /// TCP-connect alone is not proof the daemon is serving (v0.3.0 §10).
  @override
  Future<bool> probe() async {
    Socket? s;
    try {
      s = await Socket.connect(InternetAddress.loopbackIPv4, socksPort,
          timeout: const Duration(milliseconds: 600));
      s.add([0x05, 0x01, 0x00]); // SOCKS5: offer NO-AUTH
      final reply = await _readN(s, 2);
      return reply.length == 2 && reply[0] == 0x05 && reply[1] == 0x00;
    } catch (_) {
      return false;
    } finally {
      s?.destroy();
    }
  }

  static Future<List<int>> _readN(Socket s, int n) async {
    final buf = <int>[];
    final c = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = s.listen((chunk) {
      buf.addAll(chunk);
      if (buf.length >= n && !c.isCompleted) c.complete();
    }, onDone: () {
      if (!c.isCompleted) c.complete();
    }, onError: (Object _) {
      if (!c.isCompleted) c.complete();
    });
    try {
      await c.future.timeout(const Duration(milliseconds: 800));
    } on TimeoutException {
      // fall through with whatever arrived
    } finally {
      await sub.cancel();
    }
    return buf;
  }
}
