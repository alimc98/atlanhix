import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../dns_scanner.dart';
import '../logger.dart';

/// An [http.Client] that resolves hostnames through a clean resolver instead
/// of the carrier's poisoned system one — while keeping TLS SNI + certificate
/// validation against the ORIGINAL hostname.
///
/// Why: on Iran MCI the subscription host (and several node hosts) resolve to
/// a sinkhole or time out at the system resolver, so a plain `package:http`
/// GET dies with a 20s TimeoutException, yet the SAME host answers instantly
/// when dialed by its clean-DNS IP (measured 2026-09-15: connecting to
/// 185.143.234.238 with SNI n2.meta-design.ir returns in <1s; system resolver
/// = timeout). This is what made "update subscription" stop working.
///
/// Every request gets its own [HttpClient] with a `connectionFactory` that
/// dials the pinned IP, so no mutable state is shared across requests. If the
/// clean lookup yields nothing we fall back to the platform resolver — so this
/// is never worse than a plain `http.Client`.
class CleanDnsClient extends http.BaseClient {
  CleanDnsClient({
    String resolver = DnsScanner.cleanResolverIp,
    Duration pinTtl = const Duration(minutes: 10),
    Duration lookupTimeout = const Duration(seconds: 6),
  })  : _resolver = resolver,
        _ttl = pinTtl,
        _lookupTimeout = lookupTimeout;

  /// Fallback clean resolvers tried in order (UDP/53) when the primary one
  /// is unreachable from the network — measured on MCI 2026-09-15: Shecan
  /// sometimes times out while Begzar answers.
  static const _resolvers = [
    DnsScanner.cleanResolverIp, // Shecan (domestic, clean for blocked names)
    '185.55.226.26', // Begzar (domestic)
    '94.103.125.150', // 403.online (domestic)
    '8.8.8.8', // Google (user request 2026-09-15 — measured blocked on
    '1.1.1.1', // Cloudflare — last resort, UDP+TCP both attempted)
  ];

  final String _resolver;
  final Duration _ttl;
  final Duration _lookupTimeout;
  final Map<String, _Pin> _pins = {};

  /// The IP currently pinned for [host], or null (diagnostics/tests).
  String? pinnedIp(String host) {
    final p = _pins[host];
    if (p == null) return null;
    if (DateTime.now().difference(p.at) > _ttl) return null;
    return p.ip;
  }

  Future<String?> _pinFor(String host) async {
    if (InternetAddress.tryParse(host) != null) return null; // already an IP
    final now = DateTime.now();
    final cached = _pins[host];
    if (cached != null && now.difference(cached.at) <= _ttl) return cached.ip;
    // Total lookup budget: never spend longer than one fetch window on DNS.
    final budget = Stopwatch()..start();
    const maxBudget = Duration(seconds: 14);
    for (final attempt in [
      for (final server in [_resolver, ..._resolvers]) (server, false),
      // UDP/53 is intercepted+poisoned by MCI; TCP/53 is not (device
      // verified). Try every resolver over UDP first, then TCP.
      for (final server in [_resolver, ..._resolvers]) (server, true),
    ]) {
      final server = attempt.$1;
      final useTcp = attempt.$2;
      if (budget.elapsed > maxBudget) {
        Logger.instance.info('cleandns', 'budget spent for $host');
        break;
      }
      try {
        final ips = await DnsScanner(timeout: _lookupTimeout)
            .resolve(host, server: server, tcp: useTcp)
            .timeout(_lookupTimeout + const Duration(seconds: 2));
        if (ips.isEmpty) {
          Logger.instance.info('cleandns', '$host via $server: no answer');
          continue;
        }
        _pins[host] = _Pin(ips.first, now);
        Logger.instance.info('cleandns', '$host -> ${ips.first} via $server');
        return ips.first;
      } catch (e) {
        Logger.instance.info('cleandns', '$host via $server: $e');
      }
    }
    Logger.instance.info('cleandns', 'no clean answer for $host — system DNS');
    return null;
  }

  IOClient _clientFor(String? ip) {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (ip != null) {
      c.connectionFactory = (Uri target, String? viaHost, int? viaPort) {
        final port = viaPort ?? target.port;
        final host = viaHost ?? target.host;
        Future<Socket> sock = Socket.connect(InternetAddress(ip), port,
            timeout: const Duration(seconds: 8));
        if (target.scheme == 'https') {
          // The target URI still carries the REAL hostname, so SNI + cert
          // chain validation happen against it even though we dial [ip].
          sock = sock.then((s) => SecureSocket.secure(
            s,
            context: SecurityContext(withTrustedRoots: true),
            host: host,
            onBadCertificate: (_) => false,
            supportedProtocols: const ['http/1.1'],
          ));
        }
        Socket? settled;
        final shared = sock.then((s) {
          settled = s;
          return s;
        });
        return shared.then((s) => ConnectionTask.fromSocket(
            Future<Socket>.value(s), () => settled?.destroy()));
      };
    }
    return IOClient(c);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final host = request.url.host;
    final ip = await _pinFor(host);
    final client = _clientFor(ip);
    final streamed = await client.send(request);
    // Keep the per-request client alive until the body is fully drained —
    // closing earlier would reset the socket mid-response.
    final controller = StreamController<List<int>>();
    streamed.stream.listen(
      controller.add,
      onDone: () {
        client.close();
        controller.close();
      },
      onError: (Object e, StackTrace s) {
        client.close();
        controller.addError(e, s);
      },
      cancelOnError: false,
    );
    return http.StreamedResponse(
      controller.stream,
      streamed.statusCode,
      contentLength: streamed.contentLength,
      request: streamed.request,
      headers: streamed.headers,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  @override
  void close() {}
}

class _Pin {
  const _Pin(this.ip, this.at);
  final String ip;
  final DateTime at;
}
