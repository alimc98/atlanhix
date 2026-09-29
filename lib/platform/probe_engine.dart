import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/configgen/singbox_config_generator.dart';
import '../core/configgen/xray_config_generator.dart';
import '../core/logger.dart';
import '../core/net/bootstrap_dns.dart';
import '../core/runtime/clash_api_client.dart';
import '../core/runtime/core_manager.dart';
import '../core/runtime/core_process.dart' show PortAllocator;
import '../core/runtime/singbox_runtime.dart';
import '../domain/entities/proxy_profile.dart';
import '../routing/builtin_profiles.dart';
import '../routing/routing_models.dart';
import 'xray_bridge.dart';

/// v0.4.9 §user ("تست پینگ وقتی برنامه تازه باز شده کار نمی‌کند") — the
/// Dart side of the TRANSIENT libbox probe engine.
///
/// Real delay tests need a running engine to dial through. When no VPN is
/// connected (fresh app open), the main engine does not exist: libbox lives
/// in the VPN service process and its Clash API only answers while the
/// tunnel is up. This engine starts a second libbox Box INSIDE the app
/// process (channel `dev.atlanhix/probe`) with a pure proxy config — mixed
/// inbound on a private port + clash_api + the batch's node outbounds — and
/// NO tun inbound: no VpnService consent dialog, no TUN, no notification.
/// Nodes are measured through the real Clash-API delay test, then the
/// engine is stopped after an idle gap (battery: nothing keeps running
/// between sweeps).
///
/// v0.4.9 §testall-fix (device 2026-09-25, "every node red while the probe
/// API answered 598 ms by hand"):
///  1. **Union growth, never a restart under a running sweep.** The sweep
///     tests chunks of 6; a chunk with a node set ≠ the loaded one used to
///     RESTART the Box (log evidence: two "probe engine UP" lines one second
///     apart) — every in-flight delay test died against the swapped config
///     and the UI painted × for all. Now a superset is REUSED as-is and a
///     missing node grows the union; a restart happens only when the engine
///     is already down.
///  2. **Xray-owned nodes ride a REAL :xray child.** They have no sing-box
///     outbound (the builder returns null on purpose) — a stub without a
///     child was a guaranteed-fake dead measurement. The probe boots ONE
///     child process (XrayConfigGenerator per node, tags renamed unique,
///     one socks inbound per node port) and stops it with itself.
///  3. **Bootstrap pinning** for the child's nodes (the same clean-resolver
///     pin the connect path uses) so the poisoned carrier resolver cannot
///     fake another ×.
///
/// Cost model: one engine start per sweep (≈0.5–1.5 s; the Go runtime image
/// is already loaded by the forked AAR), zero while idle.
class ProbeEngine {
  ProbeEngine._();
  static final ProbeEngine instance = ProbeEngine._();

  static const _channel = MethodChannel('dev.atlanhix/probe');

  /// Distinct ports so the probe never collides with the live engine's
  /// mixed:2080 / clash:9097 (and never with the OS global http_proxy that
  /// proxy mode points at the live port).
  static const int mixedPort = 7891;
  static const int apiPort = 9090;
  static const String _apiSecret = 'probe-local';

  bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Shared in-flight start/grow: concurrent callers await ONE task instead
  /// of racing restarts (v0.4.9 §user-fix, kept).
  Future<void>? _inFlight;
  ClashApiClient? _api;
  Set<String> _loadedIds = {};
  Timer? _idleStop;

  /// v0.5.0 §device-fix (log evidence 2026-09-27 10:22: `initialize
  /// cache-file: timeout` on every connect): the connect path stops this
  /// engine, but the Smart Switch sweep it just armed re-entered
  /// [ensureUp] BEFORE the tunnel finished booting — both libbox instances
  /// then fought over ONE cache.db in the same process and the TUNNEL
  /// start died with `ENGINE_START_FAILED` (the probe engine, ironically,
  /// came UP right after: "probe engine UP :9090 nodes=11" one second
  /// after the connect FAILED). The connect owns the lock: while a tunnel
  /// boot is in flight (and until it is CONNECTED or terminally dead),
  /// every start attempt here answers honestly null — the sweep reports
  /// engine-off and falls through to the TCP fallback; the NEXT sweep
  /// boots the engine if it is still wanted.
  bool _tunnelBootHold = false;

  /// Connect path: [hold] = "a tunnel boot is in flight — no probe engine
  /// starts"; false releases the hold (tunnel up or dead — a sweep may
  /// boot the engine again).
  void setTunnelBootHold(bool hold) {
    _tunnelBootHold = hold;
    if (hold) {
      _idleStop?.cancel();
      _idleStop = null;
    }
  }

  /// v0.4.9 §ownership-fix: TRUE only while THIS engine's :xray child is
  /// the one running. [stop()] fires from the app lifecycle (main.dart,
  /// paused/hidden) too — without this flag it would kill the VPN
  /// SESSION's :xray child on every background while a tunnel is up.
  bool _ownXrayChild = false;

  /// Profiles backing [_loadedIds] — the union grows from these plus the
  /// caller's batch; ids are stable so pinned variants reuse the slot.
  final Map<String, ProxyProfile> _profileCache = {};

  /// True when the probe engine answered its last health check.
  bool get isUp => _api != null;

  /// Measures one node's REAL end-to-end URL delay, starting (or reusing)
  /// the transient engine on demand. Returns null when the node cannot be
  /// measured here (not Android / start failed) so the caller falls through
  /// honestly — same contract as the live-engine provider.
  Future<int?> delayTest(ProxyProfile p, String url, int timeoutMs) async {
    if (!isAndroid) return null;
    final api = await ensureUp([p]);
    if (api == null) return null;
    final ms = await api.delayTest(
        '${SingBoxRuntime.tagPrefix}${p.id}', url, timeoutMs);
    _armIdleStop();
    return ms;
  }

  /// v0.5.0 §perf-fix ("ping takes forever and reads ~900 ms"): the batch
  /// entry the sweeps MUST use. Old flow: per-node ensureUp → every new node
  /// id rebuilt the Box (probeStart is a FULL restart — see the channel
  /// comment), so a 6-node sweep paid ~4 engine restarts × (Go runtime
  /// reload + API gate + table wait), each sequentially — tens of seconds
  /// for one sweep, and every in-flight measurement died mid-restart. Now:
  /// ONE engine up for the WHOLE batch, then all nodes measured in parallel
  /// against a single config. Returns id → ms (null = no answer in time).
  ///
  /// v0.5.2 §user: [onNode] fires the moment each node's measurement LANDS
  /// (parallel completion order) — the dashboard hero's live ladder count
  /// ("testing 5/11… 180 ms") counts real progress instead of a frozen
  /// spinner. Null → silent (legacy callers unchanged).
  Future<Map<String, int?>> delayTestBatch(
    List<ProxyProfile> nodes,
    String url,
    int timeoutMs, {
    void Function(ProxyProfile p, int? ms)? onNode,
  }) async {
    if (!isAndroid || nodes.isEmpty) return const {};
    final api = await ensureUp(nodes);
    if (api == null) return const {};
    final out = await _measureBatch(api, nodes, url, timeoutMs,
        onNode: onNode);
    _armIdleStop();
    return out;
  }

  /// Parallel delay tests against ONE up engine. Serial per node would cap
  /// a sweep at (n × timeout) worst case; concurrent calls fan out to the
  /// engine's own delay-test handler (sing-box dials them concurrently).
  Future<Map<String, int?>> _measureBatch(
    ClashApiClient api,
    List<ProxyProfile> nodes,
    String url,
    int timeoutMs, {
    void Function(ProxyProfile p, int? ms)? onNode,
  }) async {
    final entries = await Future.wait(nodes.map((p) async {
      final tag = '${SingBoxRuntime.tagPrefix}${p.id}';
      int? ms;
      try {
        ms = await api.delayTest(tag, url, timeoutMs);
      } catch (_) {
        ms = null;
      }
      onNode?.call(p, ms);
      return MapEntry(p.id, ms);
    }));
    return Map.fromEntries(entries);
  }

  /// Batch entry point used by the sweep: ensures an engine carrying AT
  /// LEAST [nodes] is up — one start for the whole batch, no start per
  /// node, and (§testall-fix) NO restart when a later chunk brings a
  /// different set: the union grows instead.
  ///
  /// v0.5.0 §device-fix: a start attempt during a tunnel boot hold answers
  /// null honestly (an UP engine keeps answering — the hold only blocks
  /// STARTS, which are exactly what re-fights cache.db).
  Future<ClashApiClient?> ensureUp(List<ProxyProfile> nodes) async {
    if (!isAndroid) return null;
    for (final n in nodes) {
      _profileCache[n.id] = n;
    }
    final wanted = nodes.map((n) => n.id).toSet();
    final api = _api;
    if (api != null) {
      if (wanted.difference(_loadedIds).isEmpty) return api; // superset: reuse
      return _grow(nodes); // union grow — never a restart under the sweep
    }
    if (_tunnelBootHold) {
      // The connect path owns the process right now — a libbox start here
      // would fight the tunnel over cache.db (device log 2026-09-27). An
      // honest null lets the sweep report engine-off and move on.
      return null;
    }
    final inflight = _inFlight;
    if (inflight != null) {
      await inflight;
      final api2 = _api;
      if (api2 != null) {
        if (wanted.difference(_loadedIds).isEmpty) return api2;
        return _grow(nodes);
      }
      // The start failed — retry honestly (a new start attempt, not null).
      return _grow(nodes);
    }
    return _grow(nodes);
  }

  /// Serialized start/grow. When another task is in flight, wait for it and
  /// re-evaluate (it may have grown the engine to cover this batch already).
  Future<ClashApiClient?> _grow(List<ProxyProfile> nodes) async {
    if (_tunnelBootHold) return null; // re-checked after any in-flight await
    final inflight = _inFlight;
    if (inflight != null) {
      await inflight;
      return ensureUp(nodes);
    }
    final wanted = <String>{..._loadedIds, ...nodes.map((n) => n.id)};
    // Profiles for the union: the caller's batch first, then everything the
    // engine already carries. A profile that vanished from the cache (only
    // possible after a process restart, where the engine is down anyway)
    // forces a fresh start with just the caller's batch.
    final union = <ProxyProfile>[];
    var missing = false;
    for (final id in wanted) {
      final p = _profileCache[id];
      if (p == null) {
        missing = true;
        break;
      }
      union.add(p);
    }
    final startNodes = missing ? nodes : union;
    final startIds = missing ? nodes.map((n) => n.id).toSet() : wanted;
    final task = _startWith(startNodes, loadedIds: startIds);
    _inFlight = task;
    try {
      await task;
      return _api;
    } finally {
      if (identical(_inFlight, task)) _inFlight = null;
    }
  }

  /// Bootstrap-pin a hostname node OUTSIDE any tunnel (same clean-resolver
  /// pin the connect path uses) — the :xray child resolves nothing itself.
  Future<ProxyProfile> _pinHost(ProxyProfile n) async {
    final host = n.server.trim();
    if (host.isEmpty || BootstrapResolver.isPublicV4(host)) return n;
    try {
      final ip = await BootstrapResolver.instance.addressFor(n);
      if (ip == null || ip == host) return n;
      return n.copyWith(
        server: ip,
        // Preserve the hostname for every identity field: SNI, Reality
        // serverName, HTTP Host header.
        sni: n.sni ?? host,
        host: n.host ?? host,
      );
    } catch (_) {
      return n;
    }
  }

  /// Builds ONE merged :xray child config serving every Xray-owned node of
  /// the batch (one socks inbound per node on its own port; tags renamed
  /// unique — the single-node generator emits fixed tags that would
  /// collide). Returns null when nothing needs the child.
  Map<String, dynamic>? _buildXrayChild(
      List<ProxyProfile> xrayNodes, List<int> ports) {
    if (xrayNodes.isEmpty) return null;
    final xg = XrayConfigGenerator();
    final routing = BuiltinRoutingProfiles.all().first;
    final inbounds = <Map<String, dynamic>>[];
    final outbounds = <Map<String, dynamic>>[];
    final rules = <Map<String, dynamic>>[];
    Map<String, dynamic>? dns;
    for (var i = 0; i < xrayNodes.length; i++) {
      final single = xg.generate(
        profile: xrayNodes[i],
        localSocksPort: ports[i],
        routing: routing,
        // NOTE: deliberately unfragmented — the sweep measures REACHABILITY;
        // the fragment rung belongs to the real connect path.
      );
      dns ??= single['dns'] as Map<String, dynamic>?;
      // Rename the fixed tags (socks-in / proxy-out / direct / block) so
      // parallel nodes cannot collide.
      final ren = <String, String>{};
      for (final inb
          in ((single['inbounds'] as List?) ?? const []).cast<Map>()) {
        final m = inb.cast<String, dynamic>();
        m['tag'] = 'probe-in-$i';
        inbounds.add(m);
      }
      for (final ob
          in ((single['outbounds'] as List?) ?? const []).cast<Map>()) {
        final m = ob.cast<String, dynamic>();
        final old = m['tag'] as String;
        final nw = '$old-$i';
        ren[old] = nw;
        m['tag'] = nw;
        outbounds.add(m);
      }
      for (final r
          in (((single['routing'] as Map?)?['rules'] as List?) ?? const [])
              .cast<Map>()) {
        final m = r.cast<String, dynamic>();
        final t = m['outboundTag'] as String?;
        // The generator's per-node catch-all (proxy-out, network tcp,udp)
        // is rebuilt below from THIS node's inbound tag — merged as-is it
        // would route every inbound into node #1's outbound.
        if (t == 'proxy-out' &&
            m['inboundTag'] == null &&
            m['network'] != null) {
          continue;
        }
        if (t != null && ren.containsKey(t)) m['outboundTag'] = ren[t];
        if (m['inboundTag'] != null) m['inboundTag'] = ['probe-in-$i'];
        rules.add(m);
      }
      rules.add({
        'type': 'field',
        'inboundTag': ['probe-in-$i'],
        'outboundTag': ren['proxy-out'],
        'network': 'tcp,udp',
      });
    }
    return {
      'log': {'loglevel': 'warning'},
      if (dns != null) 'dns': dns,
      'inbounds': inbounds,
      'outbounds': outbounds,
      'routing': {'domainStrategy': 'IPIfNonMatch', 'rules': rules},
    };
  }

  Future<ClashApiClient?> _startWith(
    List<ProxyProfile> nodes, {
    Set<String>? loadedIds,
  }) async {
    final wanted =
        loadedIds ?? nodes.map((n) => n.id).toSet();
    try {
      await _stopNative();
      // ── Xray-owned nodes: boot the REAL :xray child (one inbound per
      // node) BEFORE the sing-box config is generated, so the stubs point
      // at living listeners. Child failed / binary absent → the node is
      // dropped from THIS engine honestly (delayTest 404s → null → the
      // caller reports engine-off; never a fake timeout).
      var buildNodes = nodes;
      final upstreams = <String, ({String host, int port})>{};
      final xrayIdx = <int>[];
      for (var i = 0; i < nodes.length; i++) {
        if (CoreManager.needsXrayUpstream(nodes[i])) xrayIdx.add(i);
      }
      if (xrayIdx.isNotEmpty && XrayBridge.instance.available) {
        final xrayNodes = <ProxyProfile>[];
        for (final i in xrayIdx) {
          try {
            xrayNodes.add(await _pinHost(nodes[i]));
          } catch (_) {
            xrayNodes.add(nodes[i]);
          }
        }
        // One free port per node — NEVER 2080 (the live engine's mixed).
        final ports = <int>[];
        for (var i = 0; i < xrayNodes.length; i++) {
          ports.add(await PortAllocator.freePort(prefer: 40821 + i));
        }
        final child = _buildXrayChild(xrayNodes, ports);
        final okChild = child != null &&
            await XrayBridge.instance.start(jsonEncode(child), ports.first);
        _ownXrayChild = okChild;
        if (okChild) {
          Logger.instance.info('probe-engine',
              'xray child UP nodes=${xrayNodes.length} ports=$ports');
          for (var i = 0; i < xrayNodes.length; i++) {
            upstreams[xrayNodes[i].id] = (host: '127.0.0.1', port: ports[i]);
          }
          // buildNodes keeps the PINNED variants (same ids — SNI/Host
          // preserved, server now the pinned IP).
          buildNodes = [
            for (var i = 0; i < nodes.length; i++)
              CoreManager.needsXrayUpstream(nodes[i])
                  ? xrayNodes[xrayIdx.indexOf(i)]
                  : nodes[i],
          ];
        } else {
          Logger.instance.warn('probe-engine',
              'xray child failed — ${xrayNodes.length} node(s) engine-off');
          buildNodes = [
            for (var i = 0; i < nodes.length; i++)
              if (!xrayIdx.contains(i)) nodes[i],
          ];
        }
      } else if (xrayIdx.isNotEmpty) {
        Logger.instance.warn('probe-engine',
            'xray binary unavailable — ${xrayIdx.length} node(s) engine-off');
        buildNodes = [
          for (var i = 0; i < nodes.length; i++)
            if (!xrayIdx.contains(i)) nodes[i],
        ];
      }
      if (buildNodes.isEmpty) {
        // §ownership-fix: kill only OUR child (never the session's).
        if (_ownXrayChild) {
          _ownXrayChild = false;
          await XrayBridge.instance.stop();
        }
        return null;
      }
      // The probe config carries the batch's outbounds (every node a REAL
      // dial target) but never a tun inbound — proxy-only, consent-free.
      final gen = SingBoxConfigGenerator();
      final cfg = gen.generate(
        runnableProfiles: buildNodes,
        routing: BuiltinRoutingProfiles.all().first,
        dns: DnsSettings(mode: DnsMode.automatic),
        selectedTag: buildNodes.isEmpty
            ? 'direct'
            : '${SingBoxRuntime.tagPrefix}${buildNodes.first.id}',
        socksUpstreams: upstreams,
        options: SingBoxOptions(
          mixedPort: mixedPort,
          clashApiPort: apiPort,
          clashApiSecret: _apiSecret,
          enableTun: false,
        ),
      );
      final result = await _channel.invokeMethod<String>(
          'probeStart', {'config': jsonEncode(cfg)});
      final j = result == null
          ? const <String, dynamic>{}
          : jsonDecode(result) as Map<String, dynamic>;
      if (j['ok'] != true) {
        Logger.instance.warn('probe-engine',
            'probeStart failed: ${j['error'] ?? 'unknown'}');
        if (_ownXrayChild) {
          _ownXrayChild = false;
          await XrayBridge.instance.stop();
        }
        return null;
      }
      final api = ClashApiClient(port: apiPort, secret: _apiSecret);
      // Wait until the listener answers (Box start is async inside libbox).
      for (var i = 0; i < 20; i++) {
        if (await api.isAlive()) {
          // v0.4.9 §user-fix ("test all red on device, 21:00:11 evidence"):
          // /version answers BEFORE startOrReloadService finishes swapping
          // the Box — delay tests issued immediately 404 against the OLD
          // config and every node read ×. Gate on the reloaded table
          // actually serving one of THIS batch's tags first.
          final wantedTags = buildNodes
              .map((n) => '${SingBoxRuntime.tagPrefix}${n.id}')
              .toSet();
          for (var t = 0; t < 20; t++) {
            final tags = await api.proxyTags();
            if (tags != null && tags.intersection(wantedTags).isNotEmpty) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          _api = api;
          _loadedIds = wanted;
          Logger.instance.info('probe-engine',
              'probe engine UP :$apiPort nodes=${buildNodes.length}');
          return api;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      Logger.instance.warn('probe-engine', 'clash api never answered');
      await stop();
      return null;
    } on MissingPluginException {
      return null; // desktop / tests — honest fall-through
    } catch (e) {
      Logger.instance
          .warn('probe-engine', 'start error: ${Logger.redact(e.toString())}');
      if (_ownXrayChild) {
        _ownXrayChild = false;
        try {
          await XrayBridge.instance.stop();
        } catch (_) {}
      }
      return null;
    }
  }

  /// Explicit shutdown (also fired from the app lifecycle when backgrounded
  /// — a hidden engine with no work is pure battery drain).
  Future<void> stop() async {
    _idleStop?.cancel();
    _idleStop = null;
    _api = null;
    _loadedIds = {};
    // §ownership-fix: only OUR child dies with us — the VPN session's
    // :xray child belongs to the connect path and must survive a
    // backgrounded app (swipe/pause handler calls stop() unconditionally).
    if (_ownXrayChild) {
      _ownXrayChild = false;
      try {
        await XrayBridge.instance.stop();
      } catch (_) {}
    }
    if (!isAndroid) return;
    await _stopNative();
  }

  Future<void> _stopNative() async {
    try {
      await _channel.invokeMethod<String>('probeStop');
    } catch (_) {}
  }

  /// The engine outlives single tests by [idle] so a sweep does not pay the
  /// start cost once per node — then shuts itself down.
  void _armIdleStop({Duration idle = const Duration(seconds: 20)}) {
    _idleStop?.cancel();
    _idleStop = Timer(idle, () {
      Logger.instance.info('probe-engine', 'idle timeout — stopping');
      stop();
    });
  }
}
