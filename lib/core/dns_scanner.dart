import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// v0.4.1 — real DNS resolver scanner (§ user request: "اسکن dns").
///
/// Probes resolver candidates over UDP/53, TCP/53 and DoH (HTTPS) FROM THE
/// DEVICE'S OWN NETWORK — the only environment where carrier blocking and
/// DNS poisoning are observable. Every claim it makes is measured, never
/// hardcoded:
///   * reachable?        — a well-formed answer arrived within the timeout
///   * latency           — wall time from first byte sent to first byte of
///                         the answer
///   * answers           — the A/AAAA records the resolver actually returned
///   * poison verdict    — a public test hostname answered with a
///                         private/link-local/reserved address is the
///                         documented carrier sinkhole pattern
///                         (measured on Mi 9T / MCI: blocked domains →
///                         10.10.34.36), so the resolver is flagged SUSPECT
///                         even though it "answered".
class DnsProbeTarget {
  const DnsProbeTarget({
    required this.name,
    required this.host,
    this.port = 53,
    this.transport = DnsTransport.udp,
    this.dohPath,
    this.note = '',
  });

  final String name;
  final String host;
  final int port;
  final DnsTransport transport;

  /// DoH only: the URL path (e.g. /dns-query).
  final String? dohPath;
  final String note;

  String get label => switch (transport) {
        DnsTransport.udp => '$name (UDP:$port)',
        DnsTransport.tcp => '$name (TCP:$port)',
        DnsTransport.doh => '$name (DoH:$port)',
      };
}

enum DnsTransport { udp, tcp, doh }

enum DnsPoisonVerdict {
  /// Answers look sane (public addresses for public names).
  clean,

  /// A public test hostname resolved to a private/link-local/reserved IP —
  /// the carrier sinkhole signature. Answers cannot be trusted.
  sinkhole,

  /// No answer / malformed — unusable from this network.
  unreachable,
}

class DnsProbeResult {
  const DnsProbeResult({
    required this.target,
    required this.verdict,
    this.latencyMs,
    this.answers = const [],
    this.error,
  });

  final DnsProbeTarget target;
  final DnsPoisonVerdict verdict;
  final int? latencyMs;
  final List<String> answers;
  final String? error;

  bool get reachable => verdict != DnsPoisonVerdict.unreachable;

  Map<String, dynamic> toJson() => {
        'name': target.name,
        'host': target.host,
        'transport': target.transport.name,
        'verdict': verdict.name,
        'latencyMs': latencyMs,
        'answers': answers,
        if (error != null) 'error': error,
      };

  @override
  String toString() =>
      '${target.label}: ${verdict.name}'
      '${latencyMs != null ? ' ${latencyMs}ms' : ''}'
      '${answers.isNotEmpty ? ' → ${answers.join(", ")}' : ''}'
      '${error != null ? " ($error)" : ''}';
}

class DnsScanner {
  DnsScanner({this.timeout = const Duration(seconds: 3)});

  /// Clean domestic resolver measured reachable over UDP/53 from MCI mobile
  /// data (Shecan) — used to resolve carrier-poisoned node/subscription hosts.
  static const cleanResolverIp = '178.22.122.100';

  final Duration timeout;

  /// Public hostnames whose REAL answers are always public unicast space.
  /// A private/loopback/link-local answer for any of them is a poisoning
  /// sinkhole (measured pattern: MCI answers blocked domains with
  /// 10.10.34.36). `www.google.com` is reachable unfiltered on IR carriers
  /// and serves as the honest-latency probe.
  static const _testNames = [
    'www.google.com',
    'graph.facebook.com',
    'test-gateway.instagram.com',
  ];

  Future<DnsProbeResult> probe(DnsProbeTarget t) async {
    switch (t.transport) {
      case DnsTransport.udp:
        return _probeSocket(t, udp: true);
      case DnsTransport.tcp:
        return _probeSocket(t, udp: false);
      case DnsTransport.doh:
        return _probeDoh(t);
    }
  }

  /// Scan a list concurrently (bounded fan-out; resolvers are independent).
  Future<List<DnsProbeResult>> scan(List<DnsProbeTarget> targets,
      {void Function(DnsProbeResult)? onResult, int concurrency = 6}) async {
    final results = <DnsProbeResult>[];
    var i = 0;
    Future<void> worker() async {
      while (true) {
        final k = i++;
        if (k >= targets.length) return;
        final r = await probe(targets[k]);
        results.add(r);
        onResult?.call(r);
      }
    }

    await Future.wait([
      for (var w = 0; w < concurrency.clamp(1, targets.length); w++) worker(),
    ]);
    // Stable display order = input order.
    results.sort((a, b) => targets
        .indexOf(a.target)
        .compareTo(targets.indexOf(b.target)));
    return results;
  }

  // ------------------------------------------------------------- transports

  Future<DnsProbeResult> _probeSocket(DnsProbeTarget t,
      {required bool udp}) async {
    final sw = Stopwatch()..start();
    InternetAddress host;
    try {
      host = InternetAddress.tryParse(t.host) ??
          (await InternetAddress.lookup(t.host).then((l) => l.first));
    } catch (_) {
      return DnsProbeResult(
          target: t,
          verdict: DnsPoisonVerdict.unreachable,
          error: 'resolver host itself does not resolve');
    }
    final addr = host;
    final queries = [
      for (final n in _testNames) _buildQuery(n, _typeOf(n))
    ];
    final answers = <String>[];
    var sinkhole = false;
    try {
      if (udp) {
        final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        try {
          for (final q in queries) {
            sock.send(q.bytes, addr, t.port);
          }
          final seen = <int>{};
          final completer = Completer<void>();
          try {
            final done = completer.future.timeout(timeout);
            sock.listen((e) {
              if (e != RawSocketEvent.read) return;
              final dg = sock.receive();
              if (dg == null || dg.data.length < 2) return;
              final pkt = dg.data;
              final id = (pkt[0] << 8) | pkt[1];
              if (seen.contains(id)) return;
              seen.add(id);
              _absorb(pkt, answers, () => sinkhole = true);
              if (seen.length >= queries.length && !completer.isCompleted) {
                completer.complete();
              }
            });
            await done;
          } on TimeoutException {
            // Partial answers are still an answer — verdict below decides.
          }
        } finally {
          sock.close();
        }
      } else {
        final sock = await Socket.connect(addr, t.port, timeout: timeout);
        try {
          for (final q in queries) {
            // 2-byte big-endian TCP message length prefix, then the query.
            sock.add([q.bytes.length >> 8, q.bytes.length & 0xFF]);
            sock.add(q.bytes);
          }
          await sock.flush();
          final buf = BytesBuilder();
          try {
            await for (final chunk in sock.timeout(timeout)) {
              buf.add(chunk);
            }
          } on TimeoutException {
            // fall through: parse whatever arrived
          }
          final data = buf.takeBytes();
          var off = 0;
          while (off + 2 <= data.length) {
            final mlen = (data[off] << 8) | data[off + 1];
            if (mlen == 0 || off + 2 + mlen > data.length) break;
            _absorb(data.sublist(off + 2, off + 2 + mlen), answers,
                () => sinkhole = true);
            off += 2 + mlen;
          }
        } finally {
          sock.destroy();
        }
      }
    } catch (e) {
      return DnsProbeResult(
          target: t,
          verdict: DnsPoisonVerdict.unreachable,
          error: _short(e),
          latencyMs: sw.elapsedMilliseconds);
    }
    sw.stop();
    if (answers.isEmpty) {
      return DnsProbeResult(
          target: t,
          verdict: DnsPoisonVerdict.unreachable,
          error: 'no answer within ${timeout.inSeconds}s');
    }
    return DnsProbeResult(
      target: t,
      verdict: sinkhole
          ? DnsPoisonVerdict.sinkhole
          : DnsPoisonVerdict.clean,
      latencyMs: sw.elapsedMilliseconds,
      answers: answers,
    );
  }

  Future<DnsProbeResult> _probeDoh(DnsProbeTarget t) async {
    final sw = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = (_, __, ___) => false;
    final answers = <String>[];
    var sinkhole = false;
    try {
      final url = Uri(
        scheme: 'https',
        host: t.host,
        port: t.port,
        path: t.dohPath ?? '/dns-query',
        queryParameters: {'name': _testNames.first, 'type': 'A'},
      );
      final req = await client.getUrl(url).timeout(timeout);
      req.headers.set('accept', 'application/dns-json');
      final res = await req.close().timeout(timeout);
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      for (final a in (json['Answer'] as List? ?? const [])) {
        final m = a as Map<String, dynamic>;
        final data = m['data']?.toString() ?? '';
        if (m['type'] == 5 || m['type'] == 28) answers.add(data);
        if (m['type'] == 1 && isNonPublic(data)) sinkhole = true;
      }
    } catch (e) {
      return DnsProbeResult(
          target: t,
          verdict: DnsPoisonVerdict.unreachable,
          error: _short(e),
          latencyMs: sw.elapsedMilliseconds);
    } finally {
      client.close(force: true);
    }
    sw.stop();
    if (answers.isEmpty) {
      return DnsProbeResult(
          target: t,
          verdict: DnsPoisonVerdict.unreachable,
          error: 'DoH returned no answers');
    }
    return DnsProbeResult(
      target: t,
      verdict: sinkhole
          ? DnsPoisonVerdict.sinkhole
          : DnsPoisonVerdict.clean,
      latencyMs: sw.elapsedMilliseconds,
      answers: answers,
    );
  }

  // -------------------------------------------------------------- DNS wire

  static int _typeOf(String name) => 1; // A — the poisoning signature is IPv4

  /// Absorb one DNS response: collect A/AAAA answers and flag private-space
  /// answers for our public test names.
  static void _absorb(List<int> pkt, List<String> answers,
      void Function() onSinkhole) {
    if (pkt.length < 12) return;
    final ancount = (pkt[6] << 8) | pkt[7];
    if (ancount == 0) return;
    var i = 12;
    // skip QNAME
    while (i < pkt.length && pkt[i] != 0) {
      if ((pkt[i] & 0xC0) == 0xC0) {
        i += 2;
        break;
      }
      i += 1 + pkt[i];
    }
    i += 5; // null byte + qtype + qclass
    for (var n = 0; n < ancount && i + 10 <= pkt.length; n++) {
      // NAME (possibly compressed)
      if ((pkt[i] & 0xC0) == 0xC0) {
        i += 2;
      } else {
        while (i < pkt.length && pkt[i] != 0) {
          i += 1 + pkt[i];
        }
        i += 1;
      }
      if (i + 8 > pkt.length) return;
      final type = (pkt[i] << 8) | pkt[i + 1];
      final rdlen = (pkt[i + 8] << 8) | pkt[i + 9];
      i += 10;
      if (i + rdlen > pkt.length) return;
      if (type == 1 && rdlen == 4) {
        final ip = '${pkt[i]}.${pkt[i + 1]}.${pkt[i + 2]}.${pkt[i + 3]}';
        answers.add(ip);
        if (isNonPublic(ip)) onSinkhole();
      } else if (type == 28 && rdlen == 16) {
        final b = pkt.sublist(i, i + 16);
        final parts = <String>[];
        for (var j = 0; j < 16; j += 2) {
          parts.add(((b[j] << 8) | b[j + 1]).toRadixString(16));
        }
        answers.add(parts.join(':'));
      }
      i += rdlen;
    }
  }

  /// RFC 1918 / loopback / link-local / CGNAT / benchmark space — none of
  /// these can be a real internet address for google/facebook/instagram.
  /// Public so the Settings UI and tests share ONE definition of "this
  /// answer is poisoned".
  static bool isNonPublic(String ip) {
    final o = ip.split('.').map(int.tryParse).toList();
    if (o.length != 4 || o.any((e) => e == null)) {
      // v6: unique-local fc00::/7 (the fakeip range we ship) is fine inside
      // fakeip mode but as a REAL answer it indicates a poisoned/local reply.
      return ip.startsWith('fc') || ip.startsWith('fd') || ip == '::1';
    }
    final a = o[0]!, b = o[1]!;
    return a == 10 ||
        a == 127 ||
        a == 0 ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 198 && (b == 18 || b == 19));
  }

  /// Direct A-record lookup of [name] through a (clean) resolver — the
  /// subscription path needs real IPs for domains the carrier poisons
  /// (MCI returns 10.10.34.36 or times out for blocked hosts). Returns
  /// public IPv4 answers only; empty on failure.
  Future<List<String>> resolve(String name,
      {String server = '178.22.122.100', int port = 53, bool tcp = false}) async {
    final answers = <String>[];
    try {
      final host = InternetAddress(server);
      final q = _buildQuery(name, 1);
      if (tcp) {
        // TCP/53: MCI transparently intercepts UDP/53 (answers with the
        // sinkhole) but leaves TCP DNS alone (device-verified 2026-09-15:
        // Shecan UDP='no answer' while the same name resolves over TCP).
        final sock = await Socket.connect(host, port, timeout: timeout);
        try {
          sock.add([q.bytes.length >> 8, q.bytes.length & 0xFF]);
          sock.add(q.bytes);
          await sock.flush();
          final buf = BytesBuilder();
          final deadline = DateTime.now().add(timeout);
          await for (final chunk in sock
              .timeout(timeout, onTimeout: (s) => s.close())) {
            buf.add(chunk);
            // TCP DNS servers keep the connection OPEN — without an
            // early exit every lookup burned the full timeout even
            // though the answer had arrived (device: 3.0s of pure
            // stall, then flaky 3.1s failures raced the connect
            // deadline). Parse what's buffered and bail on the first
            // real answer.
            if (DateTime.now().isAfter(deadline)) break;
            final data = buf.toBytes();
            var probeOff = 0;
            var ready = false;
            while (probeOff + 2 <= data.length) {
              final ml = (data[probeOff] << 8) | data[probeOff + 1];
              if (ml == 0 || probeOff + 2 + ml > data.length) break;
              final probe = <String>[];
              _absorb(
                  data.sublist(probeOff + 2, probeOff + 2 + ml), probe, () {});
              if (probe.isNotEmpty) {
                answers.addAll(probe);
                ready = true;
                break;
              }
              probeOff += 2 + ml;
            }
            if (ready) break;
          }
          final data = buf.takeBytes();
          var off = 0;
          while (off + 2 <= data.length) {
            final mlen = (data[off] << 8) | data[off + 1];
            if (mlen == 0 || off + 2 + mlen > data.length) break;
            _absorb(data.sublist(off + 2, off + 2 + mlen), answers, () {});
            off += 2 + mlen;
          }
        } finally {
          sock.destroy();
        }
      } else {
        final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        final done = Completer<void>();
        try {
          sock.listen((e) {
            if (e != RawSocketEvent.read) return;
            final dg = sock.receive();
            if (dg == null || dg.data.length < 13) return;
            _absorb(dg.data, answers, () {});
            // MCI's transparent UDP/53 interceptor sometimes answers with a
            // ZERO-ANSWER packet first (device 2026-09-15: app saw 'no
            // answer' while `nc` to the same resolver got ANCOUNT=2). Only
            // a real answer completes the wait — keep listening otherwise.
            if (answers.isNotEmpty && !done.isCompleted) done.complete();
          });
          sock.send(q.bytes, host, port);
          await done.future.timeout(timeout, onTimeout: () {});
        } finally {
          sock.close();
        }
      }
    } catch (_) {/* unreachable resolver — caller falls back */}
    return answers.where((a) => !isNonPublic(a)).toList();
  }

  static _Query _buildQuery(String name, int type) {
    final id = Uint16List(1);
    final rnd = DateTime.now().microsecondsSinceEpoch & 0xFFFF;
    id[0] = rnd;
    final hdr = Uint8List(12);
    hdr[0] = rnd >> 8;
    hdr[1] = rnd & 0xFF;
    hdr[2] = 0x01; // RD
    hdr[4] = 0;
    hdr[5] = 1; // QDCOUNT
    final q = <int>[];
    for (final part in name.split('.')) {
      q.add(part.length);
      q.addAll(utf8.encode(part));
    }
    q.add(0);
    q.addAll([0, type, 0, 1]);
    return _Query(rnd, Uint8List.fromList(hdr + q));
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }
}

class _Query {
  const _Query(this.id, this.bytes);
  final int id;
  final Uint8List bytes;
}
