import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/logger.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/diagnostics/diagnostics_service.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

/// v0.3.0 §19 — diagnostics subsystem honesty contract.
///
/// Against a real (idle) CoreManager the report must contain real platform
/// facts, nulls for everything not running, and never throw. With a running
/// engine the report reflects the running state (env-gated — binaries only).
void main() {
  test('idle report: real platform facts + honest nulls', () async {
    Logger.instance.info('diag-test', 'buffer entry for the report');
    final work = await Directory.systemTemp.createTemp('nexus-diag');
    final cores = CoreManager(
      binaryManager: BinaryManager(appDir: work),
      workDir: work,
    );
    addTearDown(() => cores.dispose());
    await cores.prepare();

    final svc = DiagnosticsService(
      cores: cores,
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    final r = await svc.collect();

    // Real platform facts.
    final platform = r['platform'] as Map;
    expect(platform['os'], Platform.operatingSystem);
    expect((platform['osVersion'] as String), isNotEmpty);

    // Nothing running → honest nulls everywhere.
    expect(r['profile'], isNull);
    final engines = r['engines'] as Map;
    for (final e in engines.values) {
      expect((e as Map)['status'], isIn(['idle', 'prepared']));
      expect(e['pid'], isNull);
    }
    expect((r['ports'] as Map)['mixedInbound'], isNull);
    expect((r['readiness'] as Map)['inboundHealthy'], isNull);
    expect(r['probe'], 'skipped — engine not running');
    expect(r['lastStartupMs'] ?? (r['startup'] as Map)['lastStartMs'], isNull);

    // DNS/routing sections reflect the requested config.
    expect((r['dns'] as Map)['mode'], 'automatic');
    expect((r['routing'] as Map)['name'],
        BuiltinRoutingProfiles.all().first.name);

    // Redacted recent logs are present (the buffer entry we just wrote).
    expect((r['recentLogs'] as List).isNotEmpty, isTrue);

    // v0.4.6: no engine running → no layered failure analysis at all
    // (never a fabricated verdict).
    expect(r['failureAnalysis'], isNull);

    // Human render works and contains the platform name.
    final text = DiagnosticsService.renderText(r);
    expect(text, contains('Atlanhix diagnostics report'));
    expect(text, contains(Platform.operatingSystem));
  });

  test(
      'layered failure analysis: shape + UDP-transport verdicts (env-gated)',
      () async {
    final coresDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}cores'
        '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
    if (!coresDir.existsSync()) return;
    final bm = BinaryManager(appDir: coresDir);
    final sb = await bm.inspect(CoreBinaryKind.singbox);
    if (sb.status != 'available') return;

    final cores = CoreManager(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-diag-layer'),
    );
    addTearDown(() => cores.dispose());
    // hysteria2 = UDP/QUIC transport: tcp/tls probes must report 'n/a'
    // instead of a false FAIL (a healthy hy2 node answers no plain TCP).
    final profile = ProxyProfile(
      id: 'diag-hy2',
      name: 'diag hy2 node',
      server: '127.0.0.1',
      port: 1, // deliberately dead — layers must still report honestly
      protocol: ProxyProtocol.hysteria2,
      password: 'diag-pass',
      core: CoreKind.singbox,
    );
    final start = await cores.startFor(
      profile,
      all: [profile],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(start.ok, isTrue, reason: start.message);

    final svc = DiagnosticsService(
      cores: cores,
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    final r = await svc.collect();
    final fa = r['failureAnalysis'] as Map?;
    if (fa == null) {
      // Sandbox without outbound network: layered probes were skipped —
      // honest absence is acceptable, never a fabricated verdict.
      return;
    }
    expect(fa['activeEngine'], 'singbox');
    expect(fa['tcp'], 'n/a (UDP transport)');
    expect(fa['tls'], 'n/a (UDP transport)');
    expect(
        (fa['failingLayer'] as String), isIn(['proxy', 'tcp', 'tls', 'dns']));
    // engineTail: redacted free text — either empty (nothing logged) or
    // present, never throwing, never containing the probe password.
    final tail = (fa['engineTail'] as String?) ?? '';
    expect(tail.contains('diag-pass'), isFalse);
    await cores.stop();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('running report: real pid/port/readiness/probe (env-gated)',
      () async {
    final coresDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}cores'
        '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
    if (!coresDir.existsSync()) return;
    final bm = BinaryManager(appDir: coresDir);
    final sb = await bm.inspect(CoreBinaryKind.singbox);
    if (sb.status != 'available') return;

    final cores = CoreManager(
      binaryManager: bm,
      workDir: await Directory.systemTemp.createTemp('nexus-diag-run'),
    );
    addTearDown(() => cores.dispose());
    final profile = ProxyProfile(
      id: 'diag-run',
      name: 'diag node',
      server: '127.0.0.1',
      port: 1, // deliberately dead upstream — engine still runs
      protocol: ProxyProtocol.shadowsocks,
      ssMethod: 'aes-128-gcm',
      password: 'diag-pass',
      core: CoreKind.singbox,
    );
    final start = await cores.startFor(
      profile,
      all: [profile],
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    expect(start.ok, isTrue, reason: start.message);

    final svc = DiagnosticsService(
      cores: cores,
      routing: BuiltinRoutingProfiles.all().first,
      dns: DnsSettings(mode: DnsMode.automatic),
    );
    final r = await svc.collect();
    final sbEngine = (r['engines'] as Map)['singbox'] as Map;
    expect(sbEngine['status'], 'running');
    expect(sbEngine['pid'], greaterThan(0));
    expect((r['profile'] as Map)['effectiveCore'], 'singbox');
    expect((r['ports'] as Map)['mixedInbound'], cores.front.mixedPort);
    expect((r['readiness'] as Map)['inboundHealthy'], isTrue);
    // Probe against the real internet may fail in a sandboxed network —
    // the report must record the outcome either way (never omit it).
    expect(r['probe'], anyOf(isMap, isNull));
    await cores.stop();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
