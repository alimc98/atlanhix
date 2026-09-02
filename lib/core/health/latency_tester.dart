import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One connectivity probe result.
class ProbeResult {
  ProbeResult({
    required this.ok,
    this.latencyMs,
    this.handshakeMs,
    this.errorKind,
    this.detail,
  });

  final bool ok;
  final int? latencyMs;
  final int? handshakeMs;
  final String? errorKind; // dns | tcp | tls | http | proxy | timeout
  final String? detail;
}

/// Layered probing: TCP connect, TLS handshake, HTTP via local SOCKS5 proxy.
class LatencyTester {
  LatencyTester({this.defaultTimeout = const Duration(seconds: 5)});

  final Duration defaultTimeout;

  Future<ProbeResult> testTcp(String host, int port, {Duration? timeout}) async {
    final t = timeout ?? defaultTimeout;
    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, port, timeout: t);
      sw.stop();
      socket.destroy();
      return ProbeResult(ok: true, latencyMs: sw.elapsedMilliseconds);
    } on SocketException catch (e) {
      final isDns = e.osError == null && e.message.contains('Failed host lookup');
      return ProbeResult(
          ok: false, errorKind: isDns ? 'dns' : 'tcp', detail: e.message);
    } on TimeoutException {
      return ProbeResult(ok: false, errorKind: 'timeout', detail: 'connect timeout');
    }
  }

  Future<ProbeResult> testTls(String host, int port,
      {Duration? timeout, bool allowBadCert = false}) async {
    final t = timeout ?? defaultTimeout;
    final sw = Stopwatch()..start();
    SecureSocket? secure;
    try {
      final raw = await Socket.connect(host, port, timeout: t);
      secure = await SecureSocket.secure(raw,
          host: host, onBadCertificate: (_) => allowBadCert);
      sw.stop();
      secure.destroy();
      return ProbeResult(ok: true, handshakeMs: sw.elapsedMilliseconds);
    } catch (e) {
      secure?.destroy();
      return ProbeResult(
        ok: false,
        errorKind: e is HandshakeException ? 'tls' : 'tcp',
        detail: e.toString(),
      );
    }
  }

  /// HTTP probe through a SOCKS5 proxy — genuine end-to-end success.
  Future<ProbeResult> testHttpViaSocksProxy(String proxyHost, int proxyPort,
      String testUrl,
      {Duration? timeout}) async {
    final t = timeout ?? defaultTimeout;
    final uri = Uri.parse(testUrl);
    final sw = Stopwatch()..start();
    Socket? sock;
    try {
      sock = await Socket.connect(proxyHost, proxyPort, timeout: t);
      final reader = _SockReader(sock);
      sock.add([0x05, 0x01, 0x00]);
      final greet = await reader.waitAndTake(2, t);
      if (greet.length < 2 || greet[0] != 0x05 || greet[1] != 0x00) {
        return ProbeResult(
            ok: false, errorKind: 'proxy', detail: 'SOCKS greeting rejected');
      }
      final host = utf8.encode(uri.host);
      final port = uri.port == 0 ? 443 : uri.port;
      sock.add([0x05, 0x01, 0x00, 0x03, host.length, ...host, port >> 8, port & 0xFF]);
      final rep = await reader.waitAndTake(5, t);
      if (rep.length < 5 || rep[1] != 0x00) {
        return ProbeResult(
            ok: false,
            errorKind: 'proxy',
            detail: 'CONNECT failed (${rep.length > 1 ? rep[1] : '?'})');
      }
      final extra = switch (rep[3]) { 0x01 => 6, 0x03 => rep[4] + 2, 0x04 => 18, _ => 6 };
      if (extra > 0) await reader.waitAndTake(extra, t);
      sock.add(utf8.encode(
          'GET ${uri.path.isEmpty ? '/' : uri.path} HTTP/1.1\r\n'
          'Host: ${uri.host}\r\n'
          'User-Agent: nexus-probe\r\n'
          'Connection: close\r\n\r\n'));
      final statusLine = await reader.readLine(t);
      sw.stop();
      final code = int.tryParse(statusLine.split(' ').elementAt(1)) ?? 0;
      sock.destroy();
      final ok = code >= 200 && code < 400;
      return ProbeResult(
        ok: ok,
        latencyMs: sw.elapsedMilliseconds,
        errorKind: ok ? null : 'http',
        detail: 'HTTP $code',
      );
    } catch (e) {
      sock?.destroy();
      return ProbeResult(
        ok: false,
        errorKind: e is TimeoutException ? 'timeout' : 'http',
        detail: e.toString(),
      );
    }
  }

  /// sing-box Clash-API delay test when available.
  Future<ProbeResult?> testViaClashApi({
    required int apiPort,
    required String apiSecret,
    required String proxyTag,
    required String testUrl,
    Duration? timeout,
  }) async {
    final t = timeout ?? defaultTimeout;
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = t;
      final req = await client.getUrl(Uri.parse(
          'http://127.0.0.1:$apiPort/proxies/${Uri.encodeComponent(proxyTag)}/delay?url=${Uri.encodeComponent(testUrl)}&timeout=${t.inMilliseconds}'));
      if (apiSecret.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiSecret');
      }
      final resp = await req.close().timeout(t);
      final body = await resp.transform(utf8.decoder).join().timeout(t);
      if (resp.statusCode == 200) {
        final delay = jsonDecode(body)['delay'];
        return ProbeResult(ok: true, latencyMs: delay is int ? delay : null);
      }
      return ProbeResult(ok: false, errorKind: 'http', detail: body);
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}

/// Single-subscription-safe socket reader: pumps the socket stream ONCE and
/// lets callers take bytes as they arrive. (Fixes the double-listen crash
/// found by the runtime integration tests.)
class _SockReader {
  _SockReader(Socket s) {
    _sub = s.listen(
      (chunk) => _buf.addAll(chunk),
      onDone: () => _done = true,
      onError: (Object _) => _done = true,
      cancelOnError: false,
    );
  }

  final List<int> _buf = [];
  StreamSubscription<List<int>>? _sub;
  bool _done = false;

  /// Waits until at least [n] bytes are buffered, the stream ends, or the
  /// timeout passes. Returns (and consumes) the first bytes.
  Future<List<int>> waitAndTake(int n, Duration timeout) async {
    final stop = DateTime.now().add(timeout);
    while (_buf.length < n && !_done && DateTime.now().isBefore(stop)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final take = _buf.length < n ? _buf.length : n;
    final out = _buf.sublist(0, take);
    _buf.removeRange(0, take);
    return out;
  }

  /// Reads buffered bytes until CRLF (HTTP status line).
  Future<String> readLine(Duration timeout) async {
    final stop = DateTime.now().add(timeout);
    while (!_done && DateTime.now().isBefore(stop)) {
      final idx = _findCrlf();
      if (idx >= 0) {
        final line = utf8.decode(_buf.sublist(0, idx));
        _buf.removeRange(0, idx + 2);
        return line.trim();
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return utf8.decode(_buf, allowMalformed: true).trim();
  }

  int _findCrlf() {
    for (var i = 0; i + 1 < _buf.length; i++) {
      if (_buf[i] == 0x0D && _buf[i + 1] == 0x0A) return i;
    }
    return -1;
  }
}
