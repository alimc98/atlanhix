// Proves CleanDnsClient end-to-end: reads the subscription URL from the
// phone-store dump (never printed), fetches through the clean-DNS pinning
// client, reports status + link count. Run: dart run tool/cleandns_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:nexus/core/net/clean_dns_client.dart';
import 'package:nexus/protocols/importer.dart';

Future<void> main() async {
  final storePath = Platform.environment['STORE_FILE']!;
  final data = jsonDecode(File(storePath).readAsStringSync())['data'];
  final subs = (data['subscriptions'] as Map).values.toList();
  final url = (subs.first as Map)['url'] as String;
  final client = CleanDnsClient();
  final sw = Stopwatch()..start();
  try {
    final resp = await client
        .get(Uri.parse(url), headers: {'User-Agent': 'v2rayNG'})
        .timeout(const Duration(seconds: 25));
    sw.stop();
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final parsed = MultiFormatImporter().import(body);
    stdout.writeln(
        'HTTP ${resp.statusCode} in ${sw.elapsedMilliseconds}ms · '
        '${parsed.profiles.length} profiles (URL redacted)');
    stdout.writeln('pinned ip: ${client.pinnedIp(Uri.parse(url).host)}');
  } catch (e) {
    stdout.writeln('FAIL: ${e.toString().substring(0, (e.toString().length).clamp(0, 90))}');
  } finally {
    client.close();
    exit(0);
  }
}
