import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/android_node_support.dart';
import '../core/runtime/core_process.dart';
import '../core/logger.dart';
import '../core/net/bootstrap_dns.dart';
import '../core/health/latency_tester.dart';
import '../domain/entities/health.dart';
import '../domain/entities/proxy_profile.dart';
import '../core/configgen/xray_config_generator.dart';
import '../core/engine_availability.dart';
import '../platform/xray_bridge.dart';
import '../warp/warp_registrar.dart';
import 'app_settings.dart';
import '../platform/android_vpn.dart';
import '../application/connection_controller.dart';
import '../application/dependencies.dart';

/// v0.4.1 §2/§5/§31 — the Android VPN session orchestrator.
///
/// Owns the [AndroidVpnController] and connects it to the real runtime:
///   * permission → VpnService.prepare (native) → consent dialog → result
///   * config     → RuntimeConfigBridge.androidHandoff (REAL settings:
///                  routing mode, DNS, IPv6, MTU, per-app lists)
///   * engine     → the sing-box config generated for the selected node,
///                  handed to the native engine (libbox) as-is
///   * probe      → REAL HTTP probe through the tunnel before CONNECTED
///
/// This is the single authoritative state machine the UI listens to on
/// Android (§5); ConnectionController's desktop phases are bridged INTO it
/// for the shared ConnectRing, so there are no two competing "connected"
/// truths.
class VpnSession {
  VpnSession({required this.deps}) {
    controller = AndroidVpnController();
    _sub = controller.states.listen((_) => _syncFromAndroid());
  }

  final AppDependencies deps;
  late final AndroidVpnController controller;
  StreamSubscription<AndroidVpnPhase>? _sub;

  /// The node chosen for the current/next connection (set by the UI).
  ProxyProfile? selectedNode;

  /// Local SOCKS port of the running :xray upstream (0 = not running).
  int _xrayUpstreamPort = 0;

  /// v0.4.4: last successful tunnel-probe latency (dashboard tile).
  int? lastLatencyMs;

  /// Generate the node's Xray config and boot the :xray process with it.
  Future<bool> _startXrayUpstream(ProxyProfile profile, String trace) async {
    try {
      // NEVER a fixed 2080: the front sing-box's mixed inbound prefers that
      // exact port (device bug 2026-09-15: "listen tcp 127.0.0.1:2080: bind:
      // address already in use" — Xray won it first). Ask the OS for a free
      // port; the stub in the front config uses whatever we got.
      final port = await PortAllocator.freePort(prefer: 40820);
      final xrayJson = XrayConfigGenerator().generate(
        profile: profile,
        routing: deps.configBridge.routingProfile(),
        localSocksPort: port,
        // xray resolves the sing-box-forwarded remote domains ITSELF —
        // 1.1.1.1 (the generator default) is dead on IR mobile data
        // (measured Mi 9T 2026-09-13); use the same clean domestic resolver
        // the front config uses.
        dnsServer: Platform.isAndroid ? '178.22.122.100' : '1.1.1.1',
      );
      final ok = await XrayBridge.instance
          .start(jsonEncode(xrayJson), port);
      if (!ok) {
        lastError = 'XRAY_START_FAILED';
        Logger.instance.error('vpn-session',
            '$trace FAILED stage=XRAY_UPSTREAM node=${profile.name} reason=:xray process refused start');
        return false;
      }
      _xrayUpstreamPort = port;
      Logger.instance.info('vpn-session',
          '$trace XRAY_UPSTREAM node=${profile.name} socks=$port');
      return true;
    } catch (e) {
      lastError = 'XRAY_START_FAILED';
      Logger.instance.error('vpn-session',
          '$trace FAILED stage=XRAY_UPSTREAM exception=${e.runtimeType} msg=${Logger.redact(e.toString())}');
      return false;
    }
  }

  /// v0.4.1 §5: selection CHANGED without a state-machine event (the user
  /// tapped a node card while disconnected — no [states] emission). The UI
  /// listens to this to repaint the hero card the moment a node is tapped.
  final StreamController<void> _selectionEvents =
      StreamController<void>.broadcast();
  Stream<void> get selectionChanged => _selectionEvents.stream;

  /// Explicitly selects a node for the next connect — called by the UI the
  /// moment the user taps a node card, BEFORE any connect attempt, so the
  /// dashboard reflects the tapped node immediately.
  void selectNode(ProxyProfile p) {
    selectedNode = p;
    Logger.instance.info('vpn-session',
        '[ATX-DART UI] NODE_SELECTED ${p.name} proto=${p.protocol.name} '
        'transport=${p.transport.name} core=${p.effectiveCore.name}');
    _selectionEvents.add(null);
  }

  /// The core that will actually run the connection on this device — from
  /// the REAL state (selected node + engine gating), never hardcoded.
  CoreKind get activeCore {
    final n = selectedNode;
    if (n == null) return CoreKind.unknown;
    if (AndroidNodeSupport.isRunnable(n)) return CoreKind.singbox;
    return n.effectiveCore; // honest: shows Xray/AmneziaWG/… as-is
  }

  /// "Applied after reconnect" flag (§31): true when settings changed in
  /// ways the running tunnel cannot hot-apply.
  /// Hostname whose bootstrap-pinned IP is currently dialed —
  /// the failure path evicts THIS, not profile.server (which by then
  /// holds the pinned IP itself).
  String? _bootedHost;

  bool pendingApply = false;
  String? lastError; // last fatal connect error code (UI-facing)


  AndroidVpnPhase get phase => controller.phase;
  Stream<AndroidVpnPhase> get states => controller.states;
  bool get isConnected => controller.isConnected;

  /// UI-facing state label source: on Android the VPN session IS the truth.
  ConnectionPhase get uiPhase => switch (controller.phase) {
        AndroidVpnPhase.connected => ConnectionPhase.connected,
        AndroidVpnPhase.validating ||
        AndroidVpnPhase.starting ||
        AndroidVpnPhase.preparing ||
        AndroidVpnPhase.requestingPermission =>
          ConnectionPhase.validating,
        AndroidVpnPhase.reconnecting => ConnectionPhase.recovering,
        AndroidVpnPhase.stopping => ConnectionPhase.disconnecting,
        AndroidVpnPhase.failed => ConnectionPhase.error,
        AndroidVpnPhase.permissionDenied => ConnectionPhase.error,
        AndroidVpnPhase.revoked => ConnectionPhase.error,
        AndroidVpnPhase.idle || AndroidVpnPhase.stopped => ConnectionPhase.disconnected,
      };

  void _syncFromAndroid() {
    // Any state sync invalidates the pending-apply flag (tunnel rebuilt).
    pendingApply = false;
  }

  /// §2 — the full connect flow. Never reports CONNECTED without a real
  /// probe through the TUN (enforced inside AndroidVpnController).
  ///
  /// Node-selection semantics (v0.4.1 device fix):
  ///   * an explicit [node] (UI tap) or a stored selection is honored
  ///     EXACTLY — a non-runnable selection fails with an honest error and
  ///     is NEVER silently swapped for another node (the old fallback made
  ///     every tap "repeat" whatever auto-select preferred);
  ///   * the stored selection is re-resolved against the live repository so
  ///     a deleted/refreshed-away node cannot reconnect from a stale
  ///     in-memory reference (it self-heals to auto-select);
  ///   * with no selection at all, [_bestNode] auto-picks among
  ///     ANDROID-RUNNABLE nodes only.
  ///
  /// SINGLE-CORE GUARANTEE: exactly ONE core serves the active connection.
  /// Protocol → core map on Android today:
  ///   hysteria2 / hysteria / tuic / trojan / vmess / vless(+reality, no
  ///   XTLS flow) / shadowsocks / anytls / shadowtls / naive / socks / http
  ///     → sing-box (libbox) — the ONLY in-app engine;
  ///   vless+xhttp / Xray-owned profiles → Xray upstream — NOT runnable
  ///     in-app (excluded, honest error);
  ///   awg (AmneziaWG) → external amneziawg-go daemon — NOT bundled on
  ///     Android (excluded, honest error);
  ///   masterDnsVpn → external mdvpn-client daemon — NOT runnable in-app
  ///     (excluded, honest error).
  /// The generator is never handed two cores for one connection and no
  /// second engine process is ever spawned here.
  ///
  /// Trace: every stage logs `[ATX-DART …]` (via Logger) with a connection
  /// id shared with the native ATX traces for the same attempt.
  Future<bool> connect({ProxyProfile? node}) async {
    final trace = '[ATX-DART ${DateTime.now().millisecondsSinceEpoch % 10000}]';
    Logger.instance.info('vpn-session', '$trace CONNECT_REQUEST');
    lastError = null;

    // ── 1. EXPLICIT SELECTION FIRST: the tapped node IS the request. ──
    final explicit = node ?? _liveStoredSelection(trace);
    if (explicit != null) {
      // Remember the pick even when it cannot run: the dashboard must show
      // the node the user chose, not a node the picker preferred.
      selectedNode = explicit;
      final why = AndroidNodeSupport.androidExclusionReason(explicit);
      if (why != null) {
        lastError = 'NODE_NOT_RUNNABLE_ON_ANDROID';
        Logger.instance.error('vpn-session',
            '$trace FAILED stage=NODE_SELECTED node=${explicit.name} proto=${explicit.protocol.name} transport=${explicit.transport.name} core=${explicit.effectiveCore.name} reason=$why');
        return false;
      }
      // Node identity WITHOUT endpoint/credentials: name + protocol/transport
      // family only (redaction discipline; server/host never logged).
      Logger.instance.info('vpn-session',
          '$trace NODE_SELECTED source=explicit node=${explicit.name} proto=${explicit.protocol.name} transport=${explicit.transport.name} core=${explicit.effectiveCore.name}');
      return _connectProfile(explicit, trace);
    }

    // ── 2. AUTO-SELECT among ANDROID-RUNNABLE nodes only. ──
    final best = _bestNode();
    if (best == null) {
      lastError = 'NO_RUNNABLE_NODE';
      Logger.instance.error('vpn-session',
          '$trace FAILED stage=NODE_SELECTED error=NO_RUNNABLE_NODE ${_exclusionSummary()}');
      return false;
    }
    selectedNode = best;
    Logger.instance.info('vpn-session',
        '$trace NODE_SELECTED source=auto node=${best.name} proto=${best.protocol.name} transport=${best.transport.name} core=${best.effectiveCore.name}');
    return _connectProfile(best, trace);
  }

  /// The stored selection, re-resolved against the live repository so a
  /// deleted or subscription-refreshed-away node cannot keep reconnecting
  /// from a stale in-memory reference (device-observed wrong-node bug class).
  ProxyProfile? _liveStoredSelection(String trace) {
    final sel = selectedNode;
    if (sel == null) return null;
    final live = deps.profiles.byId(sel.id);
    if (live == null) {
      Logger.instance.warn('vpn-session',
          '$trace STORED_SELECTION_STALE node=${sel.name} is no longer in the repository; falling back to auto-select');
      selectedNode = null;
      return null;
    }
    return live;
  }

  /// The single authoritative engine-start path — every connect (explicit
  /// or auto) funnels through here after node selection, so the single-core
  /// guarantee is enforced in exactly ONE place.
  Future<bool> _connectProfile(ProxyProfile profile, String trace) async {
    // ── SINGLE-CORE GUARANTEE (fail fast, never dual-core) ──
    // Exactly ONE core engine serves this connection. On Android that engine
    // is sing-box (libbox): the Xray / MDVPN / AmneziaWG upstreams are
    // external daemon processes that cannot spawn in-app. Fail here instead
    // of generating a merged dual-core config or a direct-only selector
    // over a dead stub.
    if (!AndroidNodeSupport.coreAllowedOnAndroid(profile.effectiveCore)) {
      lastError = 'CORE_NOT_RUNNABLE_ON_ANDROID';
      Logger.instance.error('vpn-session',
          '$trace FAILED stage=CORE_SELECTED node=${profile.name} core=${profile.effectiveCore.name} reason=non-sing-box core has no in-app runtime (single-core guarantee)');
      return false;
    }
    // ── BOOTSTRAP PIN (v0.4.4 device regression) ──
    // Node hostnames are resolved HERE, outside the tunnel. Left to the
    // engine, the lookup goes through the tunnel the engine owns and
    // deadlocks (`lookup <node>: context deadline exceeded`, Mi 9T
    // 2026-09-15) or returns the carrier sinkhole. The pinned public IPv4
    // replaces `server`; SNI/server_name keep the hostname so TLS,
    // Reality and Host headers are byte-for-byte unchanged.
    profile = await _withBootstrappedAddress(profile, trace);

    // xhttp / mKCP: the front sing-box CANNOT express them — the Xray
    // runtime (:xray process + libv2ray AAR) must serve the node. Started
    // as a local SOCKS upstream below; the front config references it via
    // socksUpstreams (v2rayNG/NekoBox architecture). When the runtime is
    // off this fails with the honest reason, never a silent swap.
    if (profile.transport == Transport.xhttp ||
        profile.rawParams['type'] == 'mkcp' ||
        profile.rawParams['type'] == 'kcp') {
      if (!XrayCoreState.instance.runtimeLoaded) {
        lastError = 'XRAY_RUNTIME_UNAVAILABLE';
        Logger.instance.error('vpn-session',
            '$trace FAILED stage=CORE_SELECTED node=${profile.name} transport=${profile.transport.name} reason=xray runtime not loaded (sing-box on, Xray off)');
        return false;
      }
      final ok = await _startXrayUpstream(profile, trace);
      if (!ok) return false;
    }

    try {
      // v0.4.4 §user-4/5: apply the LOCAL PORT + PROXY/TUN MODE prefs to the
      // front runtime before the config is generated. On Android the mixed
      // port must be EXACTLY the user's (libbox reads it from the config, no
      // re-allocation), and proxy mode drops the tun inbound entirely.
      final front = deps.cores.front;
      front.mixedPortPreference = deps.appSettings.localPort;
      front.tunEnabled = !deps.appSettings.proxyMode;
      // Proxy mode: no TUN is ever established, so no consent dialog is
      // needed either; the controller learns the mode via connect().
      controller.proxyPort = deps.appSettings.localPort;

      // 1. Generate the REAL engine config for the selected node from the
      //    current settings (routing mode, DNS, IPv6, WARP, app rules).
      final configJson = await _buildEngineConfig(profile, trace);
      if (configJson == null) {
        Logger.instance.error('vpn-session',
            '$trace FAILED stage=CONFIG_GENERATED error=generation returned null');
        return false;
      }
      Logger.instance.info('vpn-session', '$trace CONFIG_GENERATED bytes=${configJson.length}');

      // 2. Push TUN parameters from the SAME settings (single source).
      controller
        ..configJson = configJson
        ..dnsServers = List.of(deps.configBridge.tunDnsServers())
        ..routes = List.of(deps.configBridge.tunRoutes())
        ..inet6Address = deps.configBridge.wantsInet6() ? 'fdfe:dcba:9876::1' : null
        ..mtu = deps.configBridge.tunMtu()
        ..includeApps = List.of(deps.configBridge.androidAppLists().include)
        ..excludeApps = List.of(deps.configBridge.androidAppLists().exclude);
      Logger.instance.info('vpn-session',
          '$trace HANDOFF mtu=${controller.mtu} dns=${controller.dnsServers.length} include=${controller.includeApps.length} exclude=${controller.excludeApps.length} routes=${controller.routes.length}');

      // 3. Real connect: permission → service → TUN → engine → probe.
      Logger.instance.info('vpn-session', '$trace VPN_PERMISSION requested');
      final ok = await controller.connect(
        probeTunnel: () => _probeThroughTunnel(trace),
        startupTimeout: Duration(seconds: deps.appSettings.connectionTimeoutSeconds),
        proxyMode: deps.appSettings.proxyMode,
      );
      Logger.instance.info(
          'vpn-session', ok ? '$trace CONNECTED' : '$trace FAILED stage=controller.connect (see prior stages)');
      if (!ok) {
        // NOTE (v0.4.4): we deliberately do NOT evict the bootstrap pin
        // here. A health-check failure is usually protocol/DPI/transport,
        // not a stale IP — and evicting a WORKING pin turns the next
        // connect into a race against a flaky instant re-resolve (device
        // trace 2026-09-15: attempt 1 pinned a good IP but timed out for
        // another reason; eviction made attempt 2 unpinned → engine
        // deadlock). Rotation is handled by the TTL + stale-while-error.
        if (_bootedHost != null) {
          Logger.instance.info('vpn-session',
              '$trace BOOT pin kept host=$_bootedHost (failure not DNS-shaped)');
        }
      }
      return ok;
    } catch (e, st) {
      Logger.instance.error('vpn-session',
          '$trace FAILED stage=connect exception=${e.runtimeType} msg=${Logger.redact(e.toString())}');
      Logger.instance.debug('vpn-session', '$trace stack=${Logger.redact(st.toString().split('\n').take(4).join(' | '))}');
      return false;
    }
  }

  /// §3 — clean disconnect; permission state is preserved by Android, so a
  /// subsequent connect skips the consent dialog (§37.12).
  Future<void> disconnect() async {
    await controller.stop();
    if (_xrayUpstreamPort > 0) {
      _xrayUpstreamPort = 0;
      await XrayBridge.instance.stop();
    }
  }

  /// Attempts full validation of a config by running the engine binary if
  /// present (desktop) — on Android, config validity is checked by the
  /// native engine at start (engine reports CONFIG_INVALID natively).
  ///
  /// Also emits a redacted structural summary of the FINAL config (§7):
  /// inbound types/ports, outbound tags/types, selector members, route
  /// final/rules — the same view the native side logs, pre-handoff.
  /// Resolves [profile]'s hostname outside the tunnel and returns a
  /// profile whose `server` is the verified public IP (SNI/Host fields
  /// backfilled with the original name so nothing TLS-facing changes).
  /// Non-routable answers and lookup failures leave the profile as-is.
  Future<ProxyProfile> _withBootstrappedAddress(
      ProxyProfile profile, String trace) async {
    final host = profile.server.trim();
    if (host.isEmpty || BootstrapResolver.isPublicV4(host)) return profile;
    final sw = Stopwatch()..start();
    String? ip;
    try {
      ip = await BootstrapResolver.instance.addressFor(profile);
    } catch (_) {
      ip = null;
    }
    sw.stop();
    if (ip == null || ip == host) {
      Logger.instance.info('vpn-session',
          '$trace BOOT host=$host pinned=false ms=${sw.elapsedMilliseconds}');
      return profile;
    }
    Logger.instance.info('vpn-session',
        '$trace BOOT host=$host pinned=$ip ms=${sw.elapsedMilliseconds}');
    _bootedHost = host;
    return profile.copyWith(
      server: ip,
      // Preserve the hostname for every identity field the cores use:
      // SNI, TLS server_name, Reality serverName, HTTP Host header.
      sni: profile.sni ?? host,
      host: profile.host ?? host,
    );
  }

  Future<String?> _buildEngineConfig(ProxyProfile profile, String trace) async {
    try {
      final bridge = deps.configBridge;
      final cores = deps.cores;
      final routing = bridge.routingProfile();
      final dns = bridge.dnsSettings();

      // Upstream daemons (Xray/MDVPN) do not run on Android in v0.4.x —
      // only sing-box-runnable nodes are connectable on-device. This is an
      // honest documented limitation, not a fake.
      // SINGLE-CORE GUARANTEE re-check at config-build time (defense in
      // depth): the config below is handed to libbox as-is, so an
      // upstream-owned (Xray/MDVPN/AWG) or xhttp profile reaching this point
      // means the selection gates above were bypassed — fail loudly instead
      // of generating a merged dual-core config.
      assert(() {
        final needsXrayUpstream = profile.transport == Transport.xhttp ||
            profile.rawParams['type'] == 'mkcp' ||
            profile.rawParams['type'] == 'kcp';
        if (needsXrayUpstream && _xrayUpstreamPort == 0) {
          throw StateError(
              'xhttp profile without a live Xray upstream reached config build');
        }
        if (!needsXrayUpstream &&
            !AndroidNodeSupport.coreAllowedOnAndroid(
                profile.effectiveCore)) {
          throw StateError(
              'single-core violation: ${profile.effectiveCore.name}/${profile.transport.name} '
              'profile reached Android config generation');
        }
        return true;
      }());

      // WARP chain (v0.4.3): the Settings toggle is authoritative on Android
      // too. chainMode == chain → the user-requested "config → WARP →
      // Cloudflare IP" (WARP last hop); warpAsOutbound → WARP outer tunnel.
      ProxyProfile? warpProfile;
      String? selectedWarpTag;
      final st = deps.appSettings;
      if (st.warpEnabled) {
        final acct = deps.warpRepo.account;
        if (acct != null &&
            acct.privateKey.isNotEmpty &&
            acct.peerPublicKey.isNotEmpty) {
          warpProfile = WarpRegistrar.profileFor(acct);
          if (st.warpChainMode == WarpChainMode.chain) {
            selectedWarpTag = 'warp';
          }
        }
      }
      // Upstream Xray (xhttp/mKCP nodes): expose the node as a local SOCKS
      // stub inside the front config; the tunnel is sing-box TUN -> socks ->
      // :xray process -> node. Real traffic, both cores cooperating per-node.
      final upstreams = <String, ({String host, int port})>{};
      final _needsXray = profile.transport == Transport.xhttp ||
          profile.rawParams['type'] == 'mkcp' ||
          profile.rawParams['type'] == 'kcp';
      if (_xrayUpstreamPort > 0 && _needsXray) {
        upstreams[profile.id] =
            (host: '127.0.0.1', port: _xrayUpstreamPort);
      }
      final cfg = cores.front.buildConfig(
        [profile],
        selectedProfileId: profile.id,
        routing: routing,
        dns: dns,
        socksUpstreams: {
          ...upstreams,
        },
        warpProfile: warpProfile,
        chainWarpOutside:
            warpProfile != null && selectedWarpTag == null,
        selectedWarpTag: selectedWarpTag,
      );
      // §8 diagnostic split: make sing-box log ITS OWN view (startups, dial
      // errors, fatals) to an adb-readable file. External files dir matches
      // the native EngineLogFile location (documented debug affordance).
      cfg['log'] = {
        'level': 'info',
        'timestamp': true,
        'output': '/sdcard/Android/data/com.example.nexus/files/singbox.log',
      };
      _logConfigSummary(cfg, trace);
      return jsonEncode(cfg);
    } catch (e, st) {
      Logger.instance.error('vpn-session',
          '$trace FAILED stage=CONFIG_GENERATED exception=${e.runtimeType} msg=${Logger.redact(e.toString())}');
      Logger.instance.debug('vpn-session',
          '$trace stack=${Logger.redact(st.toString().split('\n').take(4).join(' | '))}');
      return null;
    }
  }

  /// Redacted structural summary of the generated config (mirrors the
  /// native CONFIG_SUMMARY; values are type/tag-level, never credentials).
  void _logConfigSummary(Map<String, dynamic> cfg, String trace) {
    try {
      final inbounds = (cfg['inbounds'] as List?) ?? const [];
      final inb = inbounds.map((e) {
        final m = (e as Map).cast<String, dynamic>();
        return '${m['type']}:${m['tag']}${m['listen_port'] != null ? ':${m['listen_port']}' : ''}';
      }).join(' ');
      final outbounds = (cfg['outbounds'] as List?) ?? const [];
      final outb = outbounds.map((e) {
        final m = (e as Map).cast<String, dynamic>();
        final sel = (m['outbounds'] as List?)?.cast<String>();
        return '${m['tag']}(${m['type']})${sel != null ? '{${sel.join(',')}}' : ''}';
      }).join(' ');
      final route = (cfg['route'] as Map?)?.cast<String, dynamic>();
      final rules = (route?['rules'] as List?)?.length ?? 0;
      Logger.instance.info('vpn-session',
          '$trace CONFIG_SUMMARY inbounds=[$inb] outbounds=[$outb] route_rules=$rules final=${route?['final'] ?? '-'}');
    } catch (_) {
      // summary is best-effort; never blocks the connect path
    }
  }

  /// §2 — REAL probe through the tunnel. Uses the same HTTP-over-SOCKS
  /// tester as the desktop against sing-box's local mixed inbound, which
  /// the native engine runs INSIDE the tunnel. This is the gate before
  /// CONNECTED — a service that starts without a working tunnel fails here.
  ///
  /// The EXACT failure kind + detail is logged (no generic swallowing):
  /// proxy-greeting rejection vs CONNECT error vs DNS/TLS/HTTP failure.
  Future<bool> _probeThroughTunnel(String trace) async {
    final port = deps.cores.front.mixedPort;
    final probe = await deps.tester.testHttpViaSocksProxy(
      '127.0.0.1',
      port,
      'https://www.gstatic.com/generate_204',
      timeout: const Duration(seconds: 8),
    );
    if (probe.ok) {
      // v0.4.4 §user-2: the health probe IS a latency measurement — publish
      // it so the dashboard LATENCY tile shows a real number on-device.
      lastLatencyMs = probe.latencyMs;
      Logger.instance.info('vpn-session',
          '$trace HEALTH_CHECK via mixed:$port OK ${probe.latencyMs ?? '?'}ms');
    } else {
      Logger.instance.error('vpn-session',
          '$trace FAILED stage=HEALTH_CHECK via mixed:$port kind=${probe.errorKind} detail=${probe.detail != null ? Logger.redact(probe.detail!) : '-'}');
    }
    return probe.ok;
  }

  /// v0.4.1 device-fix: auto-pick must only consider nodes the ANDROID engine
  /// can actually run (sing-box native). Xray-owned / xhttp profiles need the
  /// upstream daemon that does not run in-app (documented limitation) —
  /// selecting one silently produced a direct-only selector and a dead TUN.
  /// Delegates to [AndroidNodeSupport] — the single source shared with the UI.
  static bool _androidRunnable(ProxyProfile p) =>
      AndroidNodeSupport.isRunnable(p);

  /// Honest exclusion report for NO_RUNNABLE_NODE: one line per profile,
  /// redaction-safe (names + reasons only, never endpoints/credentials).
  String _exclusionSummary() {
    final parts = <String>[];
    for (final p in deps.profiles.all) {
      if (!p.enabled) {
        parts.add('${p.name}=disabled');
        continue;
      }
      final why = AndroidNodeSupport.androidExclusionReason(p);
      parts.add(why == null ? '${p.name}=ok' : '${p.name}=$why');
    }
    if (parts.isEmpty) return '(no profiles in repository)';
    return 'excluded=[${parts.join('; ')}]';
  }

  ProxyProfile? _bestNode() {
    final all = deps.profiles.all
        .where((p) => p.enabled && _androidRunnable(p))
        .toList();
    if (all.isEmpty) return null;
    // Prefer a healthy node (health store), fall back to the first runnable.
    ProxyProfile? best;
    int bestScore = -1 << 30;
    for (final ProxyProfile p in all) {
      final stats = deps.healthStore.all[p.id];
      final healthy = stats != null && stats.state == NodeHealth.healthy;
      final lat = stats?.lastLatencyMs ?? 5000;
      final score = (healthy ? 1 << 20 : 0) + (100000 - lat.clamp(0, 100000));
      if (score > bestScore) {
        best = p;
        bestScore = score;
      }
    }
    return best ?? all.first;
  }

  void dispose() {
    _sub?.cancel();
    _selectionEvents.close();
    controller.dispose();
  }
}
