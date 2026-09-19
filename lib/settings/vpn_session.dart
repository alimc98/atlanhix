import 'dart:async';
import 'dart:convert';

import '../core/android_node_support.dart';
import '../core/fragmentation/fragment_profiles.dart';
import '../core/runtime/core_process.dart';
import '../core/logger.dart';
import '../core/net/bootstrap_dns.dart';
import '../core/health/latency_tester.dart';
import '../domain/entities/health.dart';
import '../domain/entities/proxy_profile.dart';
import '../core/configgen/xray_config_generator.dart';
import '../core/runtime/core_manager.dart';
import '../core/runtime/singbox_runtime.dart';
import '../core/engine_availability.dart';
import '../platform/xray_bridge.dart';
import '../warp/warp_registrar.dart';
import 'app_settings.dart';
import 'smart_switch.dart';
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

  /// v0.4.7 §user: SMART SWITCH — the default selection mode. When TRUE the
  /// session owns node choice: best candidate at connect time, continuous
  /// re-tests, live tunnel migration on a materially better/healthier node.
  /// Tapping a specific node turns it OFF (explicit pick wins); the Nodes
  /// tab's "Smart Switch" card turns it back on.
  bool smartSwitch = true;
  late final SmartSwitch _smart = SmartSwitch(
    scheduler: deps.scheduler,
    health: deps.healthStore,
    interval: Duration(seconds: deps.appSettings.smartSwitchIntervalSeconds),
    // v0.4.8 §user: the ladder ranks by REAL in-tunnel URL tests through
    // each candidate's outbound (engine delay test on its node tag) — the
    // TCP ping only proves the node IP answers, which crowned nodes whose
    // tunnel could not actually fetch anything. When no engine API is
    // available (disconnected) the probe returns null and the switcher
    // falls back to the scheduler's TCP tests.
    urlProbe: (p) async {
      final api = deps.cores.front.api;
      if (api == null) return null;
      final url = deps.appSettings.warpProbeUrl.isEmpty
          ? 'https://www.gstatic.com/generate_204'
          : deps.appSettings.warpProbeUrl;
      final ms = await api.delayTest(
          '${SingBoxRuntime.tagPrefix}${p.id}', url, 5000);
      return ProbeResult(ok: ms != null, latencyMs: ms,
          errorKind: ms == null ? 'timeout' : null);
    },
  );

  /// Local SOCKS port of the running :xray upstream (0 = not running).
  int _xrayUpstreamPort = 0;

  /// v0.4.7 §user: profile ids whose engine resolution is already logged
  /// this session (keeps the trace readable on repeated connects).
  final Set<String> _resolvedEngines = {};

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
      // v0.4.6: the generator now emits the platform-clean resolver pair
      // itself (domestic on Android, global on desktop) and never
      // `localhost` — the carrier-poison round-robin race is fixed at the
      // source for BOTH paths (see XrayConfigGenerator.defaultCleanServers).
      // v0.4.6 §user: the fragment pill (fixed or AUTO rung) now reaches the
      // Android :xray upstream config too — CoreManager.fragmentFor applies
      // the same eligibility + AUTO-rung semantics as the desktop starts.
      final xrayJson = XrayConfigGenerator().generate(
        profile: profile,
        routing: deps.configBridge.routingProfile(),
        localSocksPort: port,
        fragment: deps.cores.fragmentFor(profile),
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
    // An explicit tap STEERS away from auto — smart mode resumes only via
    // [enableSmartSwitch] (the Nodes-tab card).
    smartSwitch = false;
    _smart.stop();
    Logger.instance.info('vpn-session',
        '[ATX-DART UI] NODE_SELECTED ${p.name} proto=${p.protocol.name} '
        'transport=${p.transport.name} core=${p.effectiveCore.name}');
    _selectionEvents.add(null);
  }

  /// v0.4.7 §user: re-arms the Smart Switch (Nodes-tab card / Settings).
  /// Immediately recommends the currently-best known node and starts the
  /// periodic sweep; if the tunnel is UP on a different node, the change
  /// stream migrates it.
  void enableSmartSwitch() {
    smartSwitch = true;
    _smart
      ..interval = Duration(seconds: deps.appSettings.smartSwitchIntervalSeconds)
      ..start(SmartSwitch.candidatesOf(deps.profiles.all),
          currentId: selectedNode?.id);
    _selectionEvents.add(null);
  }

  /// v0.4.8 §user: turns the Smart Switch OFF — the user's tap on the
  /// card's OFF state is an explicit hand-back to manual selection. Before
  /// this the card's Switch only re-fired enableSmartSwitch(), so a node
  /// that was ON could never be turned OFF from the card (device report).
  void disableSmartSwitch() {
    smartSwitch = false;
    _smart.stop();
    _selectionEvents.add(null);
    Logger.instance.info('smart-switch',
        '[ATX-DART] SMART_SWITCH disabled by user — manual selection');
  }

  /// Proxy for UI reads (Nodes-tab card highlight).
  bool get isSmartSwitchActive => smartSwitch;

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
    // v0.4.8 §user: a terminal/failed/disconnected phase cancels the WARP
    // URL-watchdog (nothing to probe when the tunnel is down).
    if (controller.phase == AndroidVpnPhase.idle ||
        controller.phase == AndroidVpnPhase.stopped ||
        controller.phase == AndroidVpnPhase.failed ||
        controller.phase == AndroidVpnPhase.revoked) {
      _warpWatchdog?.cancel();
      _warpWatchdog = null;
      _warpFails = 0;
    }
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
    // v0.4.7 §user: smart mode is the DEFAULT — with no explicit pick the
    // ladder starts here and keeps re-testing; tunnel migrates on change.
    if (smartSwitch) {
      _smart
        ..interval = Duration(seconds: deps.appSettings.smartSwitchIntervalSeconds)
        ..start(SmartSwitch.candidatesOf(deps.profiles.all),
            currentId: best.id);
      _smartSub ??= _smart.changes.listen(_migrateForSmartSwitch);
    }
    return _connectProfile(best, trace);
  }

  StreamSubscription<ProxyProfile>? _smartSub;

  /// v0.4.8 §user: LIVE migration — swap the front sing-box selector to the
  /// newly-recommended node via the Clash API WITHOUT tearing the tunnel
  /// down. The previous behavior re-ran the full connect flow for every
  /// switch; on a phone that is a whole permission/TUN/engine cycle and the
  /// user saw "the app disconnected itself" (device report). A failed swap
  /// (dead API / stub) falls back to the full connect path so the migration
  /// still happens.
  ///
  /// On non-Android (CoreManager front engine) the same selector swap is
  /// attempted via [CoreManager.hotSwitch], which additionally starts the
  /// Xray/MDVPN upstream for daemon-owned nodes.
  Future<void> _migrateForSmartSwitch(ProxyProfile next) async {
    if (!smartSwitch) return;
    if (controller.phase != AndroidVpnPhase.connected) {
      // Not connected — just remember the recommendation for the next connect.
      selectedNode = next;
      _selectionEvents.add(null);
      return;
    }
    Logger.instance.info('smart-switch',
        '[ATX-DART] MIGRATE → ${next.name} (tunnel stays up during switch)');
    selectedNode = next;
    _selectionEvents.add(null);

    // 1) Fast path: Clash-API selector swap (sub-second, zero traffic
    //    interruption on the TUN interface itself).
    final api = deps.cores.front.api;
    if (api != null) {
      final ok = await api.select(
          SingBoxRuntime.selectorTag, '${SingBoxRuntime.tagPrefix}${next.id}');
      if (ok) {
        // v0.4.8 §user: the swap must be a VERIFIED handover, not a silent
        // timeout — a dead node now lands the session on FAILED instead of
        // celebrating a connected pill over a dead tunnel.
        final probe = await _probeThroughTunnel('SMART_SWITCH_MIGRATE');
        if (probe) return; // tunnel continues on the new node
        Logger.instance.warn('smart-switch',
            '[ATX-DART] MIGRATE probe failed on ${next.name} — falling back to reconnect');
        // fall through to the full reconnect below.
      }
    }

    // 2) Fallback: full reconnect (new config, permission already granted).
    await connect(node: next);
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
    // ── ENGINE RESOLUTION (v0.4.7 §user device fix) ──
    // Imported/persisted profiles carry core=unknown (only the desktop
    // ConnectionController ran the detector, on its in-memory copy that is
    // never persisted). Device evidence (2026-09-17, CDN-UK mlkem node):
    // the detector would route it to Xray (post-quantum VLESS → sing-box
    // 1.14 has no `encryption` field and silently negotiates 'none' → the
    // server resets the handshake: `outbound/vless[…]: EOF` in singbox.log),
    // but with core=unknown every Android gate saw `unknown` and the node
    // was served as a NATIVE sing-box outbound. Run the detector HERE — on
    // the actual object we are about to connect with — so
    // androidExclusionReason / isEligible / the upstream gate / the front
    // builder all see the SAME engine for this connect.
    final resolvedCore = deps.detector.resolve(profile).core;
    // Only write when different — the connect paths may run repeatedly on
    // the same profile object, and a second resolution would otherwise
    // skip the log line (effectiveCore is already xray after run 1).
    if (profile.effectiveCore != resolvedCore) {
      Logger.instance.info('vpn-session',
          '$trace ENGINE_RESOLVED node=${profile.name} '
          '${profile.effectiveCore.name} -> ${resolvedCore.name}');
      profile.core = resolvedCore;
    } else if (_resolvedEngines.add(profile.id)) {
      Logger.instance.info('vpn-session',
          '$trace ENGINE_RESOLVED node=${profile.name} -> ${resolvedCore.name}');
    }

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
    //
    // v0.4.7 §loop-fix: this pin MUST run BEFORE the :xray upstream starts —
    // the child process has no VpnService.protect fd hook (gomobile AAR is
    // banned by libbox's go.Seq), so its server traffic only escapes the TUN
    // via the front's direct-outbound bypass rule (see socksUpstreamHosts),
    // and that rule needs the RESOLVED server IP. Pinning first means the
    // bypass is always exact — even for nodes whose hostname only resolves
    // through the bootstrap resolver (carrier-poisoned system DNS).
    profile = await _withBootstrappedAddress(profile, trace);

    // v0.4.6 §user: a fresh Android connect BEGINS the fragment AUTO ladder
    // (rung 0 — or the node's persisted winning rung from the ladder cache)
    // BEFORE any engine config is generated, so the first :xray start of this
    // connect already carries the right rung. Fixed presets are unaffected.
    deps.cores.fragmentPreset = deps.appSettings.fragmentPreset;
    deps.cores.tlsFragmentEnabled = deps.appSettings.tlsFragment;
    deps.cores.beginAutoLadder(profile);

    // xhttp / mKCP / detected-Xray (e.g. post-quantum VLESS encryption):
    // the front sing-box CANNOT express them — the :xray child process must
    // serve the node as a local SOCKS upstream (v2rayNG/NekoBox topology).
    // v0.4.7 §loop-fix: the gate uses CoreManager.needsXrayUpstream so a
    // DETECTED Xray core (not just the xhttp/mKCP transports) reaches the
    // upstream path — before this, PQ-encryption CDN nodes fell through to
    // the native sing-box outbound and every handshake died with EOF.
    if (CoreManager.needsXrayUpstream(profile)) {
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
      // v0.4.6 WIRING: the TLS-Fragment pill reaches BOTH engines on Android
      // too — sing-box via the tls.fragment option of the front config, Xray
      // via the CoreManager's native freedom-fragment form (the :xray
      // upstream is started through deps.cores below / _startXrayUpstream).
      front.tlsFragment = deps.appSettings.tlsFragment;
      // NOTE: tlsFragmentEnabled/fragmentPreset/beginAutoLadder were pushed
      // to CoreManager EARLIER in this method — before the :xray upstream
      // start — so the first Xray config of this connect carries the right
      // fragment rung (see the v0.4.6 §user block above the xhttp gate).
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
      // v0.4.8 §user: arm the in-tunnel URL watchdog on a real CONNECTED,
      // cancel it on every terminal state (see _syncFromAndroid).
      if (ok) _armWarpWatchdog();
      if (!ok) {
        // v0.4.6 §user-3: the FIRST rung's probe is a real attempt too —
        // the native controller.connect already failed its own tunnel probe,
        // so the starting rung counts as tried (and failed) here.
        if (deps.cores.tlsFragmentEnabled &&
            deps.cores.fragmentPreset == FragmentPreset.auto &&
            FragmentationEngine().isEligible(profile)) {
          final firstRung = deps.cores.currentAutoFragment;
          if (firstRung != null) {
            await deps.cores.fragmentLadder?.recordRungAttempt(
                profile.subscriptionId, firstRung,
                won: false);
          }
        }
        // v0.4.6 §user: fragment AUTO ladder — the tunnel probe failed, so
        // climb conservative → default → aggressive before reporting the
        // failure. A win here IS a connected session (the rung re-probed
        // through the real tunnel and recorded itself as the node's winner).
        final climbed =
            await _escalateFragmentAfterProbeFailure(profile, trace);
        if (climbed) {
          Logger.instance.info('vpn-session', '$trace CONNECTED (fragment auto)');
          return true;
        }
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
    _smart.stop();
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
        final needsXrayUpstream = CoreManager.needsXrayUpstream(profile);
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

      // WARP chain (v0.4.3, reshaped v0.4.8 §user): the chain MODE is the
      // single authority — no separate on/off flag. Two real directions:
      //  * warpFirst — WARP dials the node (app → WARP → node → internet):
      //    the filtered node's handshake is masked inside the WARP tunnel;
      //  * warpLast — the node dials WARP (app → node → WARP → internet):
      //    the exit IP is Cloudflare's (sanctions evasion).
      // `off` (the default) generates the plain no-WARP topology — WARP
      // never silently wraps node traffic (the v0.4.7 regression).
      ProxyProfile? warpProfile;
      String? selectedWarpTag;
      final st = deps.appSettings;
      if (st.warpChainMode != WarpChainMode.off) {
        final acct = deps.warpRepo.account;
        if (acct != null &&
            acct.privateKey.isNotEmpty &&
            acct.peerPublicKey.isNotEmpty) {
          warpProfile = WarpRegistrar.profileFor(acct);
          if (st.warpChainMode == WarpChainMode.warpLast) {
            selectedWarpTag = 'warp';
          }
        } else {
          Logger.instance.warn('vpn-session',
              '$trace WARP chain mode ${st.warpChainMode.name} but no registered account — plain topology');
        }
      }
      // Upstream Xray (xhttp/mKCP nodes AND detected-Xray cores — e.g. the
      // post-quantum `mlkem…` VLESS encryption, which no sing-box outbound
      // can express): expose the node as a local SOCKS stub inside the front
      // config; the tunnel is sing-box TUN -> socks -> :xray process -> node.
      // v0.4.7 §loop-fix: the check MUST be CoreManager.needsXrayUpstream —
      // a transport-only test missed the PQ CDN nodes (vless+ws) and they
      // fell through to a native sing-box outbound that rejects `encryption`
      // (device log: EOF on every handshake).
      final upstreams = <String, ({String host, int port})>{};
      if (_xrayUpstreamPort > 0 && CoreManager.needsXrayUpstream(profile)) {
        upstreams[profile.id] =
            (host: '127.0.0.1', port: _xrayUpstreamPort);
      }
      // v0.4.8 §user (Smart Switch): the front engine carries the WHOLE
      // runnable pool, not just the active node — selector hot-swap then
      // migrates the tunnel with zero disconnect, and the ladder ranks
      // candidates with REAL engine delay tests (URL through each node's
      // outbound) instead of a bare TCP ping to the node IP. Upstream-owned
      // nodes (Xray daemons) stay stubbed ONLY for the active one — a stub
      // whose daemon is not running would be a dead selector member.
      final pool = deps.profiles.all
          .where((p) => p.enabled && AndroidNodeSupport.isRunnable(p))
          .where((p) =>
              !CoreManager.needsXrayUpstream(p) || p.id == profile.id)
          .map((p) => p.id == profile.id ? profile : p)
          .toList();
      // v0.4.7 §loop-fix: server IPs the :xray CHILD dials (the node, plus
      // its configured resolvers) must NOT re-enter the TUN — the child has
      // no VpnService.protect hook, so its sockets can only escape via the
      // front's protected direct outbound. Without this route rule the
      // child's traffic loops into its own SOCKS listener and the tunnel
      // dies with `software caused connection abort` (device log 2026-09-17).
      // The stub (127.0.0.1) never matches an ip_cidr rule, so no flow is
      // double-wrapped — the rule only serves the child's own dials.
      final bypass = CoreManager.needsXrayUpstream(profile)
          ? XrayConfigGenerator.childDialBypassCidrs(
              profile, dns: dns)
          : const <String>[];
      final cfg = cores.front.buildConfig(
        pool,
        selectedProfileId: profile.id,
        routing: routing,
        dns: dns,
        socksUpstreams: {
          ...upstreams,
        },
        bypassCidrs: bypass,
        warpProfile: warpProfile,
        // v0.4.8 §user: the chain MODE owns the direction — warpFirst passes
        // chainWarpOutside=true (the node's socket dials through the WARP
        // tunnel: app → WARP → node → internet); warpLast/off leave it false
        // (plain node, WARP-as-member or no WARP at all). WARP must NEVER
        // wrap node traffic except through this explicit user choice.
        chainWarpOutside: st.warpChainMode == WarpChainMode.warpFirst,
        selectedWarpTag: selectedWarpTag,
      );
      // §8 diagnostic split: make sing-box log ITS OWN view (startups, dial
      // errors, fatals) to an adb-readable file. External files dir matches
      // the native EngineLogFile location (documented debug affordance).
      //
      // v0.4.8 §user (WARP rescue door): when a WARP account exists and the
      // user's mode is NOT warp-first, the warp-first TWIN of the ACTIVE node
      // (tag `node:<id>:warpfirst`) is appended to the same config — enabling
      // the rescue chain at run time becomes a Clash-API selector swap with
      // zero rebuild. For an Xray-upstream node the twin is the stub with
      // detour:warp (the child's dials exit through the WARP tunnel).
      if (warpProfile != null &&
          st.warpChainMode != WarpChainMode.warpFirst) {
        final rescueTag = 'node:${profile.id}:warpfirst';
        final twinCfg = cores.front.buildConfig(
          [profile],
          selectedProfileId: profile.id,
          routing: routing,
          dns: dns,
          socksUpstreams: upstreams,
          bypassCidrs: bypass,
          warpProfile: warpProfile,
          chainWarpOutside: true,
        );
        final twinOut = ((twinCfg['outbounds'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .firstWhere(
          (o) => o['tag'] == 'node:${profile.id}',
          orElse: () => const {},
        );
        if (twinOut.isNotEmpty) {
          twinOut['tag'] = rescueTag;
          final outbounds = cfg['outbounds'] as List;
          outbounds.add(twinOut);
          final selector = outbounds.firstWhere(
              (o) => (o as Map)['tag'] == 'proxy',
              orElse: () => null) as Map<String, dynamic>?;
          if (selector != null) {
            (selector['outbounds'] as List).add(rescueTag);
          }
        }
      }
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

  /// v0.4.6 §user — fragment AUTO escalation ladder (Android). With the
  /// fragment pill on and fragmentPreset == auto, a failed tunnel probe
  /// climbs [CoreManager.advanceAutoLadder]: restart the :xray upstream with
  /// the NEXT fragment rung, re-probe, and on success record the winning
  /// rung in the per-node ladder cache. Exhausted → false; the caller
  /// reports its honest failure. Fixed presets never enter here.
  ///
  /// Scope note: the ladder is Xray-upstream-only BY DESIGN —
  /// FragmentationEngine.isEligible admits Xray-core nodes only, and on
  /// Android those are exactly the xhttp/mKCP nodes served by :xray. The
  /// sing-box front carries a boolean tls.fragment with no intensity rungs,
  /// so re-connecting an identical front config would be a dishonest retry.
  Future<bool> _escalateFragmentAfterProbeFailure(
      ProxyProfile profile, String trace) async {
    if (!deps.cores.tlsFragmentEnabled) return false;
    if (deps.cores.fragmentPreset != FragmentPreset.auto) return false;
    if (!FragmentationEngine().isEligible(profile)) return false;
    Logger.instance.info('vpn-session',
        '$trace FRAGMENT_AUTO probe failed — climbing the ladder');
    while (deps.cores.advanceAutoLadder()) {
      final rung = deps.cores.currentAutoFragment;
      Logger.instance.info('vpn-session',
          '$trace FRAGMENT_AUTO retrying with next rung${rung != null ? ' (${rung.id})' : ''}');
      // Xray-owned node: restart ONLY the upstream with the next rung, then
      // re-probe through the (unchanged) front tunnel.
      if (_xrayUpstreamPort > 0) {
        await XrayBridge.instance.stop();
        _xrayUpstreamPort = 0;
      }
      if (!await _startXrayUpstream(profile, trace)) continue;
      final ok = await _probeThroughTunnel(trace);
      // v0.4.6 §user-3: every real probe is an attempt — pass or fail.
      if (rung != null) {
        await deps.cores.fragmentLadder?.recordRungAttempt(
            profile.subscriptionId, rung,
            won: ok);
      }
      if (ok) {
        if (rung != null) {
          await deps.cores.fragmentLadder?.recordWinner(profile.id, rung);
          // v0.4.6 §user-2: promote the proven rung to the subscription-
          // level suggestion so sibling nodes START there (they still wrap
          // through every rung when it does not fit them).
          await deps.cores.fragmentLadder?.recordSuggestion(
              profile.subscriptionId, rung);
        }
        Logger.instance.info('vpn-session',
            '$trace FRAGMENT_AUTO won at rung ${rung?.id ?? '?'} (redacted node id)');
        return true;
      }
      Logger.instance.warn('vpn-session',
          '$trace FRAGMENT_AUTO rung did not answer the probe');
    }
    return false;
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

  // ---------------------------------------------------------------------
  // v0.4.8 §user — WARP auto-rescue: the filter detector.
  //
  // Contract: while connected with WARP off (plain topology), the session
  // periodically URL-tests the ACTIVE node THROUGH the tunnel (the real
  // criterion — not a TCP ping to the node IP). N consecutive failures
  // (settings.warpAutoOfferThreshold, default 5) = "this node looks
  // filtered": the app ASKS (dialog via [onWarpOffer]) to enable the
  // warp-first chain for this node — a selector swap to the pre-built
  // `node:<id>:warpfirst` twin (zero rebuild). The user can decline; a
  // decline is remembered per node and never re-asked. When the rescue
  // chain itself fails to answer the probe, the original plain selection
  // is restored and the failure counter resets — the tunnel is never left
  // down after an automated experiment.
  // ---------------------------------------------------------------------

  /// Asks the user. UI layer assigns: (context) → Future<bool>.
  Future<bool> Function(String nodeName)? onWarpOffer;

  Timer? _warpWatchdog;
  int _warpFails = 0;
  final Set<String> _warpDeclined = {};

  void _armWarpWatchdog() {
    _warpWatchdog?.cancel();
    _warpWatchdog = null;
    final st = deps.appSettings;
    if (st.warpChainMode != WarpChainMode.off) return; // chain already chosen
    if (st.warpAutoOfferThreshold <= 0) return; // detector disabled
    final url = st.warpProbeUrl.isEmpty
        ? 'https://www.gstatic.com/generate_204'
        : st.warpProbeUrl;
    final period = Duration(
        seconds: st.smartSwitchIntervalSeconds > 0
            ? st.smartSwitchIntervalSeconds
            : 120);
    _warpWatchdog = Timer.periodic(period, (_) => _warpUrlCheck(url));
  }

  Future<void> _warpUrlCheck(String url) async {
    if (controller.phase != AndroidVpnPhase.connected) return;
    final node = selectedNode;
    if (node == null) return;
    final st = deps.appSettings;
    if (st.warpChainMode != WarpChainMode.off) {
      _warpFails = 0;
      return;
    }
    final api = deps.cores.front.api;
    if (api == null) return;
    final ms = await api.delayTest(
        '${SingBoxRuntime.tagPrefix}${node.id}', url, 5000);
    if (ms != null) {
      _warpFails = 0; // the tunnel really works — reset the counter
      return;
    }
    _warpFails++;
    Logger.instance.warn('warp-offer',
        '[ATX-DART] WARP_DETECT url-test failed ($_warpFails/${st.warpAutoOfferThreshold}) node=${node.name}');
    if (_warpFails < st.warpAutoOfferThreshold) return;
    _warpFails = 0;
    if (_warpDeclined.contains(node.id)) return;
    if (onWarpOffer == null) return;
    final yes = await onWarpOffer!(node.name);
    if (!yes) {
      _warpDeclined.add(node.id);
      Logger.instance.info('warp-offer',
          '[ATX-DART] WARP_OFFER declined for ${node.name} — will not re-ask');
      return;
    }
    await _enableWarpFirstFor(node);
  }

  /// Chains WARP in front of the running node: flips the persisted mode to
  /// warpFirst, swaps the selector to the pre-built twin, verifies with a
  /// real URL probe and restores the plain selection when the rescue fails.
  Future<void> _enableWarpFirstFor(ProxyProfile node) async {
    final api = deps.cores.front.api;
    final rescueTag = 'node:${node.id}:warpfirst';
    if (api == null) return;
    Logger.instance.info('warp-offer',
        '[ATX-DART] WARP_RESCUE chaining WARP in front of ${node.name} (selector swap)');
    final ok = await api.select(SingBoxRuntime.selectorTag, rescueTag);
    if (!ok) {
      Logger.instance
          .warn('warp-offer', '[ATX-DART] WARP_RESCUE twin member missing — reconnect required');
      // Persist the user's choice; the next connect builds warpFirst natively.
      deps.appSettings.warpChainMode = WarpChainMode.warpFirst;
      await deps.appSettingsRepo.save(deps.appSettings);
      await connect(node: node);
      return;
    }
    final url = deps.appSettings.warpProbeUrl.isEmpty
        ? 'https://www.gstatic.com/generate_204'
        : deps.appSettings.warpProbeUrl;
    final ms = await api.delayTest(
        SingBoxRuntime.selectorTag, url, 8000);
    if (ms != null) {
      deps.appSettings.warpChainMode = WarpChainMode.warpFirst;
      await deps.appSettingsRepo.save(deps.appSettings);
      Logger.instance.info('warp-offer',
          '[ATX-DART] WARP_RESCUE OK (${ms}ms via chained node)');
      return;
    }
    // Rescue failed — put the user back where they were.
    Logger.instance.warn('warp-offer',
        '[ATX-DART] WARP_RESCUE probe failed — restoring plain node');
    await api.select(
        SingBoxRuntime.selectorTag, '${SingBoxRuntime.tagPrefix}${node.id}');
  }

  void dispose() {
    _warpWatchdog?.cancel();
    _smartSub?.cancel();
    _smart.dispose();
    _sub?.cancel();
    _selectionEvents.close();
    controller.dispose();
  }
}
