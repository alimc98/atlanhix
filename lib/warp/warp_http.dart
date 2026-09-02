import 'dart:convert';
import 'package:http/http.dart' as http;
import 'warp_registrar.dart';

/// Real HTTP implementation of the WARP device-registration API transport.
class HttpWarpApi implements WarpHttp {
  final http.Client _client = http.Client();

  @override
  Future<Map<String, dynamic>> post(Uri url,
      {Map<String, String> headers = const {}, Object? body}) async {
    final resp = await _client
        .post(url,
            headers: headers, body: body == null ? null : jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    return _handle(resp);
  }

  @override
  Future<Map<String, dynamic>> get(Uri url,
      {Map<String, String> headers = const {}}) async {
    final resp = await _client.get(url, headers: headers);
    return _handle(resp);
  }

  @override
  Future<Map<String, dynamic>> patch(Uri url,
      {Map<String, String> headers = const {}, Object? body}) async {
    final resp = await _client
        .patch(url,
            headers: headers, body: body == null ? null : jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    return _handle(resp);
  }

  Map<String, dynamic> _handle(http.Response resp) {
    // The trace endpoint returns text/plain — keep as a synthetic map.
    if (!resp.body.trimLeft().startsWith('{')) {
      return {'text': resp.body};
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    return {'text': resp.body};
  }
}

/// Thin application-facing WARP facade.
class WarpService {
  WarpService({required this.registrar});

  final WarpRegistrar registrar;

  Future<WarpAccount> register() => registrar.register();
  Future<void> updateLicense(WarpAccount a, String key) =>
      registrar.updateLicense(a, key);
  Future<String> trace() => registrar.trace();
}
