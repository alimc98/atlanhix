import 'dns_scanner.dart';

/// Built-in resolver catalogue for the DNS scanner (Settings → DNS scan).
///
/// SELECTION BASIS (not marketing): every domestic entry below was either
/// (a) probed from this very device on MCI mobile data on 2026-09-13
/// (Shecan, Begzar/Shole, 403) or (b) carried with a working-test citation
/// from the 2026 research pass. UNVERIFIED candidates are NOT included.
/// Foreign DoH (Cloudflare/Google) ships as a control: measured CLOSED on
/// MCI TCP/443 — seeing it "unreachable" in a scan is expected, not a bug.
class DnsCatalog {
  DnsCatalog._();

  /// Domestic resolvers — clean answers for blocked names, reachable with
  /// no proxy at all (UDP/53; many also TCP/53 and DoH/DoT).
  static const domestic = <DnsProbeTarget>[
    // Shecan — probed live from Mi 9T/MCI 2026-09-13: real A records.
    DnsProbeTarget(name: 'Shecan', host: '178.22.122.100'),
    DnsProbeTarget(name: 'Shecan 2', host: '178.22.122.101'),
    DnsProbeTarget(
        name: 'Shecan DoH',
        host: 'doh.shecan.ir',
        transport: DnsTransport.doh,
        port: 443,
        dohPath: '/dns-query'),
    // Begzar — probed live from the device: real 192.227.211.124 for
    // us.hixyz.ir. NOTE: public docs disagree on its DoH form; only the
    // verified UDP/53 rows ship here.
    DnsProbeTarget(name: 'Begzar', host: '185.55.226.26'),
    DnsProbeTarget(name: 'Begzar 2', host: '185.55.227.27'),
    // 403.online — probed live from the device: real answers over UDP.
    DnsProbeTarget(name: '403.online', host: '10.202.10.10'),
    DnsProbeTarget(name: '403.online 2', host: '10.202.10.11'),
    DnsProbeTarget(
        name: '403 DoH',
        host: 'doh4.403.online',
        transport: DnsTransport.doh,
        port: 443,
        dohPath: '/dns-query'),
    // Shole — 403-family (45.90.28.x); UDP gave nothing from THIS network
    // but the docs cite it working on other ISP paths — keep, scanner decides.
    DnsProbeTarget(name: 'Shole', host: '45.90.28.200'),
    DnsProbeTarget(name: 'Shole 2', host: '45.90.28.90'),
    // Radar Game — official domain DoH (IP literal breaks the cert).
    DnsProbeTarget(
        name: 'Radar DoH',
        host: 'radagameb.ha3tban.com',
        transport: DnsTransport.doh,
        port: 443,
        dohPath: '/dns-query'),
  ];

  /// International control group.
  static const international = <DnsProbeTarget>[
    DnsProbeTarget(name: 'Cloudflare', host: '1.1.1.1'),
    DnsProbeTarget(name: 'Google', host: '8.8.8.8'),
    DnsProbeTarget(
        name: 'Cloudflare DoH',
        host: 'cloudflare-dns.com',
        transport: DnsTransport.doh,
        port: 443,
        dohPath: '/dns-query'),
    DnsProbeTarget(
        name: 'Google DoH',
        host: 'dns.google',
        transport: DnsTransport.doh,
        port: 443,
        dohPath: '/resolve'),
    // DoT controls (need TCP/853 egress — usually blocked on IR mobile).
    DnsProbeTarget(
        name: 'AdGuard DoT',
        host: 'dns.adguard-dns.com',
        transport: DnsTransport.tcp,
        port: 853),
  ];

  /// Parse one user line: `name=1.2.3.4`, `1.2.3.4`,
  /// `https://host/path` (DoH), `tls://host` (DoT :853), `host:port`.
  static DnsProbeTarget? parseCustom(String line) {
    var s = line.trim();
    if (s.isEmpty) return null;
    String? name;
    if (s.contains('=')) {
      final i = s.indexOf('=');
      name = s.substring(0, i).trim();
      s = s.substring(i + 1).trim();
    }
    if (s.startsWith('https://')) {
      final u = Uri.tryParse(s);
      if (u == null || u.host.isEmpty) return null;
      return DnsProbeTarget(
        name: name ?? u.host,
        host: u.host,
        port: u.hasPort ? u.port : 443,
        transport: DnsTransport.doh,
        dohPath: u.path.isEmpty ? '/dns-query' : u.path,
      );
    }
    if (s.startsWith('tls://')) {
      final host = s.substring(6).trim();
      if (host.isEmpty) return null;
      return DnsProbeTarget(
          name: name ?? host,
          host: host,
          port: 853,
          transport: DnsTransport.tcp);
    }
    // ip or host[:port]
    final m = RegExp(r'^([0-9a-fA-F:.]+)(?::(\d+))?$').firstMatch(s);
    if (m == null) return null;
    final port = int.tryParse(m.group(2) ?? '') ?? 53;
    return DnsProbeTarget(
        name: name ?? m.group(1)!, host: m.group(1)!, port: port);
  }

  static List<DnsProbeTarget> all() => [...domestic, ...international];
}
