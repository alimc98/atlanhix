import 'dart:async';

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/android_node_support.dart';
import '../core/fragmentation/fragment_profiles.dart';
import '../core/runtime/core_process.dart';
import '../core/logger.dart';
import '../core/net/bootstrap_dns.dart';
import '../core/health/latency_tester.dart';
import '../domain/entities/health.dart';
import '../domain/entities/proxy_profile.dart';
import '../core/configgen/mihomo_config_generator.dart';
import '../core/configgen/xray_config_generator.dart';
import '../core/runtime/core_manager.dart';
import '../core/runtime/clash_api_client.dart';
import '../core/runtime/singbox_runtime.dart';
import '../core/engine_availability.dart';
import '../platform/mihomo_bridge.dart';
import '../platform/xray_bridge.dart';
import '../warp/warp_registrar.dart';
import 'app_settings.dart';
import 'smart_switch.dart';
import '../platform/android_vpn.dart';
import '../platform/probe_engine.dart';
import '../application/connection_controller.dart';
import '../application/dependencies.dart';

/// v0.5.9 §retarget: one running connect attempt. Lives at library scope
/// so [VpnSession] can hold it as a field type; carries only the flag the
/// retarget handshake mutates.
class _ConnectAttempt {
  _ConnectAttempt();

  /// Set when a newer tap redirects this attempt to a different node; the
  /// running flow then yields its verdict to the redial.
  ///
  /// v0.5.9 §retarget: ownership is BY IDENTITY — every redial registers a
  /// FRESH attempt, so a superseded flow (and its in-flight tunnel probe)
  /// detects it by `!identical(_runningAttempt, mine)` and aborts. The slot
  /// may briefly outlive its flow (freed by the dial's finally / overwritten
  /// at the next connect); consumers gate on in-flight phase, not on null.
  bool redirected = false;

  /// v0.6.2 §stop-fix: the user STOPPED (the dashboard pill was tapped while
  /// this attempt was still connecting). The attempt must abort its funnel
  /// and its tunnel probe immediately and never write a verdict — the
  /// disconnect owns the UI, and a late `failed`/`connected` from this flow
  /// is exactly the "نمیشه متوقف کرد" bug (the stop looked ignored and the
  /// tunnel came back up after the user had killed it).
  bool cancelled = false;
}

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
    // v0.5.2 §user: PER-NODE USAGE — fold the engine's global counters
    // into the active node's bucket on every native state poll (the same
    // 2 s cadence the dashboard reads for speeds). Delta accounting keeps
    // every byte attributed to exactly the node that carried it.
    _usageTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (controller.isConnected && selectedNode != null) {
        deps.nodeUsage
            .fold(selectedNode!.id, controller.upBytes, controller.downBytes);
      }
    });
  }

  /// v0.6.2 §stop-fix: is [a] still the session's live attempt? Ownership is
  /// BY IDENTITY (v0.5.9 §retarget) plus the two terminal flags: `redirected`
  /// = a newer node owns the dial, `cancelled` = the user stopped everything.
  /// A null/dead attempt owns nothing, so a stale flow can never boot an
  /// engine, probe a tunnel or publish a verdict.
  bool _ownsAttempt(_ConnectAttempt? a) =>
      a != null && identical(_runningAttempt, a) && !a.redirected && !a.cancelled;

  /// v0.6.2 §tap-fix ("یه کانفیگ دیگه رو کانکت کرد" while connecting): is a
  /// connect run in flight right now (either the controller's own body or a
  /// phase that a run owns)? Drives both the retarget on a node tap and the
  /// supersede on a fresh connect request.
  /// v0.6.2 §boot-race-fix: does this exclusion reason exist only because an
  /// engine-availability probe has not answered yet (rather than because the
  /// engine is genuinely absent)? Those are the reasons worth a grace window.
  static bool _runtimeGatedReason(String why) =>
      why.startsWith('mihomo:') ||
      why.startsWith('xray_transport:') ||
      why.startsWith('xray_pinned:') ||
      why.startsWith('amnezia_wg:');

  bool _connectInFlight() =>
      controller.connectRunActive ||
      controller.phase == AndroidVpnPhase.preparing ||
      controller.phase == AndroidVpnPhase.starting ||
      controller.phase == AndroidVpnPhase.validating ||
      controller.phase == AndroidVpnPhase.reconnecting;

  final AppDependencies deps;
  late final AndroidVpnController controller;
  StreamSubscription<AndroidVpnPhase>? _sub;
  Timer? _usageTimer;

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
    // v0.5.2 §user — the professional dials (live-synced in _armSmart):
    marginPercent: deps.appSettings.smartSwitchMarginPercent,
    activeRecheckInterval:
        Duration(seconds: deps.appSettings.smartSwitchActiveRecheckSeconds),
    othersRescanInterval:
        Duration(minutes: deps.appSettings.smartSwitchOthersRescanMinutes),
    // v0.5.0 §perf-fix: the WHOLE candidate pool in ONE call. The old
    // per-node urlProbe re-entered the transient probe engine per candidate
    // — every new node id REBUILT the Box (a full libbox restart) and all
    // parallel measurements died mid-sweep, so the ladder starved ("the
    // switch never switches") and pings took forever. One boot + parallel
    // delay tests now feeds the ladder real numbers in seconds.
    urlBatchProbe: (batch, {onNode}) async {
      final url = deps.appSettings.effectiveDelayTestUrl;
      // 1) LIVE engine (VPN up): measure through the running config —
      //    tags of nodes not in the running pool answer honestly below.
      final live = await liveEngineApi();
      if (live != null) {
        return _delayBatchVia(live, batch, url,
            missing: ProbeResult(
                ok: false, latencyMs: null,
                errorKind: 'engine-off',
                detail: 'not in live config'),
            onNode: onNode);
      }
      // 2) Transient probe engine (no VPN): one boot for the whole pool.
      //    v0.5.2 §user: per-node reporting rides straight through so the
      //    dashboard hero counts the ladder live.
      final ms = await ProbeEngine.instance
          .delayTestBatch(batch, url, 5000, onNode: onNode);
      if (ms.isEmpty) {
        return {
          for (final p in batch)
            p.id: ProbeResult(
                ok: false, latencyMs: null,
                errorKind: 'engine-off',
                detail: 'probe engine unavailable'),
        };
      }
      return {
        for (final p in batch)
          p.id: ms[p.id] == null
              ? ProbeResult(
                  ok: false, latencyMs: null, errorKind: 'timeout')
              : ProbeResult(ok: true, latencyMs: ms[p.id]),
      };
    },
    // v0.4.8 §user: the ladder ranks by REAL in-tunnel URL tests through
    // each candidate's outbound — the TCP ping only proves the node IP
    // answers, which crowned nodes whose tunnel could not actually fetch
    // anything. When no engine API is available (disconnected) the probe
    // returns null and the switcher falls back to the scheduler's TCP
    // tests.
    // v0.5.0 §user: the switch tolerance is a real field (Settings →
    // Smart Switch tolerance, ms) — kept in sync on every (re)arm below.
    marginMs: deps.appSettings.smartSwitchMarginMs,
    urlProbe: (p) async {
      // v0.5.0 §user-fix ("smart switch never pings"): the probe used to
      // read `deps.cores.front.api` ONLY — on Android libbox runs INSIDE
      // the VPN process and that getter is ALWAYS null, so every periodic
      // sweep measured NOTHING and the ladder starved (the only real
      // numbers came from the manual "test all" button). Route through
      // the SAME RealDelayTester the node list uses: live engine when a
      // VPN is up, else the transient probe engine (consent-free, its
      // own ports) — with an honest per-node result either way.
      final url = deps.appSettings.effectiveDelayTestUrl;
      // 1) Live front engine (desktop child process — on Android this is
      //    null and we fall through to the probe engine).
      final live = await liveEngineApi();
      if (live != null) {
        final ms = await live.delayTest(
            '${SingBoxRuntime.tagPrefix}${p.id}', url, 5000);
        return ProbeResult(ok: ms != null, latencyMs: ms,
            errorKind: ms == null ? 'timeout' : null);
      }
      // 2) Transient probe engine (Android libbox, ports 7891/9090). A
      //    null answer = engine down/unstartable → TCP fallback below.
      final ms = await ProbeEngine.instance.delayTest(p, url, 5000);
      return ProbeResult(ok: ms != null, latencyMs: ms,
          errorKind: ms == null ? 'engine-off' : null);
    },
  );

  /// Local SOCKS port of the running :xray upstream (0 = not running).
  int _xrayUpstreamPort = 0;

  /// v0.5.9 §retarget: the node the CURRENT connect attempt should dial —
  /// set by [selectNode] (a mid-flight tap) and by connect() itself.
  ProxyProfile? _connectTarget;

  /// One running connect attempt — the retarget handshake between
  /// connect()/selectNode() and [_connectProfile].
  _ConnectAttempt? _runningAttempt;

  /// v0.5.3 §mihomo — local mixed port of a RUNNING :mihomo child (0 = not
  /// running). The front config stubs this for mihomo-owned nodes.
  int _mihomoUpstreamPort = 0;

  /// v0.5.0 §user-fix: a WORKING Clash-API client for the live engine, or
  /// null. On Android libbox runs INSIDE the VPN service process and
  /// `front.api` is never constructed — only this probe-and-cache path
  /// (same as the node list's engineDelayTest) ever reaches the listener on
  /// :9097. Everything that needs the live table (ladder probes, selector
  /// migration, the WARP watchdog) must go through THIS, not through the
  /// always-null getter — the old migrate path fell through to a FULL
  /// reconnect on every switch because of it.
  Future<ClashApiClient?> liveEngineApi() => deps.liveEngineApi();

  /// Delay-tests [batch] through [api] in parallel. A tag missing from the
  /// RUNNING config gets [missing] verbatim (engine-off → honest
  /// fall-through), never a fake 5-second timeout.
  /// v0.5.2 §user: [onNode] fires per LANDED measurement (live ladder
  /// count); a missing-tag node is reported immediately with null ms.
  static Future<Map<String, ProbeResult>> _delayBatchVia(
    ClashApiClient api,
    List<ProxyProfile> batch,
    String url, {
    required ProbeResult missing,
    void Function(ProxyProfile p, int? ms)? onNode,
  }) async {
    final out = <String, ProbeResult>{};
    await Future.wait(batch.map((p) async {
      final tag = '${SingBoxRuntime.tagPrefix}${p.id}';
      // The tag exists in the config? (cheap /proxies read, cached table on
      // the engine side of the wire is still one HTTP round trip — but one
      // per node in parallel is fine.)
      final tags = await api.proxyTags();
      if (tags == null || !tags.contains(tag)) {
        out[p.id] = missing;
        onNode?.call(p, null);
        return;
      }
      int? ms;
      try {
        ms = await api.delayTest(tag, url, 5000);
      } catch (_) {
        ms = null;
      }
      onNode?.call(p, ms);
      out[p.id] = ms == null
          ? ProbeResult(ok: false, latencyMs: null, errorKind: 'timeout')
          : ProbeResult(ok: true, latencyMs: ms);
    }));
    return out;
  }

  /// v0.4.7 §user: profile ids whose engine resolution is already logged
  /// this session (keeps the trace readable on repeated connects).
  final Set<String> _resolvedEngines = {};

  /// v0.4.4: last successful tunnel-probe latency (dashboard tile).
  int? lastLatencyMs;

  /// Generate the node's Xray config and boot the :xray process with it.
  /// v0.5.3 §mihomo — start the :mihomo child for a mihomo-owned node.
  /// The config comes from [MihomoConfigGenerator] (full engine ownership);
  /// the mixed inbound listens on 2081 and the FRONT config stubs it as the
  /// node's dial-out — the same daemon topology as :xray.
  Future<bool> _startMihomoUpstream(ProxyProfile profile, String trace) async {
    try {
      final cfg = MihomoConfigGenerator.ports(mixedPort: 2081, apiPort: 9099)
          .build(
        profiles: [profile],
        selectedId: profile.id,
        routing: deps.configBridge.routingProfile(),
        dns: deps.configBridge.dnsSettings(),
      );
      final ok = await MihomoBridge.instance
          .start(jsonEncode(cfg), 2081);
      if (!ok) {
        lastError = 'MIHOMO_START_FAILED';
        Logger.instance.error('vpn-session',
            '$trace FAILED stage=MIHOMO_UPSTREAM node=${profile.name} reason=:mihomo process refused start');
        return false;
      }
      _mihomoUpstreamPort = 2081;
      Logger.instance.info('vpn-session',
          '$trace MIHOMO_UPSTREAM node=${profile.name} mixed=2081');
      return true;
    } catch (e) {
      lastError = 'MIHOMO_START_FAILED';
      Logger.instance.error('vpn-session',
          '$trace FAILED stage=MIHOMO_UPSTREAM exception=${e.runtimeType} msg=${Logger.redact(e.toString())}');
      return false;
    }
  }

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

  // ---------------------------------------------------------------------
  // v0.5.0 §user-fix ("میرم تلگرام، برمی‌گردم — انگار برنامه تازه باز شده"):
  // Android kills the app's process in the background while the NATIVE VPN
  // service keeps the tunnel up. The fresh Dart process starts with
  // selectedNode = null and the default switch flag, so the UI showed
  // "tap to connect" over a LIVE tunnel. The selection + switch choice are
  // now PERSISTED in the store (section `sessionState`) and restored during
  // bootstrap, before the native reconcile — the first paint shows the
  // truth.
  // ---------------------------------------------------------------------

  static const _sessionSection = 'sessionState';

  /// The user's LAST EXPLICIT Smart-Switch choice (card tap), kept across
  /// disconnects. Separated from the live [smartSwitch] flag on purpose: a
  /// disconnect clears the LIVE runtime state (selection + ladder) but must
  /// NOT forget whether the user wanted auto or manual — the next connect
  /// re-arms exactly what they left enabled.
  bool smartSwitchPreferred = true;

  /// v0.5.3 §user-fix ("دستی انتخاب کردم، دوباره اسمارت‌سوییچ شد"): set on
  /// [selectNode] (a real user tap) and CLEARED only by [enableSmartSwitch]
  /// or a [connect] that runs the ladder for real. While held, the cleared
  /// selection SURVIVES disconnect: the next connect dials the SAME node —
  /// a ping test never silently re-picks for a user who just chose one.
  bool _manualSelectionHold = false;

  /// Persists the picked node id + both switch flags (live + preferred).
  /// Fire-and-forget: the store coalesces writes (400 ms debounce).
  void persistState() {
    try {
      unawaited(deps.store.putSection(_sessionSection, {
        'selectedNodeId': selectedNode?.id,
        'smartSwitch': smartSwitch,
        'smartSwitchPreferred': smartSwitchPreferred,
        // v0.5.3 §user-fix: the manual pick survives a disconnect.
        'manualSelectionHold': _manualSelectionHold,
      }));
    } catch (_) {/* persistence must never break the connect path */}
  }

  /// Restores the persisted selection + switch choice. Called once from
  /// bootstrap, BEFORE the native reconcile, so the first paint already
  /// carries the user's node.
  void restorePersistedState() {
    try {
      final s = deps.store.section(_sessionSection);
      smartSwitch = (s['smartSwitch'] as bool?) ?? smartSwitch;
      smartSwitchPreferred =
          (s['smartSwitchPreferred'] as bool?) ?? smartSwitch;
      _manualSelectionHold =
          (s['manualSelectionHold'] as bool?) ?? _manualSelectionHold;
      final id = s['selectedNodeId'] as String?;
      if (id != null && selectedNode == null) {
        selectedNode = deps.profiles.byId(id);
      }
    } catch (_) {
      // A corrupt section is not worth a broken boot — defaults apply.
    }
  }

  /// v0.5.0 §user — CLEAN disconnect state: after a real disconnect the
  /// runtime state must not leak stale runtime facts into the next session.
  /// * the Smart Switch ladder is already stopped;
  /// * the scheduler's active-node monitor stops polling the old node;
  /// * the WARP watchdog is cancelled (via the terminal-phase sync);
  /// * the SELECTION is cleared — the next connect either auto-picks or
  ///   re-uses the node the user taps then, never a half-remembered one;
  /// * the user's EXPLICIT switch preference survives (see
  ///   [smartSwitchPreferred]) and the live flag re-converges to it, so the
  ///   next connect re-arms exactly what they left enabled.
  void _clearDisconnectedState() {
    _smart.stop();
    try {
      deps.scheduler.setActive(null);
    } catch (_) {}
    // v0.5.3 §user-fix: a MANUAL pick is sticky — it survives the clear so
    // the next connect dials the SAME node instead of re-running the
    // ladder over the user's head. Auto mode keeps the old behavior.
    if (!_manualSelectionHold) {
      selectedNode = null;
    }
    // v0.5.3 §user-fix ("دستی انتخاب کردم، دوباره اسمارت‌سوییچ شد"): while a
    // manual pick is HELD the live switch stays OFF across disconnects —
    // converging to the preference here re-armed the ladder and the next
    // connect silently re-picked over the user's head. The preference still
    // rules when there is no hold (pure auto users keep their auto).
    smartSwitch = _manualSelectionHold ? false : smartSwitchPreferred;
    _bootedHost = null;
    lastLatencyMs = null;
    _selectionEvents.add(null);
    persistState();
    Logger.instance.info('vpn-session',
        '[ATX-DART] SESSION_CLEARED '
        '${_manualSelectionHold ? 'manual selection KEPT (${selectedNode?.name ?? '∅'})' : 'selection dropped'}'
        ', switch re-armed per preference (${smartSwitchPreferred ? 'auto' : 'manual'})');
  }

  /// v0.5.0 §user-fix: after the native reconcile re-adopted a still-running
  /// tunnel from a dead process, a fresh Dart side has NO runtime services
  /// armed: no WARP watchdog, no Smart Switch ladder, no active-node
  /// scheduler entry. This re-arms all three (idempotent) — the tunnel the
  /// user came back to behaves exactly like one they just connected.
  void resumeRuntimeServices() {
    if (!controller.isConnected) return;
    final node = selectedNode;
    if (node != null) {
      try {
        deps.scheduler.setActive(node.id);
      } catch (_) {}
    }
    _armWarpWatchdog();
    if (smartSwitch) {
      // v0.5.0 §boot-perf ("اپ دوباره دير بوت ميشه"): arming the ladder
      // used to fire its FIRST sweep synchronously inside the resume — the
      // probe engine boot (a second libbox + possibly a 6-socket :xray
      // child) raced the shell's first paints and the platform channels on
      // a cold process. The periodic cadence still re-tests; the first
      // sweep simply waits out the boot traffic. When the switch is OFF,
      // nothing ladders — no probe boot at all.
      Future<void>.delayed(const Duration(seconds: 12), () {
        if (smartSwitch && controller.isConnected) {
          _armSmart(currentId: selectedNode?.id);
        }
      });
    }
    _selectionEvents.add(null);
    Logger.instance.info('vpn-session',
        '[ATX-DART] RUNTIME_RESUMED services re-armed for the re-adopted tunnel');
  }

  /// Explicitly selects a node for the next connect — called by the UI the
  /// moment the user taps a node card, BEFORE any connect attempt, so the
  /// dashboard reflects the tapped node immediately.
  ///
  /// v0.5.9 §retarget: a tap DURING an in-flight connect now WORKS — the
  /// old behavior only stored the pick (`_connectTarget = p`) and the
  /// running flow kept booting the OLD node (the tap did nothing until the
  /// next manual connect). Now a mid-flight tap cancels the running flow
  /// at the controller gate and REDIALS from [_connectProfile] with the
  /// new node. `runningAttempt` guards the recursion (the redirect path
  /// IS the same attempt generation).
  void selectNode(ProxyProfile p) {
    // v0.5.9 §retarget: a tap on the node ALREADY being dialed must not
    // cancel+redial it — the running funnel is doing exactly that work.
    final dialingThis = _connectTarget?.id == p.id;
    // v0.5.9 §retarget: BOTH roles — `selectedNode` keeps the session's
    // current pick (UI + persistState + manual hold), `_connectTarget`
    // steers the dial of an in-flight connect to THIS node.
    selectedNode = p;
    _connectTarget = p;
    // An explicit tap STEERS away from auto — smart mode resumes only via
    // [enableSmartSwitch] (the Nodes-tab card).
    smartSwitch = false;
    // v0.5.3 §user-fix: HOLD the pick across disconnects — the next connect
    // dials THIS node (never a silent ladder re-pick). Cleared only when
    // the user turns the smart switch back on.
    _manualSelectionHold = true;
    _smart.stop();
    Logger.instance.info('vpn-session',
        '[ATX-DART UI] NODE_SELECTED ${p.name} proto=${p.protocol.name} '
        'transport=${p.transport.name} core=${p.effectiveCore.name} (manual hold)');
    _selectionEvents.add(null);
    persistState();
    // v0.5.9 §retarget — a tap DURING a connect no longer no-ops. The gate
    // is IN-FLIGHT ONLY (a stale attempt object from an ended flow must not
    // auto-connect): a tap while idle stays a plain selection, while every
    // tap during a connect WINS — the freshest target is dialed (a newer
    // tap also replaces an in-flight redial).
    final attempt = _runningAttempt;
    final inFlight = attempt != null &&
        !attempt.redirected &&
        !attempt.cancelled &&
        _connectInFlight();
    if (inFlight && !dialingThis) {
      attempt.redirected = true;
      Logger.instance.info('vpn-session',
          '[ATX-DART UI] CONNECT_RETARGET → ${p.name} (mid-flight switch)');
      unawaited(_redialWith(p));
    }
  }

  /// v0.5.9 §retarget: abort the in-flight attempt at the CONTROLLER level
  /// ([AndroidVpnController.cancelConnect] — the superseded flow exits
  /// quietly at its next generation check) and REDIAL the new node through
  /// the same funnel as a normal connect.
  Future<void> _redialWith(ProxyProfile p) async {
    // OWN the slot with a FRESH attempt — the superseded flow (and its
    // in-flight tunnel probe) checks attempt IDENTITY, sees a newer owner
    // and aborts; a further tap retargets THIS redial the same way. The
    // swap lands BEFORE cancelConnect so the old probe stops burning
    // canaries the moment ownership moves.
    final redial = _ConnectAttempt();
    _runningAttempt = redial;
    try {
      // 1) Cancel the old controller run: its next poll/probe step returns
      //    false WITHOUT tearing the service down or fighting this redial.
      controller.cancelConnect();
      _smart.stop();
      try {
        await ProbeEngine.instance.stop();
      } catch (_) {}
      // 2) Wait for the old run to leave the gate (bounded — the identity
      //    check above aborts its probe at the current canary, so this is
      //    at most one in-flight fetch, not the full retry ladder), then
      //    land the phase on a benign state so the fresh funnel passes
      //    [wedgeArmed].
      for (var i = 0;
          i < 40 && controller.connectRunActive;
          i++) {
        if (redial.cancelled) return;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      // v0.6.2 §stop-fix: a stop can land while this redial waits or resolves
      // — its verdict belongs to nobody then.
      if (redial.cancelled) return;
      controller.resetToIdle(reason: 'connect retargeted to ${p.name}');
      // Cosmetic only (v0.5.8 §connect-fix): keep the "Connecting…" pill up
      // across the handover — the user never asked to disconnect.
      controller.markStarting(detail: 'retarget redial → ${p.name}');
      final trace =
          '[ATX-DART ${DateTime.now().millisecondsSinceEpoch % 10000}]';
      Logger.instance.info('vpn-session',
          '$trace RETARGET_REDIAL node=${p.name} proto=${p.protocol.name}');
      await _connectProfile(p, trace, attempt: redial);
    } finally {
      // Only clear when this attempt is still the one running — a newer
      // redirect may already own the slot.
      if (identical(_runningAttempt, redial)) _runningAttempt = null;
    }
  }

  /// v0.4.7 §user: re-arms the Smart Switch (Nodes-tab card / Settings).
  /// Immediately recommends the currently-best known node and starts the
  /// periodic sweep; if the tunnel is UP on a different node, the change
  /// stream migrates it.
  void enableSmartSwitch() {
    smartSwitch = true;
    smartSwitchPreferred = true;
    // v0.5.3 §user-fix: turning the switch ON is an explicit hand-back to
    // auto — the sticky manual pick releases here (and only here).
    _manualSelectionHold = false;
    _armSmart(currentId: selectedNode?.id);
    _selectionEvents.add(null);
    persistState();
  }

  /// v0.5.0 §user — ONE arming path for the ladder (connect auto-pick AND
  /// the Nodes-tab card): refresh cadence + tolerance, ENSURE the change
  /// subscription exists, then start. The old card path never subscribed —
  /// `_smartSub` was only created on the connect() auto-pick path, so
  /// enabling the switch from the card fired recommendations into the void
  /// and the tunnel never migrated (device report: "the auto switch does
  /// not switch"). Subscribing BEFORE start() also closes the race where a
  /// first-sweep recommendation arrived before the listener did.
  void _armSmart({String? currentId}) {
    final st = deps.appSettings;
    _smart
      ..interval = Duration(seconds: st.smartSwitchIntervalSeconds)
      ..marginMs = st.smartSwitchMarginMs
      ..marginPercent = st.smartSwitchMarginPercent
      ..activeRecheckInterval =
          Duration(seconds: st.smartSwitchActiveRecheckSeconds)
      ..othersRescanInterval =
          Duration(minutes: st.smartSwitchOthersRescanMinutes);
    _smartSub ??= _smart.changes.listen(_migrateForSmartSwitch);
    _smart.start(SmartSwitch.candidatesOf(deps.profiles.all),
        currentId: currentId);
  }

  /// v0.5.0 §user: live-applies cadence/tolerance edits to a RUNNING ladder
  /// WITHOUT turning it on (Settings → Smart Switch interval/tolerance
  /// fields). A no-op while the switch is off — the next [enableSmartSwitch]
  /// or auto-pick connect picks the new values up through [_armSmart].
  void syncSmartTuning() {
    if (!smartSwitch) return;
    _armSmart(currentId: selectedNode?.id ?? _smart.best?.id);
  }

  /// v0.5.2 §user: LIVE-applies the three professional dials (percent
  /// margin / active recheck / others rescan) to a RUNNING ladder — same
  /// no-op-while-off contract as [syncSmartTuning].
  void syncSmartDials() => syncSmartTuning();

  /// v0.4.8 §user: turns the Smart Switch OFF — the user's tap on the
  /// card's OFF state is an explicit hand-back to manual selection. Before
  /// this the card's Switch only re-fired enableSmartSwitch(), so a node
  /// that was ON could never be turned OFF from the card (device report).
  void disableSmartSwitch() {
    smartSwitch = false;
    smartSwitchPreferred = false;
    _smart.stop();
    _selectionEvents.add(null);
    persistState();
    Logger.instance.info('smart-switch',
        '[ATX-DART] SMART_SWITCH disabled by user — manual selection');
  }

  /// v0.5.3: TEST HOOK — the disconnect-clear without the native stop.
  /// [visibleForTesting] keeps production callers on [disconnect].
  @visibleForTesting
  void clearDisconnectedStateForTest() => _clearDisconnectedState();

  /// Proxy for UI reads (Nodes-tab card highlight).
  bool get isSmartSwitchActive => smartSwitch;

  /// v0.5.2 §user-fix: the ladder's OWN measurement stream (sweeps + the
  /// initial pre-connect ladder + active rechecks) — the Nodes tab reads
  /// THIS to repaint its ping column. Before, the list only listened to
  /// scheduler.results, so the switcher's REAL delay results (which skip
  /// the scheduler entirely) never moved the UI and the first sweep read
  /// as "no pings" until a manual re-test.
  Stream<void> get smartMeasured => _smart.measured;

  /// v0.5.2 §user — LIVE pre-connect ladder progress (start → per landed
  /// node → finish; see [LadderProgress]). The dashboard hero reads THIS
  /// while connecting: "testing 5/11… 180 ms" instead of a bare
  /// "Connecting…". Background rescans/rechecks stay silent (announce-only
  /// runs report), and a run that died to the wait cap still closes itself.
  Stream<LadderProgress> get smartLadderProgress => _smart.progress;

  /// v0.5.2 §user-fix ("بار اول وصل نمیشه، بار دوم درسته") — THE PRE-CONNECT
  /// LADDER. When Smart Switch is ON and the user has no explicit pick, the
  /// connect measures the runnable pool with REAL delay tests and connects
  /// to the fastest healthy node.
  ///
  /// v0.5.5 §user ("کانکت دیر وصل میشه"): the ladder no longer BLOCKS the
  /// handshake. It hands over the moment a first healthy node exists
  /// (or after the 3.5 s cap) — the tunnel starts WHILE the rest of the
  /// pool is still measuring; the armed switch keeps optimizing after
  /// connect and migrates if a faster node lands later. Returns the node
  /// to dial (null → the caller falls back to the health-store pick).
  Future<ProxyProfile?> _preConnectLadder(String trace) async {
    final candidates = SmartSwitch.candidatesOf(deps.profiles.all);
    if (candidates.isEmpty) return null;
    Logger.instance.info('smart-switch',
        '$trace SMART_LADDER pre-connect sweep over ${candidates.length} node(s)');
    ProxyProfile? pick;
    await _smart.initialSweep(candidates, earlyPick: (p) {
      pick = p;
      Logger.instance.info('smart-switch',
          '$trace SMART_LADDER early-pick=${p.name} '
          'lat=${deps.healthStore.statsOf(p.id)?.lastLatencyMs ?? '?'}ms — handshake starts, sweep continues');
    });
    // A fresh local: flow analysis cannot promote [pick] (assigned inside
    // the earlyPick closure), so the log below needs a promoted copy.
    final ProxyProfile? winner = pick ?? _smart.best;
    if (winner != null) {
      Logger.instance.info('smart-switch',
          '$trace SMART_LADDER dial=${winner.name} lat=${deps.healthStore.statsOf(winner.id)?.lastLatencyMs ?? '?'}ms');
    }
    return winner;
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
    // v0.6.2 §tap-fix ("یه کانفیگ دیگه رو کانکت کرد" while connecting): a
    // connect request that lands on a LIVE attempt SUPERSEDES it instead of
    // racing it. The old flow is marked so every identity gate + its tunnel
    // probe abort quietly, and the controller run is bumped so it cannot
    // tear the native session down or repaint the phase. The freshest
    // request always owns the funnel (same discipline as the node-tap
    // retarget, but for the pill/second request).
    final live = _runningAttempt;
    if (live != null && !live.cancelled && _connectInFlight()) {
      live.redirected = true;
      controller.cancelConnect();
      Logger.instance.info('vpn-session',
          '$trace CONNECT_SUPERSEDES a live attempt (freshest request wins)');
    }
    // v0.5.5 §user: INSTANT visual response — the phase flips to starting
    // on the tap itself (spinner + "Connecting…" + globe wakes up), never
    // waiting for the ladder or the permission flow. The later stages
    // overwrite the phase as they run.
    // v0.5.8 §connect-fix: markStarting now sets ONLY a cosmetic phase —
    // the controller's own connect() gate no longer counts it as busy
    // (see AndroidVpnController.wedgeArmed); before that, this line wedged
    // EVERY connect: tap → starting → isBusy guard → silent `false`.
    controller.markStarting(detail: 'session.connect entered');
    // v0.5.9 §retarget: register THIS attempt and seed the dial target so
    // a mid-flight selectNode() can redirect it (or supersede it).
    final attempt = _ConnectAttempt();
    _runningAttempt = attempt;
    _connectTarget = node;
    // v0.5.0 §boot: secrets resolve POST-PAINT now. A connect fired before
    // the deferred pass finished would build a config from `@vault:` token
    // strings — gate here: normally a no-op (resolution finished during the
    // intro), worst case the connect waits out the remaining Keystore work
    // it would have paid inline before this change.
    try {
      await deps.deferredSecretResolution;
    } catch (_) {
      // Resolution failure must not wedge the connect; the config builder
      // reports the unusable node on its own.
    }

    // ── 1. EXPLICIT SELECTION FIRST: the tapped node IS the request. ──
    final explicit = node ?? _liveStoredSelection(trace);
    if (explicit != null) {
      // Remember the pick even when it cannot run: the dashboard must show
      // the node the user chose, not a node the picker preferred.
      selectedNode = explicit;
      persistState();
      var why = AndroidNodeSupport.androidExclusionReason(explicit);
      // v0.6.2 §boot-race-fix (the other shape of "کلا هیچ کانفیگی وصل
      // نمیشه"): the engine gates (Xray runtime / mihomo binary / AWG fork)
      // are armed by probes that run UNawaited behind the first frame. A tap
      // landing before they answer rejected an xhttp/mihomo node with
      // "runtime is not loaded" — and the FIRST tap after launch is exactly
      // when the user connects, so for a subscription full of xhttp/mihomo
      // nodes EVERY config looked unrunnable. A runtime-shaped rejection now
      // gets a short bounded grace + a re-check (the same discipline the
      // funnel already uses for the Xray handshake).
      if (why != null && _runtimeGatedReason(why)) {
        for (var i = 0; i < 10 && _runtimeGatedReason(why!); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          why = AndroidNodeSupport.androidExclusionReason(explicit);
        }
        if (why == null) {
          Logger.instance.info('vpn-session',
              '$trace ENGINE_GATES armed during the boot-probe grace — proceeding');
        }
      }
      if (why != null) {
        Logger.instance.error('vpn-session',
            '$trace FAILED stage=NODE_SELECTED node=${explicit.name} proto=${explicit.protocol.name} transport=${explicit.transport.name} core=${explicit.effectiveCore.name} reason=$why');
        // v0.5.8 §connect-fix: end the phase (was: `starting` forever).
        return _failNoProfile(trace, 'NODE_NOT_RUNNABLE_ON_ANDROID');
      }
      // Node identity WITHOUT endpoint/credentials: name + protocol/transport
      // family only (redaction discipline; server/host never logged).
      Logger.instance.info('vpn-session',
          '$trace NODE_SELECTED source=explicit node=${explicit.name} proto=${explicit.protocol.name} transport=${explicit.transport.name} core=${explicit.effectiveCore.name}');
      return _connectProfile(explicit, trace, attempt: attempt);
    }

    // ── 2. AUTO-SELECT among ANDROID-RUNNABLE nodes only. ──
    // v0.5.2 §user: with the switch ON, the ladder runs and the fastest
    // healthy node connects. With it OFF, the classic health-store pick
    // applies.
    // v0.5.5 §user: the ladder is BUDGETED — early handover on the first
    // healthy measurement (or 3.5 s), then the tunnel boots while the
    // sweep keeps measuring. The armed switch migrates the tunnel later
    // if a materially better node shows up.
    if (smartSwitch) {
      ProxyProfile? ladderPick = await _preConnectLadder(trace);
      if (ladderPick != null) {
        selectedNode = ladderPick;
        persistState();
        _selectionEvents.add(null); // the globe pin + hero move NOW
      }
    }
    // The tunnel boot veto goes up REGARDLESS of the ladder outcome — from
    // here until the tunnel verdict no probe-engine start may fight the
    // VPN engine for cache.db (v0.5.2 keeps the v0.5.0 veto discipline).
    // v0.5.9 §retarget: ref-counted hold — the try/finally below pairs this
    // acquire; _connectProfile takes (and releases) its own on top of it.
    ProbeEngine.instance.setTunnelBootHold(true);
    try {
      // v0.5.5 §user: the EXPLICIT ladder pick dials AS-IS — re-ranking
      // through _bestNode() here could undo the early handover (a landed
      // measurement may not be in the store yet when _bestNode scores it).
      final best = selectedNode ?? _bestNode();
      if (best == null) {
        Logger.instance.error('vpn-session',
            '$trace FAILED stage=NODE_SELECTED error=NO_RUNNABLE_NODE ${_exclusionSummary()}');
        // v0.5.8 §connect-fix: end the phase (was: `starting` forever).
        return await _failNoProfile(trace, 'NO_RUNNABLE_NODE');
      }
      selectedNode = best;
      persistState();
      Logger.instance.info('vpn-session',
          '$trace NODE_SELECTED source=auto node=${best.name} proto=${best.protocol.name} transport=${best.transport.name} core=${best.effectiveCore.name}');
      // v0.4.7 §user: smart mode is the DEFAULT — with no explicit pick the
      // ladder starts here and keeps re-testing; tunnel migrates on change.
      // v0.5.2 §order: the ladder must arm AFTER the tunnel boot completed
      // (it did inside connect → _connectProfile already holds the boot
      // veto; arming here is safe) — and best was pre-selected by the
      // pre-connect ladder's REAL measurements.
      if (smartSwitch) _armSmart(currentId: best.id);
      return await _connectProfile(best, trace, attempt: attempt);
    } finally {
      // v0.5.9 §retarget: the veto taken above is THIS flow's own — paired
      // release. (The hold is ref-counted since v0.5.9: a nested retarget
      // redial takes its own hold and must survive this flow's unwind.)
      ProbeEngine.instance.setTunnelBootHold(false);
    }
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
      persistState();
      _selectionEvents.add(null);
      return;
    }
    Logger.instance.info('smart-switch',
        '[ATX-DART] MIGRATE → ${next.name} (tunnel stays up during switch)');
    selectedNode = next;
    persistState();
    _selectionEvents.add(null);

    // 1) Fast path: Clash-API selector swap (sub-second, zero traffic
    //    interruption on the TUN interface itself).
    //    v0.5.0 §user-fix: deps.cores.front.api is ALWAYS null on Android
    //    (libbox lives in the service process) — the old read here made the
    //    fast path dead code and every switch a full disconnect/reconnect.
    //    The probe-and-cache client reaches the real :9097 listener.
    final api = await liveEngineApi();
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

  /// v0.5.8 §connect-fix: a connect that bails on a PRE-TUNNEL gate must
  /// end on a terminal phase. [markStarting] (v0.5.5) puts the UI on the
  /// connecting spinner the instant the user taps; any gate `return false`
  /// that leaves the phase on `starting` spins the dashboard forever with
  /// no verdict. Every no-profile/no-runtime failure funnels through here:
  /// lastError is kept, the boot hold is released and the controller lands
  /// on `stopped` (non-busy — a retry tap works immediately).
  Future<bool> _failNoProfile(String trace, String code) async {
    lastError = code;
    try {
      await ProbeEngine.instance.stop();
    } catch (_) {}
    // v0.5.9 §retarget: NO unconditional boot-hold release here — the hold
    // is ref-counted now and the acquiring flow's finally owns the paired
    // release. _failNoProfile runs on pre-hold paths (node selection) and
    // on nested (redial) flows; releasing here would drop ANOTHER flow's
    // hold mid-boot (two libbox instances over cache.db again).
    controller.resetToIdle(reason: 'connect failed pre-tunnel: $code');
    return false;
  }

  /// The single authoritative engine-start path — every connect (explicit
  /// or auto) funnels through here after node selection, so the single-core
  /// guarantee is enforced in exactly ONE place.
  ///
  /// v0.5.9 §retarget: [profile] is the ATTEMPT-START suggestion. A
  /// mid-flight [selectNode] tap updates [_connectTarget] and bumps
  /// [_connectTargetEpoch]; this flow then stops cleanly (the tap's own
  /// `_redialWith` runs the funnel again with the NEW node). The caller's
  /// boolean is honest for the superseded attempt: `false`.
  Future<bool> _connectProfile(ProxyProfile profile, String trace,
      {required _ConnectAttempt attempt}) async {
    // v0.4.9 §cache-fix (LIBBOX_START_FAILED: initialize cache-file: timeout
    // on device, 2026-09-25 19:57): the transient probe engine and the VPN
    // engine live in the SAME process (the service has no :process of its
    // own), so both libbox instances share ONE setup workingDir and fight
    // over cache.db — the tunnel start TIMED OUT on the lock. The probe
    // (and its :xray child) must be fully down before the tunnel boots; the
    // sweep can restart it afterwards.
    try {
      await ProbeEngine.instance.stop();
    } catch (_) {}
    // v0.5.0 §device-fix (log evidence 2026-09-27 10:22: the connect above
    // STILL died with cache-file: timeout): stopping the engine was not
    // enough — the Smart Switch sweep armed a moment later re-entered
    // ensureUp and BOOTED the probe engine WHILE the tunnel was starting
    // ("probe engine UP :9090 nodes=11" one second after the connect
    // FAILED). The connect now owns a start veto: no probe-engine boot is
    // allowed from here until the tunnel verdict (CONNECTED or dead).
    ProbeEngine.instance.setTunnelBootHold(true);
    try {
      // v0.5.9 §retarget: a NEWER attempt owns the slot (a tap redialed
      // mid-flight, or a second connect) — this flow must NOT boot anything
      // (two funnels would race the engine boot and the config files).
      // v0.6.2 §stop-fix: a CANCELLED attempt (user pressed Stop) is just as
      // dead — no engine, no probe, no verdict.
      if (!_ownsAttempt(attempt)) {
        return false;
      }
      // v0.5.9 §retarget: dial the LATEST target, not the stale caller
      // suggestion (a tap landing between connect() and this point wins).
      final target = _connectTarget ?? profile;
      if (target.id != profile.id) {
        Logger.instance.info('vpn-session',
            '$trace RETARGET dial=${target.name} (was ${profile.name})');
      }
      final ok = await _connectProfileInner(target, trace, attempt: attempt);
      // v0.5.9 §retarget: superseded → this result is not the session's
      // verdict (the redial in flight owns it now); report honestly.
      if (!_ownsAttempt(attempt)) {
        return false;
      }
      return ok;
    } finally {
      ProbeEngine.instance.setTunnelBootHold(false);
    }
  }

  Future<bool> _connectProfileInner(ProxyProfile profile, String trace,
      {required _ConnectAttempt attempt}) async {
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
    // v0.5.3 §mihomo: the engine preference reaches the Android resolution
    // too — `mihomo` steers mihomo-runnable nodes to the standalone engine
    // (child-process shape, gated on its boot-time binary probe).
    var resolvedCore = deps.detector
        .resolve(
          profile,
          preference: deps.appSettings.corePreference,
        )
        .core;
    // v0.6.2 §engine-fallback: an APP-LEVEL engine preference must never take
    // the whole app down (the other half of "کلا هیچ کانفیگی وصل نمیشه"):
    // with Engine=mihomo chosen in Settings, EVERY vless/vmess/trojan/ss
    // node resolves to mihomo — and if this build/ABI did not ship (or could
    // not exec) the mihomo runtime, the boot probe reports "off" and every
    // single config died on the single-core gate with the same code. An app
    // preference is a PREFERENCE, not an order (unlike [userPinnedCore],
    // which still fails honestly): when the preferred engine is not runnable
    // here, fall back to the capability-matrix decision — for an xhttp node
    // that is the :xray upstream, which DOES run the transport.
    if (profile.userPinnedCore == null &&
        deps.appSettings.corePreference != CorePreference.auto &&
        !AndroidNodeSupport.coreAllowedOnAndroid(resolvedCore)) {
      final fallback =
          deps.detector.resolve(profile, preference: CorePreference.auto).core;
      if (AndroidNodeSupport.coreAllowedOnAndroid(fallback)) {
        Logger.instance.warn('vpn-session',
            '$trace ENGINE_PREFERENCE_UNAVAILABLE ${resolvedCore.name} is not runnable on this device → falling back to ${fallback.name} (the preference is not an order)');
        resolvedCore = fallback;
      }
    }
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
      Logger.instance.error('vpn-session',
          '$trace FAILED stage=CORE_SELECTED node=${profile.name} core=${profile.effectiveCore.name} reason=non-sing-box core has no in-app runtime (single-core guarantee)');
      // v0.5.8 §connect-fix: end the phase (was: `starting` forever).
      return _failNoProfile(trace, 'CORE_NOT_RUNNABLE_ON_ANDROID');
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

    // v0.6.2 §stop-fix: the bootstrap resolve awaits real DNS — a stop or a
    // node tap can land inside it. One more ownership gate here keeps a dead
    // attempt from spawning an :xray/:mihomo child (or starting mihomo for a
    // node nobody asked for anymore).
    if (!_ownsAttempt(attempt)) return false;

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
    // v0.5.3 §mihomo: a mihomo-owned node starts the :mihomo child FIRST
    // (before the front config is generated — the config stubs its mixed
    // port). No Xray runtime needed; the mihomo gate is its own probe.
    if (profile.effectiveCore == CoreKind.mihomo) {
      final ok = await _startMihomoUpstream(profile, trace);
      // v0.5.8 §connect-fix: the phase must land on a terminal either way.
      if (!ok) return _failNoProfile(trace, lastError ?? 'UPSTREAM_START_FAILED');
    } else if (CoreManager.needsXrayUpstream(profile)) {
      // v0.4.9 §user-fix ("first tap after open fails"): the runtime probe
      // rides an unawaited warmup — racing it here answered a false
      // XRAY_RUNTIME_UNAVAILABLE for a node that CAN run. Wait briefly for
      // the handshake instead of failing on a race.
      if (!XrayCoreState.instance.runtimeLoaded) {
        for (var i = 0; i < 10 && !XrayCoreState.instance.runtimeLoaded; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
      if (!XrayCoreState.instance.runtimeLoaded) {
        Logger.instance.error('vpn-session',
            '$trace FAILED stage=CORE_SELECTED node=${profile.name} transport=${profile.transport.name} reason=xray runtime not loaded (sing-box on, Xray off)');
        // v0.5.8 §connect-fix: end the phase (was: `starting` forever).
        return _failNoProfile(trace, 'XRAY_RUNTIME_UNAVAILABLE');
      }
      final ok = await _startXrayUpstream(profile, trace);
      // v0.5.8 §connect-fix: the upstream start owns its own error code —
      // but the phase must still land on a terminal either way.
      if (!ok) return _failNoProfile(trace, lastError ?? 'UPSTREAM_START_FAILED');
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
        // v0.5.8 §connect-fix: end the phase (was: `starting` forever).
        return await _failNoProfile(trace, 'CONFIG_GENERATION_FAILED');
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
      // v0.6.2 §stop-fix: the LAST gate before the native handoff. Config
      // generation, DNS pinning and the upstream start all await — a stop or
      // a retarget landing in any of them must not resurrect a session the
      // user already killed.
      if (!_ownsAttempt(attempt)) {
        Logger.instance.info('vpn-session',
            '$trace ABANDONED before native handoff (stop/retarget won)');
        return false;
      }
      Logger.instance.info('vpn-session', '$trace VPN_PERMISSION requested');
      // v0.5.2 §first-connect-fix ("بار اول وصل نمیشه، بار دوم درسته"):
      // the probe fires THE INSTANT the native side reports VALIDATING —
      // on the very first connect the engine's outbound DNS + TLS are
      // still warming, so a single 8 s probe window regularly expired and
      // the whole attempt was torn down (second attempt: warm caches →
      // instant pass). The probe now RETRIES inside the same startup
      // budget (3 tries, 1.2 s apart) — one honest session, not a
      // teardown-for-warmup.
      final ok = await controller.connect(
        probeTunnel: () async {
          // v0.5.9 §retarget: a superseded flow must not keep burning canary
          // rounds — the retarget's redial waits for THIS run to exit before
          // it may dial. Identity (not just the redirected flag): a redial
          // registers a FRESH attempt, so a stale flow sees a newer owner.
          bool superseded() => !_ownsAttempt(attempt);

          for (var i = 0; i < 3; i++) {
            if (superseded()) return false;
            if (i > 0) {
              await Future<void>.delayed(const Duration(milliseconds: 1200));
              Logger.instance.info('vpn-session',
                  '$trace HEALTH_RETRY attempt=${i + 1}/3 (engine warm-up grace)');
            }
            final port = deps.cores.front.mixedPort;
            // v0.5.6 §connect-fix: the canary was hardcoded to
            // gstatic generate_204 on ALL THREE retries. That host is
            // routinely blocked/intercepted on the networks this app
            // targets, so a healthy tunnel verified as DEAD — every
            // config failed identically ("spins, never connects"). Try
            // the user's configured delay-test URL first, then independent
            // canaries, and only fail when none of them answers.
            final canaries = <String>[
              deps.appSettings.effectiveDelayTestUrl,
              ...ConnectionController.probeFallbacks,
            ];
            // v0.6.0 §first-connect-fix: the canaries used to run SERIAL
            // (4 × 8 s = 32 s per round) while the whole probe was capped
            // by an outer 15 s timeout — a cold engine that had not yet
            // dialled its upstream could not even finish ROUND ONE, the
            // attempt was torn down, and the SECOND tap (warm caches, DNS
            // pin, already-running :mihomo/:xray child) connected. That
            // was the user's "بار اول وصل نمیشه، بار دوم درسته". Two fixes:
            // the canaries race IN PARALLEL (worst-case round = the
            // slowest canary, 8 s — not the sum), and the outer probe
            // budget is now larger than the honest worst case of all
            // three rounds (see controller probeTimeout).
            final batch = await Future.wait([
              for (final url in canaries)
                deps.tester
                    .testHttpViaSocksProxy('127.0.0.1', port, url,
                        timeout: const Duration(seconds: 8))
                    .then((r) => MapEntry(url, r)),
            ]);
            if (superseded()) return false;
            final hit = batch.where((e) => e.value.ok).toList();
            if (hit.isNotEmpty) {
              final r = hit.first.value;
              lastLatencyMs = r.latencyMs;
              Logger.instance.info('vpn-session',
                  '$trace HEALTH_CHECK via mixed:$port OK ${r.latencyMs ?? '?'}ms canary=${hit.first.key}');
              return true;
            }
            Logger.instance.warn('vpn-session',
                '$trace HEALTH_CHECK try=${i + 1}/3 all ${batch.length} canaries failed '
                'kinds=${batch.map((e) => e.value.errorKind ?? '?').join(',')}');
          }
          return false;
        },
        startupTimeout: Duration(seconds: deps.appSettings.connectionTimeoutSeconds),
        // v0.6.0 §first-connect-fix: the probe may legitimately spend its
        // own budget — 3 warm-up rounds × (8 s canary batch + 1.2 s gap).
        // Capping it with the startup clock killed round one on cold
        // engines and produced the first-connect failure the user kept
        // reporting.
        probeTimeout: const Duration(seconds: 32),
        proxyMode: deps.appSettings.proxyMode,
        // v0.6.2 §stop-fix: the SAME ownership guard the funnel uses — a stop
        // (or retarget) during the permission dialog, the engine handoff or
        // the multi-second probe makes this run exit quietly instead of
        // publishing a verdict over the stop the user just made.
        stillOwned: () => _ownsAttempt(attempt),
      );
      Logger.instance.info(
          'vpn-session', ok ? '$trace CONNECTED' : '$trace FAILED stage=controller.connect (see prior stages)');
      // v0.6.2 §stop-fix: an ABANDONED attempt (a stop, or a node tap that
      // took the dial over) ends HERE. Everything below this line is
      // session-owning work — arming the tunnel watchdog, recording fragment
      // rungs, and especially climbing the fragment ladder (which RESTARTS
      // upstreams and re-probes through the tunnel). Running it for a dead
      // attempt would fight the successor's engine and repaint a verdict
      // over the user's stop.
      if (!_ownsAttempt(attempt)) {
        Logger.instance.info('vpn-session',
            '$trace ABANDONED after controller.connect (no verdict written)');
        return false;
      }
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
      // v0.5.8 §connect-fix: an exception could also leave the phase on
      // `starting` — land it on a terminal so the spinner always ends.
      return _failNoProfile(trace, lastError ?? 'CONNECT_EXCEPTION');
    }
  }

  /// §3 — clean disconnect; permission state is preserved by Android, so a
  /// subsequent connect skips the consent dialog (§37.12).
  /// v0.5.0 §user: after the tunnel is down the runtime state is CLEARED
  /// (selection dropped, monitor/watchdog stopped, switch re-armed per the
  /// user's preference) — no half-remembered state survives into the next
  /// session.
  Future<void> disconnect() async {
    // v0.6.2 §stop-fix: kill the in-flight attempt FIRST. The flag makes the
    // funnel's identity checks and the tunnel probe abort at their next
    // step, and controller.stop() supersedes the controller run — together
    // the stop is immediate and no late verdict can repaint the UI.
    final live = _runningAttempt;
    if (live != null) {
      live.cancelled = true;
      Logger.instance.info('vpn-session',
          '[ATX-DART UI] CONNECT_CANCELLED (stop during connecting)');
    }
    _smart.stop();
    await controller.stop();
    // v0.6.3 §notify-fix: the child cores die with the session — ALWAYS, not
    // only when this process still remembers its upstream port. Those port
    // fields are in-memory: after an app restart (or a session adopted from
    // the native side) a disconnect left the :xray/:mihomo process — and its
    // "Atlanhix core" foreground notification — running with no owner. The
    // bridge's `running` flag is refreshed from the native state file, so
    // this only ever stops something that is genuinely alive.
    if (_xrayUpstreamPort > 0 || XrayBridge.instance.running) {
      _xrayUpstreamPort = 0;
      await XrayBridge.instance.stop();
    }
    // v0.5.3 §mihomo: the child dies with the session.
    if (_mihomoUpstreamPort > 0 || MihomoBridge.instance.running) {
      _mihomoUpstreamPort = 0;
      await MihomoBridge.instance.stop();
    }
    _clearDisconnectedState();
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
      // v0.5.3 §mihomo — STANDALONE ENGINE BRANCH: a mihomo-owned node NEVER
      // reaches the sing-box front config. The mihomo child process owns the
      // dial-out end-to-end; the front tunnel (libbox TUN) routes ALL traffic
      // into mihomo's mixed inbound via the SAME socksUpstream mechanism the
      // :xray child uses — one dialer, no double wrap. The generated config
      // below is what `mihomo -d -f` consumes when the runtime starts.
      if (profile.effectiveCore == CoreKind.mihomo) {
        final cfg = MihomoConfigGenerator.ports(mixedPort: 2081, apiPort: 9099)
            .build(
          profiles: [profile],
          selectedId: profile.id,
          routing: routing,
          dns: dns,
        );
        Logger.instance.info('vpn-session',
            '$trace MIHOMO_CONFIG generated node=${profile.name} transport=${profile.transport.name}');
        _logMihomoSummary(cfg, trace);
        return jsonEncode(cfg);
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
      // v0.5.3 §mihomo: the front dial-out goes to the mihomo child's mixed
      // inbound (2081) for mihomo-owned nodes — same stub mechanism, so the
      // tunnel stays sing-box TUN → socks → :mihomo → node.
      var mihomoStubPort = 0;
      if (_mihomoUpstreamPort > 0 &&
          profile.effectiveCore == CoreKind.mihomo) {
        mihomoStubPort = _mihomoUpstreamPort;
        upstreams[profile.id] = (host: '127.0.0.1', port: mihomoStubPort);
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
          // v0.4.9 §fix: the previous firstWhere(orElse: () => null) cast the
          // closure's return to Map<String, dynamic>? — Dart infers the
          // orElse body as `Null` against the LIST's element type (dynamic),
          // and the runtime threw "'() => Null' is not a subtype of
          // '() => Map<String, dynamic>?'" the moment the selector was
          // missing (device log 2026-09-20, WARP rescue twin). A typed search
          // over the cast list removes the mismatch entirely.
          final outs = cfg['outbounds'] as List<Map<String, dynamic>>;
          Map<String, dynamic>? selector;
          for (final o in outs) {
            if (o['tag'] == 'proxy') {
              selector = o;
              break;
            }
          }
          if (selector != null) {
            (selector['outbounds'] as List).add(rescueTag);
          }
        }
      }
      cfg['log'] = {
        'level': 'info',
        'timestamp': true,
        'output': '/sdcard/Android/data/com.atlanhix.app/files/singbox.log',
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

  /// Redacted structural summary of a generated MIHOMO config (proxy
  /// names + group shapes only — never endpoints or credentials).
  void _logMihomoSummary(Map<String, dynamic> cfg, String trace) {
    try {
      final proxies = ((cfg['proxies'] as List?) ?? const [])
          .map((e) => (e as Map)['name'])
          .join(',');
      final groups = ((cfg['proxy-groups'] as List?) ?? const [])
          .map((e) => (e as Map)['name'])
          .join(',');
      final rules = (cfg['rules'] as List?)?.length ?? 0;
      Logger.instance.info('vpn-session',
          '$trace MIHOMO_SUMMARY proxies=[$proxies] groups=[$groups] rules=$rules');
    } catch (_) {
      // best-effort; never blocks the connect path
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
    // v0.5.6 §connect-fix: this is the WARP-watchdog's health probe — it
    // also had the single hardcoded gstatic canary, so on a filtered network
    // it judged a perfectly healthy tunnel dead. Same fallback as connect().
    ProbeResult? last;
    for (final url in <String>[
      deps.appSettings.effectiveDelayTestUrl,
      ...ConnectionController.probeFallbacks,
    ]) {
      final r = await deps.tester.testHttpViaSocksProxy(
        '127.0.0.1',
        port,
        url,
        timeout: const Duration(seconds: 8),
      );
      if (r.ok) {
        lastLatencyMs = r.latencyMs;
        return true;
      }
      last ??= r;
      Logger.instance.warn('vpn-session',
          '$trace HEALTH canary=$url failed kind=${r.errorKind}');
    }
    // Every canary failed — report the aggregate verdict.
    Logger.instance.error('vpn-session',
        '$trace FAILED stage=HEALTH_CHECK via mixed:$port '
        'kind=${last?.errorKind} '
        'detail=${last?.detail != null ? Logger.redact(last!.detail!) : '-'}');
    return false;
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

  /// Asks the user. UI layer assigns: `(context) → Future<bool>`.
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
    final url = st.effectiveWarpProbeUrl;
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
    final api = await liveEngineApi();
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
    final api = await liveEngineApi();
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
    final url = deps.appSettings.effectiveWarpProbeUrl;
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
    _usageTimer?.cancel();
    _smartSub?.cancel();
    _smart.dispose();
    _sub?.cancel();
    _selectionEvents.close();
    controller.dispose();
  }
}
