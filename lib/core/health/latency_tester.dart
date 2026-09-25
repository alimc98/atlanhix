import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
      if (_isDnsFailure(e)) {
        // v0.4.9 §user-fix (ping broken for domain nodes): the carrier DNS
        // can't resolve the node hostname (poisoned/blocked) — every probe
        // died with a dns error while the node itself was fine. Retry ONCE
        // through a CLEAN resolver before declaring the node dead.
        final ip = await _resolveClean(host);
        if (ip != null && ip != host) {
          final again = await testTcp(ip, port, timeout: t);
          // Numeric IP → no DNS can fail in the retry, so this result is
          // the truth now: ok, or a genuine tcp/timeout — not "dns".
          return again;
        }
        return ProbeResult(ok: false, errorKind: 'dns', detail: e.message);
      }
      return ProbeResult(ok: false, errorKind: 'tcp', detail: e.message);
    } on TimeoutException {
      return ProbeResult(ok: false, errorKind: 'timeout', detail: 'connect timeout');
    }
  }

  // ── CLEAN DNS fallback (v0.4.9 §user) ─────────────────────────────────
  // System DNS on the carriers this app targets lies or fails outright; a
  // node hostname then reads as dead. A raw UDP A-record query (no new
  // dependencies) to 1.1.1.1, then 8.8.8.8, rescues the probe.

  static final Random _rng = Random.secure();

  static bool _isDnsFailure(SocketException e) {
    final msg = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    return msg.contains('host lookup') ||
        msg.contains('name or service not known') ||
        msg.contains('no address associated with hostname') ||
        msg.contains('nodename nor servname') ||
        msg.contains('no such host');
  }

  Future<String?> _resolveClean(String host) async {
    if (InternetAddress.tryParse(host) != null) return host;
    for (final resolver in const ['1.1.1.1', '8.8.8.8']) {
      final ip = await _udpDnsA(host, resolver);
      if (ip != null) return ip;
    }
    return null;
  }

  /// Minimal DNS client: one A-record question over UDP, first response
  /// with our transaction id wins. Null = timeout/error (filtering).
  Future<String?> _udpDnsA(
    String host,
    String resolver, {
    Duration timeout = const Duration(milliseconds: 1600),
  }) async {
    final name = host.trim().toLowerCase().replaceAll(RegExp(r'\.+$'), '');
    if (name.isEmpty) return null;
    final id = _rng.nextInt(0x10000);
    final q = BytesBuilder()
      ..addByte(id >> 8)
      ..addByte(id & 0xff)
      ..addByte(0x01) // flags: recursion desired
      ..addByte(0x00)
      ..addByte(0x00)
      ..addByte(0x01) // QDCOUNT
      ..addByte(0x00)
      ..addByte(0x00)
      ..addByte(0x00)
      ..addByte(0x00)
      ..addByte(0x00)
      ..addByte(0x00);
    for (final label in name.split('.')) {
      final lb = utf8.encode(label);
      if (lb.isEmpty || lb.length > 63) return null;
      q
        ..addByte(lb.length)
        ..add(lb);
    }
    q
      ..addByte(0) // root label
      ..addByte(0x00)
      ..addByte(0x01) // QTYPE A
      ..addByte(0x00)
      ..addByte(0x01); // QCLASS IN
    RawDatagramSocket? sock;
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock = s;
      s.send(q.takeBytes(), InternetAddress(resolver), 53);
      final done = Completer<String?>();
      final sub = s.listen((ev) {
        if (ev != RawSocketEvent.read || done.isCompleted) return;
        final d = s.receive();
        if (d == null) return;
        final ip = _parseDnsA(d.data, id);
        if (ip != null && !done.isCompleted) done.complete(ip);
      }, onError: (Object _) {
        if (!done.isCompleted) done.complete(null);
      }, onDone: () {
        if (!done.isCompleted) done.complete(null);
      });
      final ip = await done.future.timeout(timeout, onTimeout: () => null);
      await sub.cancel();
      return ip;
    } catch (_) {
      return null; // filtered resolver — caller tries the next one
    } finally {
      sock?.close();
    }
  }

  /// First A record in a DNS response whose id matches [expectId].
  static String? _parseDnsA(List<int> d, int expectId) {
    if (d.length < 12) return null;
    if (((d[0] << 8) | d[1]) != expectId) return null;
    final flags = (d[2] << 8) | d[3];
    if ((flags & 0x8000) == 0) return null; // not a response
    if ((flags & 0x000f) != 0) return null; // NXDOMAIN/SERVFAIL/…
    final qd = (d[4] << 8) | d[5];
    final an = (d[6] << 8) | d[7];
    var off = 12;
    for (var i = 0; i < qd; i++) {
      off = _skipDnsName(d, off);
      if (off < 0 || off + 4 > d.length) return null;
      off += 4;
    }
    for (var i = 0; i < an; i++) {
      off = _skipDnsName(d, off);
      if (off < 0 || off + 10 > d.length) return null;
      final type = (d[off] << 8) | d[off + 1];
      final rdlen = (d[off + 8] << 8) | d[off + 9];
      off += 10;
      if (off + rdlen > d.length) return null;
      if (type == 1 && rdlen == 4) {
        return '${d[off]}.${d[off + 1]}.${d[off + 2]}.${d[off + 3]}';
      }
      off += rdlen;
    }
    return null;
  }

  /// Returns the offset after a (possibly compressed) DNS name, or -1.
  static int _skipDnsName(List<int> d, int off) {
    while (true) {
      if (off >= d.length) return -1;
      final len = d[off];
      if (len == 0) return off + 1;
      if ((len & 0xc0) == 0xc0) return off + 2; // compression pointer
      off += 1 + len;
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
  ///
  /// v0.3.2 (live-subscription finding): rewritten on [RawSocket]/
  /// [RawSecureSocket]. The previous [Socket]+[SecureSocket.secure] upgrade
  /// was impossible once a stream subscription existed (Dart sockets are
  /// single-subscription), so every real HTTPS probe failed with
  /// `Connection terminated during handshake`.
  ///
  /// For https targets the TLS upgrade happens AFTER the SOCKS CONNECT via
  /// [RawSecureSocket.secure], with certificate verification ON.
  Future<ProbeResult> testHttpViaSocksProxy(String proxyHost, int proxyPort,
      String testUrl,
      {Duration? timeout}) async {
    final t = timeout ?? defaultTimeout;
    final uri = Uri.parse(testUrl);
    final sw = Stopwatch()..start();
    RawSocket? sock;
    try {
      sock = await RawSocket.connect(proxyHost, proxyPort, timeout: t);
      sock.setOption(SocketOption.tcpNoDelay, true);

      // SOCKS5 greeting: offer NO-AUTH.
      if (!_rawWrite(sock, [0x05, 0x01, 0x00])) {
        return ProbeResult(
            ok: false, errorKind: 'proxy', detail: 'write failed');
      }
      final greet = await _rawReadAtLeast(sock, 2, t);
      if (greet.length < 2 || greet[0] != 0x05 || greet[1] != 0x00) {
        return ProbeResult(
            ok: false, errorKind: 'proxy', detail: 'SOCKS greeting rejected');
      }
      // CONNECT host:port (domain → remote DNS resolution by design).
      final host = utf8.encode(uri.host);
      final port = uri.port == 0 ? 443 : uri.port;
      if (!_rawWrite(sock,
          [0x05, 0x01, 0x00, 0x03, host.length, ...host, port >> 8, port & 0xFF])) {
        return ProbeResult(
            ok: false, errorKind: 'proxy', detail: 'write failed');
      }
      final rep = await _rawReadAtLeast(sock, 5, t);
      if (rep.length < 5 || rep[1] != 0x00) {
        return ProbeResult(
            ok: false,
            errorKind: 'proxy',
            detail: 'CONNECT failed (${rep.length > 1 ? rep[1] : '?'})');
      }
      final extra = switch (rep[3]) {
        0x01 => 6,
        0x03 => rep[4] + 2,
        0x04 => 18,
        _ => 6,
      };
      if (extra - 5 > 0) await _rawReadAtLeast(sock, extra - 5, t);

      Object transport = sock;
      // TLS upgrade for https targets (certificate verification ON).
      if (uri.scheme == 'https') {
        try {
          // Drain any SOCKS reply bytes already buffered so they are not
          // misread as TLS records (RawSecureSocket has no drain; we must
          // ensure a clean stream — the SOCKS reply was already consumed by
          // _rawReadAtLeast above; a final poll ensures late bytes land).
          await Future<void>.delayed(const Duration(milliseconds: 25));
          sock.read(65536); // best-effort soak of any trailing bytes
          transport = await RawSecureSocket.secure(sock,
              host: uri.host, onBadCertificate: (_) => false);
        } on HandshakeException catch (e) {
          sock.close();
          return ProbeResult(ok: false, errorKind: 'tls', detail: e.message);
        } on SocketException catch (e) {
          sock.close();
          return ProbeResult(
              ok: false, errorKind: 'tls', detail: e.message);
        }
      }

      final request = utf8.encode(
          'GET ${uri.path.isEmpty ? '/' : uri.path} HTTP/1.1\r\n'
          'Host: ${uri.host}\r\n'
          'User-Agent: atlanhix-probe\r\n'
          'Connection: close\r\n\r\n');
      if (!_rawWrite(transport, request)) {
        return ProbeResult(
            ok: false, errorKind: 'http', detail: 'write failed');
      }
      final respBytes = await _rawReadUntilClosed(transport, t);
      final text = utf8.decode(respBytes, allowMalformed: true);
      final statusLine =
          text.split('\r\n').isEmpty ? '' : text.split('\r\n').first.trim();
      final codeMatch = RegExp(r'HTTP/\d(?:\.\d)?\s+(\d{3})').firstMatch(
          statusLine.isEmpty ? text : statusLine);
      final code = codeMatch != null
          ? int.parse(codeMatch.group(1)!)
          : (respBytes.isEmpty ? 0 : -1);
      sock.close();
      final ok = code >= 200 && code < 400;
      return ProbeResult(
        ok: ok,
        latencyMs: sw.elapsedMilliseconds,
        errorKind: ok ? null : (code == 0 ? 'timeout' : 'http'),
        detail: ok ? 'HTTP $code' : 'HTTP ${code == 0 ? 'NO-RESPONSE' : code} '
            'bytes=${respBytes.length}',
      );
    } catch (e) {
      sock?.close();
      return ProbeResult(
        ok: false,
        errorKind: e is TimeoutException ? 'timeout' : 'http',
        detail: e.toString(),
      );
    }
  }

  bool _rawWrite(Object transport, List<int> bytes) {
    // v0.3.2 hardening: RawSocket.write may accept a prefix — loop until the
    // whole request is out (partial writes previously corrupted probes).
    try {
      var written = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (written < bytes.length) {
        final n = transport is RawSecureSocket
            ? (transport as RawSecureSocket).write(bytes.sublist(written))
            : (transport as RawSocket).write(bytes.sublist(written));
        if (n > 0) {
          written += n;
          continue;
        }
        if (DateTime.now().isAfter(deadline)) return false;
        return false; // caller treats as failure; polling write is unsafe here
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Poll-reads until at least [n] bytes arrive (raw sockets have no stream
  /// subscriptions — the re-listen hazard does not apply).
  Future<List<int>> _rawReadAtLeast(
      RawSocket s, int n, Duration timeout) async {
    final stop = DateTime.now().add(timeout);
    final buf = <int>[];
    while (buf.length < n && DateTime.now().isBefore(stop)) {
      final chunk = s.read(n - buf.length);
      if (chunk != null && chunk.isNotEmpty) {
        buf.addAll(chunk);
        continue;
      }
      // RawSocket gotcha: after a null read, read events are disabled and
      // must be re-enabled or every subsequent read() returns null.
      s.readEventsEnabled = true;
      await Future<void>.delayed(const Duration(milliseconds: 4));
    }
    return buf;
  }

  /// Poll-reads until headers complete, the connection closes, or timeout.
  Future<List<int>> _rawReadUntilClosed(
      Object transport, Duration timeout) async {
    final stop = DateTime.now().add(timeout);
    final buf = <int>[];
    final RawSocket s =
        transport is RawSecureSocket ? transport : transport as RawSocket;
    while (DateTime.now().isBefore(stop)) {
      final chunk = s.read(65536);
      if (chunk == null) {
        s.readEventsEnabled = true;
        await Future<void>.delayed(const Duration(milliseconds: 4));
        continue;
      }
      if (chunk.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 4));
        continue;
      }
      buf.addAll(chunk);
      final t = utf8.decode(buf, allowMalformed: true);
      if (t.contains('\r\n\r\n')) break; // headers complete — enough for 204
    }
    return buf;
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

  /// Releases the raw subscription so a TLS upgrade can re-listen the
  /// underlying socket (v0.3.2 — required before SecureSocket.secure).
  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
  }

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
