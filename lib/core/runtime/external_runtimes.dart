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

  Stream<CoreExitEvent> get onExit =>
      (_exitEvents ??= StreamController<CoreExitEvent>.broadcast()).stream;

  @override
  RuntimeStatus get status => _status;

  @override
  CoreExitEvent? get lastExit => _lastExit;

  CoreBinaryInfo? get binaryInfo => _binary;

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
    _stderrRing.clear();
    p.stderrStream.listen((line) {
      _stderrRing.add(line);
      if (_stderrRing.length > 40) _stderrRing.removeAt(0);
      Logger.instance.debug(binaryKind.name, line);
    });
    p.stdoutStream
        .listen((line) => Logger.instance.debug(binaryKind.name, line));
  }

  String _stderrTail() => _stderrRing.take(12).join('\n');

  @override
  Future<void> stop() async {
    _status = RuntimeStatus.stopping;
    final p = _process;
    _process = null;
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
/// NEXUS generates client_config.toml from the profile's rawParams; the
/// resulting localhost SOCKS5 is ingested by sing-box (Phase 17 chaining).
class MasterDnsVpnRuntime extends ExternalDaemonRuntime {
  MasterDnsVpnRuntime({
    required super.binaryManager,
    required super.workDir,
    this.socksPort = 9720,
  });

  final int socksPort;
  ProxyProfile? profile;

  @override
  CoreBinaryKind get binaryKind => CoreBinaryKind.masterDnsVpn;

  @override
  CoreKind get coreKind => CoreKind.masterDnsVpn;

  @override
  String configFileName() => 'nexus-mdvpn-client.toml';

  @override
  Map<String, dynamic> buildConfig() => throw UnimplementedError();

  @override
  String? _configText() {
    final p = profile;
    if (p == null) return null;
    final q = p.rawParams;
    final resolvers = (q['RESOLVERS'] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final b = StringBuffer()
      ..writeln('# Generated by NEXUS — MasterDNSVPN client config')
      ..writeln('SERVER_ADDRESS = "${p.server}"')
      ..writeln('SERVER_PORT = "${p.port}"')
      ..writeln('SUBDOMAIN = "${q['SUBDOMAIN'] ?? ''}"')
      ..writeln('SERVER_PUBLIC_KEY = "${q['SERVER_PUBLIC_KEY'] ?? ''}"')
      ..writeln(
          'DATA_ENCRYPTION_METHOD = "${q['DATA_ENCRYPTION_METHOD'] ?? '1'}"')
      ..writeln('ENCRYPTION_KEY_FILE = "${q['ENCRYPTION_KEY_FILE'] ?? ''}"')
      ..writeln('USE_TUN_MODE = "false"')
      ..writeln('USE_EXTERNAL_SOCKS5 = "false"')
      ..writeln('SOCKS5_LISTEN_HOST = "127.0.0.1"')
      ..writeln('SOCKS5_LISTEN_PORT = "$socksPort"')
      ..writeln('MTU = "${q['MTU'] ?? '1230'}"');
    if (resolvers.isNotEmpty) {
      b.writeln('RESOLVERS = [${resolvers.map((r) => '"$r"').join(', ')}]');
    }
    return b.toString();
  }

  @override
  List<String> launchArgs(File configFile) => ['--config', configFile.path];

  @override
  Future<bool> probe() async {
    try {
      final s = await Socket.connect(
          InternetAddress.loopbackIPv4, socksPort,
          timeout: const Duration(milliseconds: 400));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
