import 'dart:convert';
import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import 'common/uri_utils.dart';
import 'link_screener.dart';
import 'adapters/clash_yaml.dart';
import 'adapters/hysteria2.dart';
import 'adapters/masterdnsvpn.dart';
import 'adapters/shadowsocks.dart';
import 'adapters/stormdns.dart';
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
  stormDnsToml,
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
    // v0.6.4 §stormdns: check FIRST — both client configs carry DOMAINS =
    // and only the StormDNS sample has STARTUP_MODE / DNS_QUERY_TYPE /
    // the split duplication keys.
    if (StormDnsParser.looksLikeToml(text) &&
        StormDnsParser.looksLikeStormToml(text)) {
      return SourceFormat.stormDnsToml;
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
      'stormdns:', 'storm:', 'masterdns:', 'anytls:',
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
  final _storm = StormDnsParser();

  /// v0.4.7 §user: every imported payload is screened for Xray-only
  /// transports (xhttp/mKCP) and their stream-shape requirements, so the
  /// summary can report counts BEFORE the user discovers a broken node at
  /// connect time.
  final _screener = const LinkScreener();

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
      case SourceFormat.stormDnsToml:
        profiles.add(_storm.parseToml(payload, name: fileName));
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
    final screen = _screener.screenAll(profiles);
    return ImportResult(
      profiles: profiles,
      warnings: warnings,
      format: format,
      screen: screen,
    );
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
    // WhiteDNS-compatible profile links (stormdns://, storm://, masterdns://
    // JSON) — before the generic scheme list, engine picked per scheme.
    if (StormDnsParser.isProfileLink(line)) return _storm.parseUri(line);
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
    LinkScreenSummary? screen,
  }) : screen = screen ??
            const LinkScreener().screenAll(const <ProxyProfile>[]);

  final List<ProxyProfile> profiles;
  final List<String> warnings;
  final SourceFormat format;

  /// v0.4.7 §user: pre-import screening — Xray-only transport counts and
  /// stream-shape risks (headerType/mode/seed classes), aggregated.
  final LinkScreenSummary screen;
}
