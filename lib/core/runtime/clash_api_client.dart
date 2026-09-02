import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logger.dart';
import 'core_runtime.dart' show TrafficSnapshot;

/// Client for the sing-box Clash-compatible API (bound to 127.0.0.1).
///
/// Used for (Phase 4/5/24):
///  * selector switching   — PUT /proxies/{selector} {"name": tag}
///  * engine delay tests   — GET /proxies/{tag}/delay?url=&timeout=
///  * real traffic stats   — GET /connections  (uploadTotal/downloadTotal)
///  * health of the API itself — GET /version
class ClashApiClient {
  ClashApiClient({required this.port, required this.secret});

  final int port;
  final String secret;

  HttpClient? _client;

  HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  Uri _uri(String path, [Map<String, String>? q]) => Uri.http(
        '127.0.0.1:$port',
        path,
        q,
      );

  Map<String, String> get _headers => {
        if (secret.isNotEmpty) HttpHeaders.authorizationHeader: 'Bearer $secret',
        HttpHeaders.contentTypeHeader: 'application/json',
      };

  Future<Map<String, dynamic>?> _getJson(
    String path, {
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      final req = await _http.getUrl(_uri(path, query)).timeout(timeout);
      _headers.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close().timeout(timeout);
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (e) {
      Logger.instance.debug('clash-api', 'GET $path failed: $e');
      return null;
    }
  }

  Future<bool> isAlive() async {
    final v = await _getJson('/version', timeout: const Duration(seconds: 2));
    return v != null;
  }

  /// Cumulative counters from the connection tracker.
  Future<TrafficSnapshot?> connections() async {
    final j = await _getJson('/connections');
    if (j == null) return null;
    return TrafficSnapshot(
      upBytes: (j['uploadTotal'] as num?)?.toInt() ?? 0,
      downBytes: (j['downloadTotal'] as num?)?.toInt() ?? 0,
    );
  }

  /// Engine-measured latency (ms) for one outbound/selector tag.
  Future<int?> delayTest(String tag, String url, int timeoutMs) async {
    final j = await _getJson(
      '/proxies/${Uri.encodeComponent(tag)}/delay',
      query: {'url': url, 'timeout': '$timeoutMs'},
      timeout: Duration(milliseconds: timeoutMs + 1500),
    );
    if (j == null) return null;
    return (j['delay'] as num?)?.toInt();
  }

  /// Currently selected node of a selector (for state verification).
  Future<String?> selectedOf(String selector) async {
    final j = await _getJson('/proxies/${Uri.encodeComponent(selector)}');
    if (j == null) return null;
    return j['now'] as String?;
  }

  /// Hot-switch a selector outbound without restarting the engine (Phase 5).
  Future<bool> select(String selector, String name) async {
    try {
      final req = await _http
          .openUrl('PUT', _uri('/proxies/${Uri.encodeComponent(selector)}'));
      _headers.forEach((k, v) => req.headers.set(k, v));
      req.add(utf8.encode(jsonEncode({'name': name})));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      await resp.drain<void>();
      final ok = resp.statusCode == 200 || resp.statusCode == 204;
      if (ok) {
        Logger.instance.info('clash-api', 'selector "$selector" → $name');
      }
      return ok;
    } catch (e) {
      Logger.instance.warn('clash-api', 'select $selector → $name failed: $e');
      return false;
    }
  }

  void dispose() {
    _client?.close(force: true);
    _client = null;
  }
}
