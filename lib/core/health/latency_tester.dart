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
      sock.add([0x05, 0x01, 0x00]);
      var resp = await _readN(sock, 2, t);
      if (resp[0] != 0x05 || resp[1] != 0x00) {
        return ProbeResult(
            ok: false, errorKind: 'proxy', detail: 'SOCKS greeting rejected');
      }
      final host = utf8.encode(uri.host);
      final port = uri.port == 0 ? 443 : uri.port;
      sock.add([0x05, 0x01, 0x00, 0x03, host.length, ...host, port >> 8, port & 0xFF]);
      resp = await _readN(sock, 5, t);
      if (resp.length < 5 || resp[1] != 0x00) {
        return ProbeResult(
            ok: false,
            errorKind: 'proxy',
            detail: 'CONNECT failed (${resp.length > 1 ? resp[1] : '?'})');
      }
      final extra = switch (resp[3]) { 0x01 => 6, 0x03 => resp[4] + 2, 0x04 => 18, _ => 6 };
      if (extra > 0) await _readN(sock, extra, t);
      sock.add(utf8.encode(
          'GET ${uri.path.isEmpty ? '/' : uri.path} HTTP/1.1\r\n'
          'Host: ${uri.host}\r\n'
          'User-Agent: nexus-probe\r\n'
          'Connection: close\r\n\r\n'));
      final statusLine = await _readLine(sock, t);
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

  Future<List<int>> _readN(Socket s, int n, Duration t) async {
    final out = <int>[];
    await for (final chunk in s.timeout(t)) {
      out.addAll(chunk);
      if (out.length >= n) break;
    }
    return out.sublist(0, n.clamp(0, out.length));
  }

  Future<String> _readLine(Socket s, Duration t) async {
    final b = <int>[];
    await for (final chunk in s.timeout(t)) {
      for (final byte in chunk) {
        if (byte == 0x0A) return utf8.decode(b).trim();
        if (byte != 0x0D) b.add(byte);
      }
    }
    throw TimeoutException('http read');
  }
}
