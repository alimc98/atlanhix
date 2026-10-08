import 'dart:async';
import 'dart:io';

import '../../domain/entities/proxy_profile.dart';
import '../dns_scanner.dart';

/// Bootstrap resolution — resolve a node hostname OUTSIDE the tunnel and
/// pin the verified public IPv4 into the generated config.
///
/// Why (device evidence, Mi 9T / MCI, 2026-09-15): sing-box logs
/// `lookup <node-domain>: context deadline exceeded` — resolving the
/// node's own domain THROUGH the tunnel it owns deadlocks; and the
/// carrier resolver poison-answers blocked hosts with sinkholes
/// (private 10.10.34.36 for A, a 6to4 address embedding it for AAAA).
/// Pinning a clean-resolved public IP removes the lookup from the
/// tunnel path entirely — the same trick v2rayNG `direct-vpn` and every
/// mature Iran client use. SNI/server_name still carry the hostname
/// (the generators emit `sni ?? host`), so TLS/Reality are unaffected.
///
/// Trust order:
///  1. clean UDP resolvers (Shecan/Begzar/4.2.2.x) — an address seen at
///     TWO different resolvers wins (agreement is the poison detector);
///  2. the system resolver, accepted only when it yields a public IPv4
///     (carriers answer correctly more often than they poison; keeps a
///     connect possible when clean DNS itself is blocked);
///  3. nothing — leave the hostname to the engine.
///
/// Results cache with stale-while-revalidate: repeat connects skip the
/// lookup, and a failed connect evicts the pin so a provider IP
/// rotation is re-resolved on the next attempt.
class BootstrapResolver {
  BootstrapResolver({
    required Future<List<String>> Function(String host) lookup,
    this.onLog,
    this.ttl = const Duration(minutes: 5),
    this.staleTtl = const Duration(hours: 6),
  }) : _lookup = lookup;

  static final BootstrapResolver instance =
      BootstrapResolver(lookup: (h) => _defaultLookup(h, note: _note));

  /// Diagnostic sink wired by [resolve] for the duration of a lookup
  /// (per-resolver outcome — which transport survived MCI tonight).
  static void Function(String)? _noteSink;
  static void _note(String m) => _noteSink?.call(m);

  /// Resolvers probed live from the phone (2026-09-15) plus the classic
  /// public fallbacks for non-Iran networks.
  static const resolverPool = <String>[
    DnsScanner.cleanResolverIp, // 178.22.122.100 (Shecan, UDP-reachable on MCI)
    '178.22.122.101', // Shecan secondary
    '185.55.226.26', // Begzar
    '4.2.2.0', // level3 legacy
    '8.8.8.8',
    '1.1.1.1',
  ];

  static Future<List<String>> _defaultLookup(String host,
      {void Function(String)? note}) async {
    final scanner = DnsScanner(timeout: const Duration(seconds: 3));
    final byServer = <String, List<String>>{};
    // TCP/53 FIRST (device-measured MCI behavior 2026-09-15: the carrier
    // transparently intercepts UDP/53 — answers are sinkholed or silently
    // dropped, `lookupARecords` UDP returns nothing while the identical
    // TCP query answers clean). Both Shecan and 8.8.8.8 (user-requested:
    // domestic AND foreign) answer over TCP; UDP runs in parallel as the
    // fallback for networks that block TCP DNS instead.
    Future<void> ask(String server, {bool tcp = true}) async {
      final t0 = DateTime.now();
      try {
        // Hard per-ask bound: the connect deadline is ~12s and FOUR
        // parallel asks must finish inside the pin budget. 1.6s is
        // plenty for a resolver that answers at all (device p50 ≈
        // 100ms); slower ones are dead weight tonight.
        final ips = await scanner
            .resolve(host, server: server, tcp: tcp)
            .timeout(const Duration(milliseconds: 1600));
        note?.call('${tcp ? 'tcp' : 'udp'}:$server=${ips.join(",")}'
            ' (${DateTime.now().difference(t0).inMilliseconds}ms)');
        if (ips.isNotEmpty) byServer.putIfAbsent(server, () => ips);
      } catch (e) {
        note?.call('${tcp ? 'tcp' : 'udp'}:$server=ERR '
            '(${DateTime.now().difference(t0).inMilliseconds}ms)');
      }
    }
    final futures = <Future<void>>[
      ask('178.22.122.100'),
      ask('8.8.8.8'),
      ask('1.1.1.1'),
      ask('185.55.226.26'),
      for (final s in resolverPool) ask(s, tcp: false),
    ];
    await Future.wait(futures)
        .timeout(const Duration(seconds: 9), onTimeout: () => []);
    final counts = <String, int>{};
    for (final ips in byServer.values) {
      final seen = <String>{};
      for (final ip in ips) {
        if (seen.add(ip)) counts[ip] = (counts[ip] ?? 0) + 1;
      }
    }
    final agreed = counts.entries
        .where((e) => e.value >= 2 && isPublicV4(e.key))
        .map((e) => e.key)
        .toList();
    if (agreed.isNotEmpty) return agreed;
    final single = counts.keys.where(isPublicV4).toList();
    if (single.isNotEmpty) return single;
    // Fallback: the system resolver, filtered for sinkholes only.
    try {
      final sys =
          await InternetAddress.lookup(host).timeout(const Duration(seconds: 4));
      return sys.map((a) => a.address).where(isPublicV4).toList();
    } catch (_) {
      return const [];
    }
  }

  /// MCI sinkhole shapes: private 10.x (the 10.10.34.36 family), CGNAT
  /// 100.64/10, link-local, and the 6to4 wrapper embedding them. A
  /// PUBLIC server hostname answering with any of these is poison.
  static bool isPublicV4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final oct = parts.map(int.tryParse).toList();
    if (oct.any((o) => o == null)) return false;
    final a = oct[0]!, b = oct[1]!;
    if (a == 0 || a >= 224) return false; // reserved/multicast
    if (a == 10 || a == 127) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT
    if (a == 169 && b == 254) return false;
    return true;
  }

  final Future<List<String>> Function(String host) _lookup;
  final void Function(String message)? onLog;
  final Duration ttl;
  final Duration staleTtl;

  final Map<String, _Entry> _cache = {};
  final Map<String, Future<String?>> _inFlight = {};

  /// IP to pin for [profile]'s endpoint, or null to leave the hostname.
  Future<String?> addressFor(ProxyProfile profile) async {
    final host = profile.server.trim();
    if (host.isEmpty || InternetAddress.tryParse(host) != null) return null;
    return resolve(host);
  }

  Future<String?> resolve(String host) async {
    final now = DateTime.now();
    final cached = _cache[host];
    if (cached != null && now.difference(cached.at) < ttl) return cached.ip;
    final running = _inFlight[host];
    if (running != null) return running;
    final fut = () async {
      List<String> ips = const [];
      final notes = <String>[];
      void collect(String m) {
        if (notes.length < 12) notes.add(m);
      }
      _noteSink = collect;
      try {
        ips = await _lookup(host);
      } catch (_) {
      } finally {
        _noteSink = null;
      }
      for (final n in notes) {
        onLog?.call('probe:$host $n');
      }
      final fresh = ips.where(isPublicV4);
      final ip = fresh.isNotEmpty ? fresh.first : null;
      if (ip != null) {
        _cache[host] = _Entry(ip, DateTime.now());
        onLog?.call('boot:$host->$ip');
        return ip;
      }
      if (cached != null && now.difference(cached.at) < staleTtl) {
        // Fresh lookup failed — keep dialing the last known-good IP: a
        // stale address beats a deadlock or a poison sinkhole.
        onLog?.call('boot:$host->stale(${cached.ip})');
        return cached.ip;
      }
      onLog?.call('boot:$host->none');
      return null;
    }();
    _inFlight[host] = fut;
    try {
      return await fut;
    } finally {
      unawaited(_inFlight.remove(host));
    }
  }

  /// Drop a cached pin (after a connect failure — the IP may have
  /// rotated; the next attempt re-resolves).
  void evict(String host) => _cache.remove(host);
}

class _Entry {
  const _Entry(this.ip, this.at);
  final String ip;
  final DateTime at;
}
