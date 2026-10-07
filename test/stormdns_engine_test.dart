import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/android_node_support.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/external_runtimes.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/domain/errors/app_error.dart';
import 'package:nexus/protocols/adapters/stormdns.dart';
import 'package:nexus/protocols/importer.dart';

/// v0.6.4 §stormdns — StormDNS engine (nullroute1970/StormDNS).
///
/// Mirrors the MasterDnsVPN contract: upstream client_config.toml schema,
/// resolvers sidecar, --config/--resolvers/--encryption-key argv, SOCKS5
/// readiness, WhiteDNS-compatible `stormdns://` profile links, and the
/// honest Android desktop-only lockout.
ProxyProfile _stormProfile({Map<String, String>? params}) => ProxyProfile(
      id: 'storm-1',
      name: 'storm test node',
      server: 'v.tunnel.example.com',
      port: 53,
      protocol: ProxyProtocol.stormDns,
      core: CoreKind.stormDns,
      password: 'test-storm-key',
      rawParams: params ??
          {
            'DOMAINS': 'v.tunnel.example.com',
            'DATA_ENCRYPTION_METHOD': '1',
          },
    );

String _whiteDnsPayload({
  String domain = 'v.example.com',
  String key = 'secret-key',
  int method = 3,
  String name = 'My storm',
}) =>
    jsonEncode({
      'schema': 'whitedns.profile',
      'version': 1,
      'profile': {
        'name': name,
        'server': {
          'domain': domain,
          'encryption_key': key,
          'encryption_method': method,
        },
      },
    });

void main() {
  group('§stormdns config generation (upstream client_config.toml.simple)', () {
    test('generates DOMAINS/SOCKS5 listener + headless STARTUP_MODE', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-storm-cfg');
      final rt = StormDnsRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
        socksPort: 18001,
      );
      rt.profile = _stormProfile();
      final f = await rt.writeConfig();
      final text = await f.readAsString();
      expect(text, contains('DOMAINS = ["v.tunnel.example.com"]'));
      expect(text, contains('DATA_ENCRYPTION_METHOD = 1'));
      expect(text, contains('PROTOCOL_TYPE = "SOCKS5"'));
      expect(text, contains('LISTEN_IP = "127.0.0.1"'));
      expect(text, contains('LISTEN_PORT = 18001'));
      // Headless: the default `ask` startup waits on stdin and the
      // readiness probe would time out on every connect.
      expect(text, contains('STARTUP_MODE = "resolvers"'));
      // The shared key must NEVER land in the config file (§2/§22):
      expect(text.contains('test-storm-key'), isFalse,
          reason: 'secret must go via --encryption-key argv, not the file');
      await dir.delete(recursive: true);
    });

    test('schema parity: no MTU / RESOLVERS keys (absent upstream)', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-storm-par');
      final rt = StormDnsRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
        socksPort: 18001,
      );
      rt.profile = _stormProfile(params: {
        'DOMAINS': 'v.tunnel.example.com',
        'RESOLVERS': '8.8.8.8,1.1.1.1',
        'MTU': '1230',
      });
      final text = await (await rt.writeConfig()).readAsString();
      expect(text.contains('RESOLVERS'), isFalse,
          reason: 'resolvers ride client_resolvers.txt + --resolvers');
      expect(RegExp(r'^MTU\s*=', multiLine: true).hasMatch(text), isFalse);
      await dir.delete(recursive: true);
    });

    test('DNS_QUERY_TYPE passes through only for valid upstream values',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-storm-qt');
      final rt = StormDnsRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
        socksPort: 18001,
      );
      rt.profile = _stormProfile(params: {
        'DOMAINS': 'v.tunnel.example.com',
        'DNS_QUERY_TYPE': 'NS',
      });
      expect(await (await rt.writeConfig()).readAsString(),
          contains('DNS_QUERY_TYPE = "NS"'));
      rt.profile = _stormProfile(params: {
        'DOMAINS': 'v.tunnel.example.com',
        'DNS_QUERY_TYPE': 'BOGUS',
      });
      expect((await (await rt.writeConfig()).readAsString())
              .contains('DNS_QUERY_TYPE'),
          isFalse);
      await dir.delete(recursive: true);
    });

    test('resolvers sidecar + argv carry --config/--resolvers/--encryption-key',
        () async {
      final dir = await Directory.systemTemp.createTemp('nexus-storm-side');
      final rt = StormDnsRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
        socksPort: 18001,
      );
      rt.profile = _stormProfile(params: {
        'DOMAINS': 'v.tunnel.example.com',
        'RESOLVERS': '8.8.8.8,1.1.1.1:5353',
      });
      final cfg = await rt.writeConfig();
      // Before sidecar preparation there is no --resolvers flag.
      final before = rt.launchArgs(cfg);
      expect(before.contains('--resolvers'), isFalse);

      await rt.prepareSidecars();
      expect(rt.resolversFile, isNotNull);
      expect(rt.resolversFile!.existsSync(), isTrue,
          reason: 'the real client refuses to start without its resolver file');
      final lines = (await rt.resolversFile!.readAsString())
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines, ['8.8.8.8', '1.1.1.1:5353']);

      final args = rt.launchArgs(cfg);
      expect(args[0], '--config');
      expect(args[1], cfg.path);
      expect(args.contains('--resolvers'), isTrue);
      expect(args[args.indexOf('--resolvers') + 1], rt.resolversFile!.path);
      expect(args.contains('--encryption-key'), isTrue);
      expect(args[args.indexOf('--encryption-key') + 1], 'test-storm-key');
      // The secret is argv-only: the config on disk stays clean.
      expect(await cfg.readAsString(), isNot(contains('test-storm-key')));
      await dir.delete(recursive: true);
    });
  });

  group('§stormdns binary resolution', () {
    test('normalized name + upstream release aliases + version flag', () {
      expect(BinaryManager.binaryName(CoreBinaryKind.stormDns),
          Platform.isWindows ? 'stormdns.exe' : 'stormdns');
      final aliases = BinaryManager.binaryAliases(CoreBinaryKind.stormDns);
      expect(
          aliases.any((a) => a.contains('StormDNS_Client')),
          isTrue,
          reason: 'upstream releases ship StormDNS_Client_<OS>_<ARCH>');
      expect(BinaryManager.versionArgs(CoreBinaryKind.stormDns),
          ['--version']);
    });
  });

  group('§stormdns parser + WhiteDNS-compatible links', () {
    test('parseToml: upstream schema, key vaultified and redacted', () {
      const toml = '# provider config\n'
          'DOMAINS = ["v.u.example.com"]\n'
          'DATA_ENCRYPTION_METHOD = 3\n'
          'ENCRYPTION_KEY = "super-secret-value"\n'
          'PROTOCOL_TYPE = "SOCKS5"\n'
          'STARTUP_MODE = "resolvers"\n'
          'DNS_QUERY_TYPE = "CNAME"\n';
      final p = StormDnsParser().parseToml(toml);
      expect(p.protocol, ProxyProtocol.stormDns);
      expect(p.core, CoreKind.stormDns);
      expect(p.server, 'v.u.example.com');
      expect(p.rawParams['DOMAINS'], 'v.u.example.com');
      expect(p.rawParams['DNS_QUERY_TYPE'], 'CNAME');
      expect(p.rawParams.containsKey('ENCRYPTION_KEY'), isFalse,
          reason: 'secret must not persist into rawParams');
      expect(p.password, 'super-secret-value');
      expect(p.rawConfig!.contains('super-secret-value'), isFalse);
      expect(p.rawConfig, contains('<redacted>'));
    });

    test('parseUri: stormdns:// WhiteDNS JSON → StormDNS profile', () {
      final b64 = base64Url
          .encode(utf8.encode(_whiteDnsPayload()))
          .replaceAll('=', '');
      final p = StormDnsParser().parseUri('stormdns://$b64#My%20storm');
      expect(p.protocol, ProxyProtocol.stormDns);
      expect(p.core, CoreKind.stormDns);
      expect(p.server, 'v.example.com');
      expect(p.password, 'secret-key');
      expect(p.rawParams['DATA_ENCRYPTION_METHOD'], '3');
    });

    test('parseUri: masterdns:// JSON routes to the MasterDnsVPN core', () {
      final b64 = base64Url
          .encode(utf8.encode(_whiteDnsPayload()))
          .replaceAll('=', '');
      final p = StormDnsParser().parseUri('masterdns://$b64');
      expect(p.protocol, ProxyProtocol.masterDnsVpn);
      expect(p.core, CoreKind.masterDnsVpn);
      expect(p.server, 'v.example.com');
    });

    test('parseUri: honest errors on missing domain/key or bad payload', () {
      expect(() => StormDnsParser().parseUri('stormdns://!!!'),
          throwsA(isA<ParseError>()));
      final noKey = base64Url
          .encode(utf8.encode(jsonEncode({
            'schema': 'whitedns.profile',
            'profile': {
              'name': 'x',
              'server': {'domain': 'v.x.com', 'encryption_method': 1},
            },
          })))
          .replaceAll('=', '');
      expect(() => StormDnsParser().parseUri('stormdns://$noKey'),
          throwsA(isA<ParseError>()));
    });

    test('exportUri round-trips through parseUri (WhiteDNS exchange)', () {
      final p = _stormProfile();
      final link = StormDnsParser().exportUri(p);
      expect(link, startsWith('stormdns://'));
      final back = StormDnsParser().parseUri(link);
      expect(back.server, p.server);
      expect(back.password, p.password);
      expect(back.name, p.name);
      expect(back.protocol, ProxyProtocol.stormDns);
    });
  });

  group('§stormdns importer routing', () {
    test('a stormdns:// share line imports as a StormDNS node', () {
      final link = StormDnsParser().exportUri(_stormProfile());
      final r = MultiFormatImporter().import(link);
      expect(r.format, SourceFormat.uriList);
      expect(r.profiles, hasLength(1));
      expect(r.profiles.single.protocol, ProxyProtocol.stormDns);
      expect(r.profiles.single.core, CoreKind.stormDns);
    });

    test('a StormDNS client_config.toml pastes as stormDnsToml', () {
      const toml = '# provider config\n'
          'DOMAINS = ["v.paste.example.com"]\n'
          'DATA_ENCRYPTION_METHOD = 1\n'
          'ENCRYPTION_KEY = "k"\n'
          'PROTOCOL_TYPE = "SOCKS5"\n'
          'STARTUP_MODE = "resolvers"\n';
      final r = MultiFormatImporter().import(toml);
      expect(r.format, SourceFormat.stormDnsToml);
      expect(r.profiles.single.protocol, ProxyProtocol.stormDns);
      expect(r.profiles.single.password, 'k');
    });

    test('a MasterDnsVPN TOML without storm keys still maps to mdvpn', () {
      const toml = '# provider config\n'
          'DOMAINS = ["u.md.example.com"]\n'
          'DATA_ENCRYPTION_METHOD = 1\n'
          'ENCRYPTION_KEY = "k"\n'
          'PROTOCOL_TYPE = "SOCKS5"\n';
      final r = MultiFormatImporter().import(toml);
      expect(r.format, SourceFormat.masterDnsVpnToml);
      expect(r.profiles.single.protocol, ProxyProtocol.masterDnsVpn);
    });
  });

  group('§stormdns engine selection + Android gating', () {
    test('detector routes the transport to the StormDNS engine', () {
      final d = CoreDetector().detect(_stormProfile());
      expect(d.core, CoreKind.stormDns);
    });

    test('honest desktop-only lockout on Android', () {
      final p = _stormProfile();
      expect(AndroidNodeSupport.isRunnable(p), isFalse);
      expect(AndroidNodeSupport.notRunnableReason(p),
          'StormDNS (desktop only)');
      expect(AndroidNodeSupport.coreAllowedOnAndroid(CoreKind.stormDns),
          isFalse);
      expect(AndroidNodeSupport.androidExclusionReason(p)!.startsWith('stormdns:'),
          isTrue);
      expect(AndroidNodeSupport.coreDisplayName(CoreKind.stormDns),
          'StormDNS');
    });
  });

  group('§schema-parity regression guard (MasterDnsVPN)', () {
    test('mdvpn generated config carries no MTU / RESOLVERS keys', () async {
      final dir = await Directory.systemTemp.createTemp('nexus-mdvpn-par');
      final rt = MasterDnsVpnRuntime(
        binaryManager: BinaryManager(),
        workDir: dir,
        socksPort: 18000,
      );
      rt.profile = ProxyProfile(
        id: 'mdvpn-par',
        name: 'mdvpn parity',
        server: 'v.u.example.com',
        port: 53,
        protocol: ProxyProtocol.masterDnsVpn,
        core: CoreKind.masterDnsVpn,
        password: 'k',
        rawParams: {
          'DOMAINS': 'v.u.example.com',
          'RESOLVERS': '8.8.8.8',
          'MTU': '1230',
        },
      );
      final text = await (await rt.writeConfig()).readAsString();
      expect(text.contains('RESOLVERS'), isFalse);
      expect(RegExp(r'^MTU\s*=', multiLine: true).hasMatch(text), isFalse);
      expect(text, contains('DOMAINS = ["v.u.example.com"]'));
      await dir.delete(recursive: true);
    });
  });
}
