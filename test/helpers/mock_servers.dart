import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Deterministic test topology for v0.2.1 E2E (no external network needed).
///
/// [MockSocksServer] — a real SOCKS5 CONNECT server that records every
/// upstream target and pipes bytes to the destination. Used both as:
///  * the "remote proxy server" an engine dials into, and
///  * the traffic-path witness (records which upstream was traversed).
class MockSocksServer {
  MockSocksServer();

  ServerSocket? _server;
  final List<String> connectTargets = [];
  int connections = 0;

  int get port => _server!.port;
  bool get isRunning => _server != null;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleClient);
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  void _handleClient(Socket client) {
    connections++;
    // Single-listener state machine: ONE subscription for the socket's whole
    // lifetime (Dart socket streams cannot be re-listened after cancel —
    // verified by the earlier test failures).
    final buf = <int>[]; // handshake buffer
    var handshakeDone = false;
    Socket? dest;
    final pending = <int>[]; // app data after handshake, before dest ready

    client.listen((chunk) {
      if (dest != null) {
        // Phase PIPE: forward client → destination.
        dest!.add(chunk);
        return;
      }
      buf.addAll(chunk);
      if (!handshakeDone) {
        // Phase HANDSHAKE: accumulate until the full SOCKS5 request is here.
        if (buf.length < 2) return;
        final nmethods = buf[1];
        if (buf.length < 2 + nmethods) return;
        final off = 2 + nmethods;
        if (buf.length < off + 5) return;
        final atyp = buf[off + 3];
        final need = switch (atyp) {
          0x01 => 4 + 6,
          0x03 => 1 + buf[off + 4] + 6,
          0x04 => 16 + 6,
          _ => 0,
        };
        if (need == 0) {
          client.destroy();
          return;
        }
        if (buf.length < off + need) return;

        var aoff = off + 4;
        String host;
        int dport;
        if (atyp == 0x01) {
          host = buf.sublist(aoff, aoff + 4).join('.');
          aoff += 4;
        } else if (atyp == 0x03) {
          final l = buf[aoff];
          aoff += 1;
          host = utf8.decode(buf.sublist(aoff, aoff + l));
          aoff += l;
        } else {
          host = List.generate(
                  8, (i) => (buf[aoff + i * 2] << 8 | buf[aoff + i * 2 + 1])
                      .toRadixString(16))
              .join(':');
          aoff += 16;
        }
        dport = (buf[aoff] << 8) | buf[aoff + 1];
        connectTargets.add('$host:$dport');
        handshakeDone = true;

        // Application data that arrived together with the handshake.
        final appDataOff = aoff + 2;
        if (appDataOff < buf.length) {
          pending.addAll(buf.sublist(appDataOff));
        }
        buf.clear();
        client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);

        // Dial asynchronously; further client chunks land in `pending`
        // (dest is still null) and are flushed on connect.
        Socket.connect(host, dport, timeout: const Duration(seconds: 5))
            .then((d) {
          dest = d;
          d.listen((dd) => client.add(dd),
              onDone: () => client.destroy(),
              onError: (Object _) => client.destroy());
          if (pending.isNotEmpty) {
            d.add(List<int>.from(pending));
            pending.clear();
          }
        }).catchError((Object _) {
          client.add([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
          client.destroy();
        });
      } else {
        // Handshake parsed, destination not connected yet — buffer.
        pending.addAll(chunk);
      }
    }, onDone: () {
      dest?.destroy();
    }, onError: (Object _) {
      dest?.destroy();
    });
  }
}

/// Minimal HTTP server for deterministic destinations. Returns a marker
/// body so tests can assert the response actually traversed the topology.
class MockHttpServer {
  MockHttpServer();

  HttpServer? _server;
  final List<String> requests = [];

  int get port => _server!.port;
  bool get isRunning => _server != null;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      requests.add('${req.method} ${req.uri.path}');
      req.response.headers.contentType = ContentType.text;
      req.response.write('NEXUS-E2E-OK path=${req.uri.path}');
      await req.response.close();
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}

/// Fetches the current external IP via Cloudflare trace (internet optional).
Future<String?> fetchExternalIp() async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    final req = await client
        .getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
        .timeout(const Duration(seconds: 8));
    final resp = await req.close().timeout(const Duration(seconds: 8));
    final body = await resp.transform(utf8.decoder).join();
    client.close(force: true);
    final m = RegExp(r'ip=(.+)').firstMatch(body);
    return m?.group(1)?.trim();
  } catch (_) {
    return null;
  }
}
