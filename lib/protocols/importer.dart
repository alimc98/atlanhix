import 'dart:convert';
import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import 'common/uri_utils.dart';
import 'adapters/clash_yaml.dart';
import 'adapters/hysteria2.dart';
import 'adapters/masterdnsvpn.dart';
import 'adapters/shadowsocks.dart';
import 'adapters/singbox_json.dart';
import 'adapters/trojan.dart';
import 'adapters/tuic_socks.dart';
import 'adapters/vless.dart';
import 'adapters/vmess.dart';
import 'adapters/wireguard_conf.dart';
import 'adapters/xray_json.dart';

/// Detected source formats for imported payloads.
enum SourceFormat {
  uriList,
  base64UriList,
  clashYaml,
  singBoxJson,
  xrayJson,
  wireguardConf,
  masterDnsVpnToml,
  unknown,
}

class SourceFormatSniffer {
  SourceFormat detect(String text) {
    final t = text.trimLeft();
    if (t.startsWith('{')) {
      try {
        final j = jsonDecode(text);
        if (j is Map) {
          if (j['outbounds'] != null && j['inbounds'] != null) {
            return SourceFormat.xrayJson;
          }
          if (j['outbounds'] != null || j['endpoints'] != null) {
            return SourceFormat.singBoxJson;
          }
        }
      } on FormatException {
        return SourceFormat.unknown;
      }
      return SourceFormat.unknown;
    }
    if (RegExp(r'^\s*\[interface\]', caseSensitive: false).hasMatch(t)) {
      return SourceFormat.wireguardConf;
    }
    if (RegExp(r'^proxies\s*:', multiLine: true).hasMatch(t) ||
        RegExp(r'^port:|^socks-port:|^mixed-port:', multiLine: true)
            .hasMatch(t)) {
      return SourceFormat.clashYaml;
    }
    if (MasterDnsVpnParser.looksLikeToml(text) &&
        RegExp(r'SERVER_(ADDRESS|PUBLIC_KEY)|RESOLVERS|SUBDOMAIN|DOMAINS\s*=',
                multiLine: true)
            .hasMatch(text)) {
      return SourceFormat.masterDnsVpnToml;
    }
    final lines = t
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    // v0.3.2 (live-subscription finding): real subscriptions mix node URIs
    // with comment/info lines — require ANY share line, not every line.
    if (lines.isNotEmpty && lines.any(_isShareUri)) {
      return SourceFormat.uriList;
    }
    final decoded = UriUtils.tryDecodeBase64(t);
    if (decoded != null && decoded.contains('://')) {
      return SourceFormat.base64UriList;
    }
    return SourceFormat.unknown;
  }

  static bool _isShareUri(String line) {
    const schemes = {
      'vmess:', 'vless:', 'trojan:', 'ss:', 'hysteria2:', 'hy2:', 'hysteria:',
      'tuic:', 'socks:', 'socks5:', 'http:', 'ssr:', 'wireguard:', 'mdvpn:',
      'anytls:',
    };
    return schemes.any(line.startsWith);
  }
}

/// Single entry point for importing any payload (clipboard, file, QR, manual).
class MultiFormatImporter {
  final _sniffer = SourceFormatSniffer();
  final _vmess = VmessParser();
  final _vless = VlessParser();
  final _trojan = TrojanParser();
  final _ss = ShadowsocksParser();
  final _hy2 = Hysteria2Parser();
  final _tuic = TuicParser();
  final _socksHttp = SocksHttpParser();
  final _wg = WireGuardConfParser();
  final _clash = ClashYamlParser();
  final _singbox = SingBoxJsonParser();
  final _xray = XrayJsonParser();
  final _mdvpn = MasterDnsVpnParser();

  ImportResult import(String payload, {String? fileName}) {
    final format = _sniffer.detect(payload);
    final profiles = <ProxyProfile>[];
    final warnings = <String>[];
    switch (format) {
      case SourceFormat.uriList:
      case SourceFormat.base64UriList:
        final lines = ShadowsocksParser.decodeUriList(payload);
        var i = 0;
        for (final line in lines) {
          i++;
          try {
            profiles.add(_parseShareUri(line));
          } on AppError catch (e) {
            warnings.add('Line $i: ${e.userMessage}');
          } on FormatException catch (e) {
            warnings.add('Line $i: ${e.message}');
          }
        }
      case SourceFormat.clashYaml:
        final r = _clash.parse(payload);
        profiles.addAll(r.profiles);
        warnings.addAll(r.skipped.map((s) => 'Clash: $s'));
      case SourceFormat.singBoxJson:
        final r = _singbox.parse(payload);
        profiles.addAll(r.profiles);
        warnings.addAll(r.skipped.map((s) => 'sing-box: $s'));
      case SourceFormat.xrayJson:
        final r = _xray.parse(payload);
        profiles.addAll(r.profiles);
        warnings.addAll(r.skipped.map((s) => 'Xray: $s'));
      case SourceFormat.wireguardConf:
        profiles.add(_wg.parse(payload, fileName: fileName));
      case SourceFormat.masterDnsVpnToml:
        profiles.add(_mdvpn.parseToml(payload, name: fileName));
      case SourceFormat.unknown:
        // v0.3.2 (§13 security): never echo raw payload — real subscription
        // URIs embed credentials (uuid/password) that previously leaked into
        // the error text. Report shape, not content.
        throw ParseError(
            'Could not recognize this configuration format.',
            likelyCauses: [
              'Expected share links, base64 list, Clash YAML, sing-box/Xray JSON, or a WireGuard .conf'
            ],
            raw:
                'payload ${payload.length} bytes, line count ~${payload.split(RegExp(r"\r?\n")).length}');
    }
    if (profiles.isEmpty) {
      throw ParseError('No usable proxy configurations were found.',
          likelyCauses: warnings.isEmpty
              ? ['The payload contained no supported entries']
              : warnings);
    }
    return ImportResult(profiles: profiles, warnings: warnings, format: format);
  }

  ProxyProfile _parseShareUri(String line) {
    if (line.startsWith('vmess://')) return _vmess.parse(line);
    if (line.startsWith('vless://')) return _vless.parse(line);
    if (line.startsWith('trojan://')) return _trojan.parse(line);
    if (line.startsWith('ss://')) return _ss.parse(line);
    if (line.startsWith('hysteria2://') ||
        line.startsWith('hy2://') ||
        line.startsWith('hysteria://')) {
      return _hy2.parse(line);
    }
    if (line.startsWith('tuic://')) return _tuic.parse(line);
    if (line.startsWith('mdvpn://')) return _mdvpn.parseUri(line);
    if (line.startsWith('socks://') ||
        line.startsWith('socks5://') ||
        line.startsWith('http://') ||
        line.startsWith('https://')) {
      return _socksHttp.parse(line);
    }
    throw FormatException('unsupported link scheme');
  }
}

class ImportResult {
  ImportResult({
    required this.profiles,
    required this.warnings,
    required this.format,
  });

  final List<ProxyProfile> profiles;
  final List<String> warnings;
  final SourceFormat format;
}
