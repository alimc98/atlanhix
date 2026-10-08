import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_process.dart';
import 'package:nexus/core/runtime/core_runtime.dart';
import 'package:nexus/core/runtime/external_runtimes.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/adapters/masterdnsvpn.dart';

/// v0.3.1 §10 — MasterDNSVPN runtime: REAL upstream client schema.
///
/// Config/escape/readiness tests run everywhere. The real-daemon E2E is
/// gated by ATLANHIX_MDVPN_E2E=1 plus:
///   ATLANHIX_MDVPN_BIN      path to the real `masterdnsvpn-client` binary
///   ATLANHIX_MDVPN_SERVER   DNS-tunnel server host (also a DOMAIN)
///   ATLANHIX_MDVPN_PORT     server DNS port (default 53)
///   ATLANHIX_MDVPN_KEY      shared tunnel encryption key (SECRET)
///   ATLANHIX_MDVPN_RESOLVERS  optional comma-separated resolver list
ProxyProfile _mdvpnProfile({Map<String, String>? params}) => ProxyProfile(
      id: 'mdvpn-1',
      name: 'mdvpn test node',
      server: 'dns-tunnel.example.com',
      port: 53,
      protocol: ProxyProtocol.masterDnsVpn,
      password: 'test-tunnel-key',
      rawParams: params ??
          {
            'DOMAINS': 'dns-tunnel.example.com',
            'DATA_ENCRYPTION_METHOD': '1',
          },
    );

void main() {
  group('§10 MasterDNSVPN config generation (upstream schema, unit)', () {
    test('generates client_config.toml with DOMAINS/SOCKS5 listener',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-mdvpn-cfg');
      final rt = MasterDnsVpnRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
        socksPort: 18000,
      );
      rt.profile = _mdvpnProfile();
      final f = await rt.writeConfig();
      final text = await f.readAsString();
      expect(text, contains('DOMAINS = ["dns-tunnel.example.com"]'));
      expect(text, contains('DATA_ENCRYPTION_METHOD = 1'));
      expect(text, contains('PROTOCOL_TYPE = "SOCKS5"'));
      expect(text, contains('LISTEN_IP = "127.0.0.1"'));
      expect(text, contains('LISTEN_PORT = 18000'));
      // Invented v0.3.0 schema must not reappear:
      expect(text.contains('SERVER_ADDRESS'), isFalse);
      expect(text.contains('SUBDOMAIN'), isFalse);
      expect(text.contains('SOCKS5_LISTEN_PORT'), isFalse);
      // The shared key must NEVER be written to the config file (§2/§22):
      expect(text.contains('test-tunnel-key'), isFalse,
          reason: 'secret must go via -k argv, not the config file');
      expect(text.contains('ENCRYPTION_KEY'), isFalse);
      await dir.delete(recursive: true);
    });

    test('launchArgs use real Go client flags; key rides argv only', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-mdvpn-args');
      final rt = MasterDnsVpnRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
      );
      rt.profile = _mdvpnProfile();
      rt.logPath = '${dir.path}${Platform.pathSeparator}mdvpn.log';
      final cfgFile = await rt.writeConfig();
      final args = rt.launchArgs(cfgFile);
      expect(args, contains('-config'));
      expect(args[args.indexOf('-config') + 1], cfgFile.path);
      expect(args, contains('-k'));
      expect(args[args.indexOf('-k') + 1], 'test-tunnel-key');
      expect(args, contains('-log'));
      await dir.delete(recursive: true);
    });

    test('escapes untrusted rawParams (TOML injection, §21/§22)', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-mdvpn-esc');
      final rt = MasterDnsVpnRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
      );
      rt.profile = _mdvpnProfile(params: {
        'DOMAINS': 'x"\nINJECTED_KEY = "pwned',
      });
      final f = await rt.writeConfig();
      final text = await f.readAsString();
      final injected = text
          .split('\n')
          .any((l) => l.trimLeft().startsWith('INJECTED_KEY'));
      expect(injected, isFalse,
          reason: 'untrusted value must not inject new TOML keys: $text');
      expect(text, contains(r'\"'));
      expect(text, contains(r'\n'));
      await dir.delete(recursive: true);
    });

    test('parser accepts upstream DOMAINS schema and strips the key', () {
      final toml = '# provider config\n'
          'DOMAINS = ["u.hixyz.ir"]\n'
          'DATA_ENCRYPTION_METHOD = 3\n'
          'ENCRYPTION_KEY = "super-secret-value"\n'
          'PROTOCOL_TYPE = "SOCKS5"\n'
          'LISTEN_PORT = 18000\n';
      final p = MasterDnsVpnParser().parseToml(toml);
      expect(p.server, 'u.hixyz.ir');
      expect(p.port, 53);
      expect(p.rawParams['DOMAINS'], 'u.hixyz.ir');
      expect(p.rawParams['DATA_ENCRYPTION_METHOD'], '3');
      expect(p.rawParams.containsKey('ENCRYPTION_KEY'), isFalse,
          reason: 'secret must not persist into rawParams (plaintext store)');
      // §22: the key moves to password (vaultified at persistence) and the
      // stored raw TOML must be redacted.
      expect(p.password, 'super-secret-value');
      expect(p.rawConfig!.contains('super-secret-value'), isFalse,
          reason: 'rawConfig persists to the JSON store — must be redacted');
      expect(p.rawConfig, contains('<redacted>'));
    });

    test('start() prepares the resolvers sidecar (real client requirement)',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-mdvpn-side');
      final rt = MasterDnsVpnRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
      );
      rt.profile = _mdvpnProfile(params: {
        'DOMAINS': 'dns-tunnel.example.com',
        'RESOLVERS': '8.8.8.8,1.1.1.1:5353',
      });
      await rt.prepareSidecars();
      expect(rt.resolversFile, isNotNull);
      expect(rt.resolversFile!.existsSync(), isTrue,
          reason: 'real client refuses to start without client_resolvers.txt');
      final text = await rt.resolversFile!.readAsString();
      expect(text, contains('8.8.8.8'));
      expect(text, contains('1.1.1.1:5353'));
      // Defaults when the profile has none:
      final rt2 = MasterDnsVpnRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
      );
      rt2.profile = _mdvpnProfile();
      await rt2.prepareSidecars();
      final text2 = await rt2.resolversFile!.readAsString();
      expect(text2, contains('8.8.8.8'));
      expect(text2, contains('1.1.1.1'));
      await dir.delete(recursive: true);
    });

    test('launchArgs include -resolvers when the sidecar was prepared',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-mdvpn-args2');
      final rt = MasterDnsVpnRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
      );
      rt.profile = _mdvpnProfile();
      final cfgFile = await rt.writeConfig();
      final argsBefore = rt.launchArgs(cfgFile);
      expect(argsBefore.contains('-resolvers'), isFalse);
      await rt.prepareSidecars();
      final args = rt.launchArgs(cfgFile);
      expect(args, contains('-resolvers'));
      expect(args[args.indexOf('-resolvers') + 1],
          rt.resolversFile!.path);
      await dir.delete(recursive: true);
    });

    test('resolver file parser handles upstream formats', () {
      final parsed = MasterDnsVpnParser.parseResolverFile(
          '# comment\n8.8.8.8\n1.1.1.1:5353\n[2001:4860:4860::8888]:53\n');
      expect(parsed, [
        {'host': '8.8.8.8', 'port': '53'},
        {'host': '1.1.1.1', 'port': '5353'},
        {'host': '2001:4860:4860::8888', 'port': '53'},
      ]);
    });
  });

  group('§10 MasterDNSVPN readiness & lifecycle (no binary required)', () {
    late MasterDnsVpnRuntime rt;
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('nexus-mdvpn-rt');
      rt = MasterDnsVpnRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
        socksPort: 0, // nothing listens on port 0 → probe must fail
      );
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('probe() is false when the SOCKS endpoint is not serving', () async {
      expect(await rt.probe(), isFalse);
    });

    test('start() reports binaryMissing honestly without the daemon',
        () async {
      rt.profile = _mdvpnProfile();
      final r = await rt.start();
      expect(r.ok, isFalse);
      expect(r.status, StartStatus.binaryMissing);
    });
  });

  test('§11/§13/§14 (ATLANHIX_MDVPN_E2E=1): real daemon → DNS tunnel → '
      'real HTTP traffic → crash → recovery → traffic again', () async {
    final env = Platform.environment;
    if (env['ATLANHIX_MDVPN_E2E'] != '1') {
      // ignore: avoid_print
      print('SKIPPED: ATLANHIX_MDVPN_E2E=1 + ATLANHIX_MDVPN_SERVER/KEY required');
      return;
    }
    final binPath = env['ATLANHIX_MDVPN_BIN'];
    if (binPath == null || !File(binPath).existsSync()) {
      fail('ATLANHIX_MDVPN_E2E set but ATLANHIX_MDVPN_BIN is missing');
    }
    final server = env['ATLANHIX_MDVPN_SERVER'];
    final key = env['ATLANHIX_MDVPN_KEY'];
    if (server == null || server.isEmpty || key == null || key.isEmpty) {
      fail('ATLANHIX_MDVPN_E2E requires SERVER and KEY (secrets stay in env)');
    }
    final method = env['ATLANHIX_MDVPN_METHOD'] ?? '1';
    final resolvers = env['ATLANHIX_MDVPN_RESOLVERS'] ?? '';

    // Expose the real binary to the runtime via userCoresDir.
    final coresDir =
        await Directory.systemTemp.createTemp('nexus-mdvpn-cores');
    await File(binPath).copy(
        '${coresDir.path}${Platform.pathSeparator}'
        '${BinaryManager.binaryName(CoreBinaryKind.masterDnsVpn)}');

    final rt = MasterDnsVpnRuntime(
      binaryManager: BinaryManager(userCoresDir: coresDir.path),
      workDir: await Directory.systemTemp.createTemp('nexus-mdvpn-e2e'),
      socksPort: 0, // allocated dynamically below (§21)
    );
    addTearDown(() => rt.stop());
    await rt.prepare();
    rt.socksPort = await PortAllocator.freePort(prefer: 18000);
    rt.profile = _mdvpnProfile(params: {
      'DOMAINS': server,
      'DATA_ENCRYPTION_METHOD': method,
      if (resolvers.isNotEmpty) 'RESOLVERS': resolvers,
    })
      ..password = key; // delivered via -k argv only (§2/§22)
    final sw = Stopwatch()..start();
    final r = await rt.start();
    expect(r.ok, isTrue, reason: 'daemon start failed: ${r.message}');
    // §12: not ready until the SOCKS endpoint actually speaks SOCKS5.
    final ready = await rt.probe();
    expect(ready, isTrue, reason: 'daemon did not open its SOCKS5 endpoint');
    // §13: REAL HTTP request THROUGH the tunnel to a REAL destination.
    final probe = await LatencyTester().testHttpViaSocksProxy(
        '127.0.0.1', rt.socksPort, 'https://www.gstatic.com/generate_204',
        timeout: const Duration(seconds: 45));
    expect(probe.ok, isTrue,
        reason: 'HTTP through MDVPN tunnel failed: ${probe.errorKind} '
            '${probe.detail}');
    // ignore: avoid_print
    print('METRIC mdvpn: start=${sw.elapsedMilliseconds}ms pid=${rt.lastPid} '
        'http=${probe.latencyMs}ms socksPort=${rt.socksPort}');
    // §14: kill → detect → restart → readiness → traffic again → new PID.
    final oldPid = rt.lastPid!;
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '$oldPid', '/F']);
    } else {
      Process.killPid(oldPid, ProcessSignal.sigkill);
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(rt.lastExit, isNotNull, reason: 'exit watcher must fire on kill');
    expect(rt.lastExit!.kind, isNot(CoreExitKind.clean));
    await rt.start();
    expect(await rt.probe(), isTrue, reason: 'recovered daemon not ready');
    final probe2 = await LatencyTester().testHttpViaSocksProxy(
        '127.0.0.1', rt.socksPort, 'https://www.gstatic.com/generate_204',
        timeout: const Duration(seconds: 45));
    expect(probe2.ok, isTrue, reason: 'post-recovery HTTP probe failed');
    expect(rt.lastPid, isNot(equals(oldPid)),
        reason: 'recovered daemon must be a new process');
    // ignore: avoid_print
    print('METRIC mdvpn recovery: oldPid=$oldPid newPid=${rt.lastPid} '
        'http=${probe2.latencyMs}ms');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
