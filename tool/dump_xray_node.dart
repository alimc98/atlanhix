import 'dart:convert';
import 'dart:io';
import 'package:nexus/core/configgen/xray_config_generator.dart';
import 'package:nexus/protocols/importer.dart';
import 'package:nexus/routing/builtin_profiles.dart';
void main() {
  final raw = File(Platform.environment['SUB_FILE']!).readAsStringSync().trim();
  var payload = raw;
  if (!raw.contains('://')) { try { payload = utf8.decode(base64.decode(raw)); } catch (_) {} }
  final p = MultiFormatImporter().import(payload).profiles.firstWhere((e) => e.name.contains('GM-USA'));
  final cfg = XrayConfigGenerator().generate(profile: p, routing: BuiltinRoutingProfiles.all().first, localSocksPort: 40999, dnsServer: '8.8.8.8');
  final ob = (cfg['outbounds'] as List).firstWhere((o) => o['tag'] == 'proxy-out');
  // redact uuid/password-ish fields
  final s = jsonEncode(ob).replaceAll(RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'), '<uuid>').replaceAll(RegExp(r'"password":"[^"]*"'), '"password":"<red>"');
  stdout.writeln(s);
}
