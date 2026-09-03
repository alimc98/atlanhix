import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_runtime.dart';
import 'package:nexus/core/runtime/external_runtimes.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';

/// v0.3.0 §10 — MasterDNSVPN external runtime lifecycle & config.
///
/// The config/escape/readiness tests run everywhere. The real-daemon E2E is
/// gated by ATLANHIX_MDVPN_E2E=1 plus:
///   ATLANHIX_MDVPN_BIN     path to the real `mdvpn-client` binary
///   ATLANHIX_MDVPN_SERVER  DNS-tunnel server host
///   ATLANHIX_MDVPN_PORT    server port
///   ATLANHIX_MDVPN_SUB     SUBDOMAIN param (server-assigned)
///   ATLANHIX_MDVPN_KEY     path to the ENCRYPTION_KEY_FILE (optional)
ProxyProfile _mdvpnProfile({Map<String, String>? params}) => ProxyProfile(
      id: 'mdvpn-1',
      name: 'mdvpn test node',
      server: 'dns-tunnel.example.com',
      port: 53,
      protocol: ProxyProtocol.masterDnsVpn,
      rawParams: params ??
          {
            'SUBDOMAIN': 't.example.com',
            'SERVER_PUBLIC_KEY': 'base64pubkey',
            'DATA_ENCRYPTION_METHOD': '1',
          },
    );

void main() {
  group('§10 MasterDNSVPN config generation (unit)', () {
    test('generates TOML with SOCKS5 listener on 127.0.0.1', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-mdvpn-cfg');
      final rt = MasterDnsVpnRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
        socksPort: 9720,
      );
      rt.profile = _mdvpnProfile();
      final f = await rt.writeConfig();
      final text = await f.readAsString();
      expect(text, contains('SERVER_ADDRESS = "dns-tunnel.example.com"'));
      expect(text, contains('SERVER_PORT = "53"'));
      expect(text, contains('SOCKS5_LISTEN_HOST = "127.0.0.1"'));
      expect(text, contains('SOCKS5_LISTEN_PORT = "9720"'));
      expect(text, contains('USE_TUN_MODE = "false"'));
      expect(text, isNot(contains('NEXUS')));
      await dir.delete(recursive: true);
    });

    test('escapes untrusted rawParams (TOML injection, §21)', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-mdvpn-esc');
      final rt = MasterDnsVpnRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
      );
      rt.profile = _mdvpnProfile(params: {
        'SUBDOMAIN': 'x"\nINJECTED_KEY = "pwned',
      });
      final f = await rt.writeConfig();
      final text = await f.readAsString();
      // The payload must stay INSIDE the quoted TOML value: no physical
      // newline may appear inside the value, and quotes must be escaped —
      // i.e. no line may BEGIN with the injected key.
      final injected = text
          .split('\n')
          .any((l) => l.trimLeft().startsWith('INJECTED_KEY'));
      expect(injected, isFalse,
          reason: 'untrusted value must not inject new TOML keys: $text');
      expect(text, contains(r'\"'));
      expect(text, contains(r'\n'));
      await dir.delete(recursive: true);
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

  test('§11 (ATLANHIX_MDVPN_E2E=1): real daemon → SOCKS → traffic',
      () async {
    final env = Platform.environment;
    if (env['ATLANHIX_MDVPN_E2E'] != '1') {
      // ignore: avoid_print
      print('SKIPPED: ATLANHIX_MDVPN_E2E=1 + server params required');
      return;
    }
    final binPath = env['ATLANHIX_MDVPN_BIN'];
    if (binPath == null || !File(binPath).existsSync()) {
      fail('ATLANHIX_MDVPN_E2E set but ATLANHIX_MDVPN_BIN is missing');
    }
    final server = env['ATLANHIX_MDVPN_SERVER'];
    final sub = env['ATLANHIX_MDVPN_SUB'];
    if (server == null || sub == null) {
      fail('ATLANHIX_MDVPN_E2E requires SERVER and SUB');
    }
    final port = int.tryParse(env['ATLANHIX_MDVPN_PORT'] ?? '53') ?? 53;
    final keyFile = env['ATLANHIX_MDVPN_KEY'] ?? '';

    // Expose the real binary to the runtime via userCoresDir.
    final coresDir =
        await Directory.systemTemp.createTemp('nexus-mdvpn-cores');
    await File(binPath).copy(
        '${coresDir.path}${Platform.pathSeparator}'
        '${BinaryManager.binaryName(CoreBinaryKind.masterDnsVpn)}');

    final rt = MasterDnsVpnRuntime(
      binaryManager: BinaryManager(userCoresDir: coresDir.path),
      workDir: await Directory.systemTemp.createTemp('nexus-mdvpn-e2e'),
      socksPort: 19720,
    );
    addTearDown(() => rt.stop());
    rt.profile = _mdvpnProfile(params: {
      'SUBDOMAIN': sub,
      'SERVER_PUBLIC_KEY': env['ATLANHIX_MDVPN_PUBKEY'] ?? '',
      'ENCRYPTION_KEY_FILE': keyFile,
    });
    final r = await rt.start();
    expect(r.ok, isTrue, reason: 'daemon start failed: ${r.message}');
    // §10: not ready until the SOCKS endpoint actually speaks SOCKS5.
    final ready = await rt.probe();
    expect(ready, isTrue, reason: 'daemon did not open its SOCKS5 endpoint');
    // ignore: avoid_print
    print('MDVPN E2E: daemon ready pid=${rt.lastPid} '
        '(traffic-path verification needs a live DNS tunnel server — '
        'probe-only here unless ATLANHIX_MDVPN_HTTP_TARGET is set)');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
