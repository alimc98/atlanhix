import 'dart:convert';

/// Shared helpers for share-link parsing/export across adapters.
class UriUtils {
  /// Tolerant base64 decode: handles url-safe alphabets, missing padding and
  /// raw (non-base64) fallback via [returnsNullOnFail].
  static String? tryDecodeBase64(String input) {
    var s = input.trim().replaceAll('\n', '').replaceAll('\r', '');
    if (s.isEmpty) return null;
    s = s.replaceAll('-', '+').replaceAll('_', '/');
    final pad = (4 - s.length % 4) % 4;
    s = s + '=' * pad;
    try {
      final bytes = base64.decode(s);
      final decoded = utf8.decode(bytes, allowMalformed: true);
      // Heuristic: decoded payload should be printable-ish.
      final printable = decoded
          .runes
          .where((r) => r >= 32 || r == 9 || r == 10 || r == 13)
          .length;
      if (printable < decoded.runes.length * 0.9) return null;
      return decoded;
    } on FormatException {
      return null;
    }
  }

  static String encodeBase64(String input) =>
      base64.encode(utf8.encode(input));

  static String encodeBase64Url(String input) {
    final std = base64.encode(utf8.encode(input));
    return std.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  }

  /// Query parsing that also handles keys repeated and keeps raw strings.
  static Map<String, String> queryOf(Uri uri) {
    final m = <String, String>{};
    uri.queryParametersAll.forEach((k, v) {
      if (v.isNotEmpty) m[k] = v.first;
    });
    return m;
  }

  /// IPv6-safe host:port split from the userinfo-less authority part.
  static (String host, int port)? parseHostPort(String authority) {
    final at = authority.lastIndexOf('@');
    final hostPort = at >= 0 ? authority.substring(at + 1) : authority;
    if (hostPort.startsWith('[')) {
      final close = hostPort.indexOf(']');
      if (close < 0) return null;
      final host = hostPort.substring(1, close);
      final rest = hostPort.substring(close + 1);
      if (!rest.startsWith(':')) return null;
      final port = int.tryParse(rest.substring(1));
      if (port == null) return null;
      return (host, port);
    }
    final idx = hostPort.lastIndexOf(':');
    if (idx < 0) return null;
    final host = hostPort.substring(0, idx);
    final port = int.tryParse(hostPort.substring(idx + 1));
    if (port == null || host.isEmpty) return null;
    return (host, port);
  }

  static String? stripFragment(String? name) {
    if (name == null) return null;
    final decoded = Uri.decodeComponent(name);
    return decoded.isEmpty ? null : decoded;
  }

  static bool isValidPort(int p) => p > 0 && p <= 65535;

  static String flagForCountry(String? code) {
    if (code == null || code.length != 2) return '🌐';
    final base = 0x1F1E6;
    final up = code.toUpperCase();
    return String.fromCharCode(base + up.codeUnitAt(0) - 65) +
        String.fromCharCode(base + up.codeUnitAt(1) - 65);
  }

  static String? countryCodeFromName(String name) {
    final m = RegExp(
      r'\b(US|UK|GB|DE|FR|NL|SE|NO|FI|DK|CH|AT|IT|ES|PL|CZ|RO|TR|RU|UA|CA|JP|'
      r'KR|SG|HK|TW|IN|AE|SA|IL|AU|BR|MX|AR|ZA|IR)\b',
      caseSensitive: false,
    );
    return m.firstMatch(name)?.group(0)?.toUpperCase();
  }
}
