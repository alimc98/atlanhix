import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus/core/core_detector.dart';
import 'package:nexus/core/health/latency_tester.dart';
import 'package:nexus/core/runtime/binary_manager.dart';
import 'package:nexus/core/runtime/core_manager.dart';
import 'package:nexus/core/runtime/core_runtime.dart';
import 'package:nexus/core/scoring/smart_connect.dart';
import 'package:nexus/core/configgen/singbox_config_generator.dart';
import 'package:nexus/core/logger.dart';
import 'package:nexus/domain/entities/proxy_profile.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';
import 'package:nexus/routing/routing_models.dart';

/// v0.3.1 §4–§7 — REAL subscription E2E harness.
///
/// Gated by:
///   ATLANHIX_SUBSCRIPTION_E2E=1
///   ATLANHIX_SUBSCRIPTION_URL=`<real subscription URL>`  (SECRET — never
///                                                        printed/committed)
///
/// Pipeline: fetch → validate HTTP → detect encoding → parse → sanitized
/// inventory → CoreDetector per profile → config generation validated by the
/// REAL engine binaries → bounded real connectivity through the selected
/// runtime (CoreDetector decision == launched runtime, §7).
///
/// NO node is connected "simultaneously"; connectivity is sequential and
/// bounded. Every emitted line is sanitized (no passwords/UUIDs/URLs/keys).
const _maxConnectCandidates = 12;

Map<String, dynamic> _inventoryLine(ProxyProfile p, CoreDecision d,
    {required bool sbConfigOk}) {
  return {
    'protocol': p.protocol.name,
    'transport': p.transport.name,
    'tls': p.security.name,
    'reality': p.security == Security.reality,
    'server': p.server,
    'port': p.port,
    'core': d.core.name,
    'confidence': d.confidence.toStringAsFixed(2),
    'singboxConfig': sbConfigOk ? 'VALID' : 'SKIPPED/NA',
  };
}

void main() {
  test('§4–§7 REAL subscription E2E (ATLANHIX_SUBSCRIPTION_E2E=1)', () async {
    final env = Platform.environment;
    if (env['ATLANHIX_SUBSCRIPTION_E2E'] != '1') {
      // ignore: avoid_print
      print('SKIPPED: set ATLANHIX_SUBSCRIPTION_E2E=1 + '
          'ATLANHIX_SUBSCRIPTION_URL for the real subscription E2E');
      return;
    }
    final rawUrl = env['ATLANHIX_SUBSCRIPTION_URL'];
    if (rawUrl == null || rawUrl.isEmpty) {
      fail('ATLANHIX_SUBSCRIPTION_E2E set but ATLANHIX_SUBSCRIPTION_URL '
          'is missing (secret stays in the environment)');
    }
    final url = Uri.tryParse(rawUrl);
    if (url == null || (url.scheme != 'http' && url.scheme != 'https')) {
      fail('ATLANHIX_SUBSCRIPTION_URL is not a valid http(s) URL');
    }

    // 1) fetch + 2) validate (default TLS verification — never weakened).
    final client = HttpClient();
    final sw = Stopwatch()..start();
    final req = await client.getUrl(url);
    final resp = await req.close().timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      fail('subscription fetch failed: HTTP ${resp.statusCode}');
    }
    final body =
        await utf8.decoder.bind(resp).join().timeout(const Duration(seconds: 60));
    // ignore: avoid_print
    print('METRIC fetch: ${body.length} bytes in ${sw.elapsedMilliseconds}ms');
    client.close(force: true);

    // 3) detect encoding: base64-of-uri-list is the common subscription form.
    String payload = body.trim();
    final looksB64 =
        RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(payload) && payload.length > 40;
    if (looksB64 && payload.length % 4 == 0) {
      try {
        final decoded = utf8.decode(base64.decode(payload));
        if (decoded.contains('://')) payload = decoded;
      } on FormatException {
        // not base64 — keep original payload
      }
    }

    // 4) parse (format auto-detection; never logs the URL/token).
    final imported = MultiFormatImporter().import(payload);
    final profiles = imported.profiles;
    expect(profiles, isNotEmpty, reason: 'subscription produced no profiles');
    // ignore: avoid_print
    print('INVENTORY total=${profiles.length} format=${imported.format.name} '
        'warnings=${imported.warnings.length}');
    await _continueSubscriptionE2E(profiles);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('subscription harness: base64 detection + sanitized inventory (unit)',
      () {
    const link =
        'ss://YWVzLTEyOC1nY206cGFzc3dvcmQ=@203.0.113.9:8388#unit-node';
    final encoded = base64.encode(utf8.encode(link));
    final decoded = utf8.decode(base64.decode(encoded));
    expect(decoded, link);
    final imported = MultiFormatImporter().import(encoded);
    expect(imported.profiles, isNotEmpty);
    expect(imported.profiles.first.protocol, ProxyProtocol.shadowsocks);
    final line = _inventoryLine(
      imported.profiles.first,
      CoreDetector().resolve(imported.profiles.first),
      sbConfigOk: true,
    );
    final encodedLine = jsonEncode(line);
    expect(encodedLine.contains('password'), isFalse);
    expect(encodedLine.contains('YWVzLTEyOC1nY206'), isFalse);
  });
}

Future<void> _continueSubscriptionE2E(List<ProxyProfile> profiles) async {
  // 5) sanitized inventory + 6) CoreDetector + config generation.
  final coresDir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}cores'
      '${Platform.pathSeparator}${BinaryManager.platformDirName()}');
  final bm = BinaryManager(appDir: coresDir);
  final sbInfo = await bm.inspect(CoreBinaryKind.singbox);
  final detector = CoreDetector();
  final gen = SingBoxConfigGenerator();
  final byCombo = <String, Map<String, dynamic>>{};
  var genOk = 0;
  var genFail = 0;
  for (final p in profiles) {
    final d = detector.resolve(p);
    final sbOk = gen
        .generate(
          runnableProfiles: [p],
          routing: BuiltinRoutingProfiles.all().first,
          dns: DnsSettings(mode: DnsMode.automatic),
          selectedTag: 'node:${p.id}',
          socksUpstreams: d.core == CoreKind.xray
              ? {p.id: (host: '127.0.0.1', port: 2081)}
              : const {},
        )
        .isNotEmpty;
    if (sbOk) {
      genOk++;
    } else if (d.core != CoreKind.xray) {
      genFail++;
    }
    final combo = '${p.protocol.name}/${p.transport.name}/${p.security.name}';
    byCombo.putIfAbsent(combo, () => _inventoryLine(p, d, sbConfigOk: sbOk));
  }
  for (final e in byCombo.entries) {
    // ignore: avoid_print
    print('INVENTORY ${e.key} → ${jsonEncode(e.value)}');
  }
  // ignore: avoid_print
  print('INVENTORY config-gen ok=$genOk fail=$genFail');

  // Engine validation for distinct combos (bounded, real binary).
  if (sbInfo.status == 'available') {
    final validated = <String>{};
    var idx = 0;
    for (final p in profiles) {
      final d = detector.resolve(p);
      if (d.core == CoreKind.xray) continue; // xray-owned, not native
      final combo =
          '${p.protocol.name}/${p.transport.name}/${p.security.name}';
      if (!validated.add(combo)) continue;
      final cfg = gen.generate(
        runnableProfiles: [p],
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: 'node:${p.id}',
      );
      idx++;
      final f = await File(
              '${Directory.systemTemp.path}${Platform.pathSeparator}'
              'sub-check-$idx.json')
          .writeAsString(jsonEncode(cfg));
      final r = await Process.run(sbInfo.path!, ['check', '-c', f.path],
              stdoutEncoding: utf8, stderrEncoding: utf8)
          .timeout(const Duration(seconds: 20));
      await f.delete();
      expect(r.exitCode, 0,
          reason: 'sing-box rejected $combo config: ${r.stderr}');
      // ignore: avoid_print
      print('INVENTORY engine-check $combo: VALID');
    }
  }

  // 7) bounded REAL connectivity: TCP pre-probe → sequential connect.
  // v0.3.2: test ALL alive candidates (bounded per-node timeouts), classify
  // per §22, and capture sanitized engine stderr on failures.
  final selector = SmartConnectSelector();
  final probed = await selector.preprobe(profiles, concurrency: 8);
  // ignore: avoid_print
  print('CONNECTIVITY pre-probe: ${probed.length}/${profiles.length} '
      'candidates answered TCP');

  final results = <String, String>{}; // id → classification
  final details = <String>[];
  final mgr = CoreManager(
    binaryManager: bm,
    workDir: await Directory.systemTemp.createTemp('nexus-sub-e2e'),
  );
  final routing = BuiltinRoutingProfiles.all().first;
  var verified = 0;
  var tried = 0;
  final testedIds = <String>{};
  for (final (profile, _) in probed) {
    if (!testedIds.add(profile.id)) continue;
    if (tried >= _maxConnectCandidates) break;
    tried++;
    final d = detector.resolve(profile);
    profile.core = d.core; // §7: detector decision drives the runtime
    final swStart = Stopwatch()..start();
    final start = await mgr.startFor(profile,
        all: [profile],
        routing: routing,
        dns: DnsSettings(mode: DnsMode.automatic));
    final startMs = swStart.elapsedMilliseconds;
    final label = '${profile.protocol.name}/'
        '${profile.transport.name}/${profile.security.name}';
    if (!start.ok) {
      results[profile.id] = 'FAIL';
      details.add('$label via ${d.core.name}: START_FAIL '
          '(${start.status.name}) ${start.message ?? ''} '
          '${_sanitizedTail(mgr)}');
      continue;
    }
    // §7 core-selection verification: the launched runtime must match.
    final runtimeStatus = switch (d.core) {
      CoreKind.xray => mgr.xray.status,
      CoreKind.masterDnsVpn => mgr.masterDnsVpn.status,
      _ => mgr.front.status,
    };
    if (runtimeStatus != RuntimeStatus.running) {
      results[profile.id] = 'FAIL';
      details.add('$label via ${d.core.name}: CORE_MISMATCH (§7 violation) '
          '${_engineExits(mgr)}');
      await mgr.stop();
      continue;
    }
    final probe = await LatencyTester().testHttpViaSocksProxy(
        '127.0.0.1', mgr.front.mixedPort,
        'https://www.gstatic.com/generate_204',
        timeout: const Duration(seconds: 15));
    if (probe.ok) {
      verified++;
      results[profile.id] = 'PASS';
      details.add('$label via ${d.core.name}: HTTP_OK ${probe.latencyMs}ms '
          'startMs=$startMs pid=${start.pid}');
    } else {
      results[profile.id] =
          probe.errorKind == 'timeout' ? 'TIMEOUT' : 'FAIL';
      details.add('$label via ${d.core.name}: HTTP_FAIL '
          '(${probe.errorKind ?? '?'}) detail=${Logger.redact(probe.detail ?? '')} '
          'startMs=$startMs ${_engineExits(mgr)}');
    }
    await mgr.stop();
  }
  for (final d in details) {
    // ignore: avoid_print
    print('CONNECTIVITY $d');
  }
  // Unsupported/not-alive nodes are reported, not silently dropped.
  final aliveIds = probed.map((r) => r.$1.id).toSet();
  for (final p in profiles) {
    if (!aliveIds.contains(p.id) && !results.containsKey(p.id)) {
      results[p.id] = 'SKIPPED';
    }
  }
  final counts = <String, int>{};
  for (final v in results.values) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  // ignore: avoid_print
  print('RESULT total=${profiles.length} '
      '${counts.entries.map((e) => '${e.key}=${e.value}').join(' ')} '
      'verified=$verified');
  // At least one real node must verify for a PASS (no manufactured passes).
  expect(verified, greaterThanOrEqualTo(1),
      reason: 'no real node from the subscription carried HTTP traffic');
}

/// Sanitized engine stderr tail for failure diagnostics (no credentials —
/// engine logs never contain them; Redact applied as defense in depth).
String _sanitizedTail(CoreManager mgr) {
  final buf = <String>[];
  final all = Logger.instance.buffer;
  final from = all.length > 12 ? all.length - 12 : 0;
  for (final line in all.skip(from)) {
    buf.add(line.message);
  }
  return buf.isEmpty ? '' : ' | log: ${Logger.redact(buf.join(' / ').trim())}';
}

/// Real engine exit diagnostics: exit kind + stderr tail per engine.
String _engineExits(CoreManager mgr) {
  final parts = <String>[];
  final fe = mgr.front.lastExit;
  if (fe != null) {
    parts.add('singbox[${fe.kind.name}]: ${Logger.redact(fe.stderrTail)}');
  }
  final xe = mgr.xray.lastExit;
  if (xe != null) {
    parts.add('xray[${xe.kind.name}]: ${Logger.redact(xe.stderrTail)}');
  }
  return parts.isEmpty ? '(no exits captured)' : parts.join(' || ');
}

