import 'dart:async';
import 'dart:io';

import '../../domain/entities/proxy_profile.dart';
import '../../domain/errors/app_error.dart';
import '../../routing/routing_models.dart';
import '../fragmentation/fragment_profiles.dart';
import '../fragmentation/fragment_ladder_cache.dart';
import '../../settings/app_settings.dart';
import '../configgen/mihomo_config_generator.dart';
import '../logger.dart';
import 'binary_manager.dart';
import 'core_process.dart';
import 'core_runtime.dart';
import 'external_runtimes.dart';
import 'mihomo_runtime.dart';
import 'singbox_runtime.dart';
import 'xray_runtime.dart';

/// An engine process exited — tagged with the owning engine so crash
/// recovery can rebuild the correct topology (v0.2.1 W4).
class EngineExitEvent {
  const EngineExitEvent(this.engine, this.event);
  final CoreKind engine;
  final CoreExitEvent event;
}

/// Orchestrates every engine runtime (Phase 1).
///
/// Architecture: **sing-box is always the front engine** — it owns the mixed
/// inbound (127.0.0.1:2080), optional TUN and the selector. sing-box-runnable
/// profiles live as real outbounds; Xray / MasterDNSVPN profiles appear as
/// SOCKS stubs pointing at their local daemon ports. Switching:
///  * sing-box→sing-box: Clash API selector swap (no restart, sub-second)
///  * xray→xray: Xray process restart, then selector swap
///  * cross-family: start/stop the needed upstream, then selector swap
///  * AWG: standalone daemon (no front) — documented limitation
class CoreManager {
  /// v0.4 BUGFIX (Android device run): the four runtimes are constructed
  /// eagerly. They were `late final` + built only in prepare(), so any
  /// read of frontStatus/front before prepare() (the UI reads it at
  /// startup) threw LateInitializationError and killed the widget tree.
  /// Construction is I/O-free; prepare() still performs all disk work.
  CoreManager({
    required this.binaryManager,
    required this.workDir,
    this.enableTun = false,
  }) {
    singbox = SingBoxRuntime(
      binaryManager: binaryManager,
      workDir: Directory('${workDir.path}${Platform.pathSeparator}singbox'),
      enableTun: enableTun,
    );
    xray = XrayRuntime(
      binaryManager: binaryManager,
      workDir: Directory('${workDir.path}${Platform.pathSeparator}xray'),
    );
    amneziaWg = AmneziaWgRuntime(
      binaryManager: binaryManager,
      workDir: Directory('${workDir.path}${Platform.pathSeparator}awg'),
    );
    masterDnsVpn = MasterDnsVpnRuntime(
      binaryManager: binaryManager,
      workDir: Directory('${workDir.path}${Platform.pathSeparator}mdvpn'),
    );
    // v0.6.4 §stormdns: the DNS-tunnel sibling — own work dir, own SOCKS
    // port (18001 default, re-allocated in prepare()) so it can coexist
    // with a MasterDnsVPN daemon on 18000.
    stormDns = StormDnsRuntime(
      binaryManager: binaryManager,
      workDir: Directory('${workDir.path}${Platform.pathSeparator}stormdns'),
      socksPort: 18001,
    );
    // v0.5.3: the third standalone engine (its own work dir, own API port —
    // 9097 is the front's; mihomo takes 9099 to never collide).
    mihomo = MihomoRuntime(
      binaryManager: binaryManager,
      workDir: Directory('${workDir.path}${Platform.pathSeparator}mihomo'),
      mixedPort: mihomoMixedPort,
      apiPort: mihomoApiPort,
    );
  }

  /// v0.5.3: mihomo's own ports (the front sing-box owns 2080/9097).
  static const int mihomoMixedPort = 2081;
  static const int mihomoApiPort = 9099;

  final BinaryManager binaryManager;
  final Directory workDir;
  final bool enableTun;

  late final SingBoxRuntime singbox;
  late final XrayRuntime xray;
  late final AmneziaWgRuntime amneziaWg;
  late final MasterDnsVpnRuntime masterDnsVpn;

  /// v0.6.4 §stormdns: standalone StormDNS client daemon (DNS tunnel →
  /// local SOCKS5, chained as a sing-box upstream stub).
  late final StormDnsRuntime stormDns;

  /// v0.5.3: standalone mihomo (Clash.Meta) — full xhttp/XMUX ownership.
  late final MihomoRuntime mihomo;

  bool _prepared = false;
  ProxyProfile? _active;
  int _restartCount = 0;
  static const _maxRestarts = 1; // Phase 26: never loop

  ProxyProfile? get activeProfile => _active;
  RuntimeStatus get frontStatus => singbox.status;
  SingBoxRuntime get front => singbox;

  /// v0.4.6: redacted stderr tail of an engine — surfaced into ProbeError
  /// likelyCauses so a failed probe says WHY (resolve timeout, TLS reset,
  /// dial refused…) instead of a bare "node did not respond". Redaction
  /// follows the same discipline as Logger: callers must redact before
  /// persisting/displaying; here we only bound the length.
  String engineStderrTail(CoreKind engine, {int maxLines = 6}) {
    final lines = switch (engine) {
      CoreKind.xray => xray.debugStderrTail(),
      CoreKind.singbox => singbox.debugStderrTail(),
      // v0.6.4 §mihomo: a failed mihomo session must surface ITS stderr
      // (dial refused, resolve timeout, bad config) — before, this fell
      // through to an empty tail and the ProbeError said nothing useful.
      CoreKind.mihomo => mihomo.debugStderrTail(),
      // v0.6.4 §stormdns: the external DNS-tunnel daemons surface their
      // stderr too (resolver scan failed / config rejected / key mismatch).
      CoreKind.masterDnsVpn => masterDnsVpn.debugStderrTail(),
      CoreKind.stormDns => stormDns.debugStderrTail(),
      _ => const <String>[],
    };
    if (lines.isEmpty) return '';
    final tail = lines
        .take(maxLines)
        .map((l) => Logger.redact(l))
        .join(' | ');
    return tail.length > 400 ? tail.substring(tail.length - 400) : tail;
  }

  /// Work directory of the Xray runtime (for access-log paths in tests).
  Directory get xrayWorkDir => Directory(
      '${workDir.path}${Platform.pathSeparator}xray');

  /// W4: every engine's exit stream, tagged with the owning engine —
  /// the controller routes crash recovery per engine.
  final _anyExitCtrl = StreamController<EngineExitEvent>.broadcast();
  final _exitSubs = <StreamSubscription<void>>[];
  bool _exitWired = false;

  Stream<EngineExitEvent> get onAnyExit {
    if (!_exitWired) {
      _exitWired = true;
      _exitSubs.addAll([
        singbox.onExit.listen((e) => _anyExitCtrl.add(EngineExitEvent(CoreKind.singbox, e))),
        xray.onExit.listen((e) => _anyExitCtrl.add(EngineExitEvent(CoreKind.xray, e))),
        masterDnsVpn.onExit
            .listen((e) => _anyExitCtrl.add(EngineExitEvent(CoreKind.masterDnsVpn, e))),
        stormDns.onExit
            .listen((e) => _anyExitCtrl.add(EngineExitEvent(CoreKind.stormDns, e))),
        amneziaWg.onExit
            .listen((e) => _anyExitCtrl.add(EngineExitEvent(CoreKind.amneziaWg, e))),
        // v0.6.4 §mihomo: a crashed standalone mihomo session never reached
        // crash recovery (the default engine's exit was simply unheard).
        mihomo.onExit
            .listen((e) => _anyExitCtrl.add(EngineExitEvent(CoreKind.mihomo, e))),
      ]);
    }
    return _anyExitCtrl.stream;
  }

  bool _isXrayOwned(ProxyProfile p) => needsXrayUpstream(p);

  /// v0.4.6 WIRING: Settings → TLS-Fragment pill (opt-in) now drives the
  /// Xray upstream too. When enabled, the next Xray start carries the
  /// Xray-NATIVE fragmentation form — a `freedom` fragment outbound chained
  /// via `sockopt.dialerProxy` on the proxy outbound (ARCHITECTURE.md §6:
  /// FragmentationEngine). Eligibility is enforced per profile (Xray +
  /// TLS-family transports only); sing-box TCP-TLS outbounds receive the
  /// separate sing-box `tls.fragment` option via SingBoxRuntime.tlsFragment.
  /// Default OFF — nothing changes until the user opts in.
  bool tlsFragmentEnabled = false;

  /// v0.4.6 §user: WHICH fragment profile the pill uses. Defaults to
  /// conservative (the safe first attempt); the Settings screen lets the
  /// user pick Default/Aggressive — or AUTO, which climbs
  /// conservative → default → aggressive on failed probes (see
  /// [advanceAutoLadder]). Re-derived on every Xray start/recovery.
  FragmentPreset fragmentPreset = FragmentPreset.conservative;

  /// v0.4.7 §user: the MANUAL dial parameters (used when
  /// [fragmentPreset] == manual). Mirrors AppSettings' manual fields.
  String fragmentManualPackets = 'tlshello';
  String fragmentManualLength = '100-200';
  String fragmentManualInterval = '10-20';

  /// v0.4.6 §user: per-node winners of the AUTO ladder (optional — set by
  /// the composition root). When present, an AUTO connect to a node that
  /// already climbed successfully STARTS at its winning rung.
  FragmentLadderCache? fragmentLadder;

  FragmentProfile? _fragmentFor(ProxyProfile profile) {
    if (!tlsFragmentEnabled) return null;
    if (!FragmentationEngine().isEligible(profile)) return null;
    if (fragmentPreset == FragmentPreset.auto) {
      final order = _autoOrder;
      return FragmentPresets.all[order[_autoStep.clamp(0, order.length - 1)]];
    }
    if (fragmentPreset == FragmentPreset.manual) {
      return FragmentPresets.manual(
        packets: fragmentManualPackets,
        length: fragmentManualLength,
        interval: fragmentManualInterval,
      );
    }
    return FragmentPresets.profileFor(fragmentPreset);
  }

  /// Begin a fresh AUTO ladder for [profile]. The STARTING rung is, in
  /// priority order:
  ///   1. the node's own persisted winning rung (ladder cache),
  ///   2. the subscription-level suggestion (the latest proven rung of any
  ///      sibling node — nodes from one subscription usually share the same
  ///      CDN/DPI shape),
  ///   3. conservative (the safe default).
  /// The climb order then lists every rung starting from that rung, WRAPPING
  /// to the skipped lower ones afterwards — so a suggested start never
  /// blocks a node that actually needs a different rung: all three are
  /// still tried before the connect gives up. Fixed presets are unaffected;
  /// call after [stop]/reset and before [startFor].
  void beginAutoLadder(ProxyProfile profile) {
    _autoStep = 0;
    _autoOrder = const [0, 1, 2];
    if (fragmentPreset != FragmentPreset.auto) return;
    final start = fragmentLadder?.winnerFor(profile.id) ??
        fragmentLadder?.suggestionFor(profile.subscriptionId) ??
        FragmentPresets.conservative;
    final startIdx =
        FragmentPresets.all.indexWhere((p) => p.id == start.id);
    if (startIdx <= 0) return; // conservative: plain 0→1→2 order
    // Climb order: start, start+1, … 2, then wrap 0 … start-1 — the
    // suggested start never blocks a node that needs another rung: ALL
    // three are still tried before the connect gives up.
    _autoOrder = [
      for (var i = startIdx; i < FragmentPresets.all.length; i++) i,
      for (var i = 0; i < startIdx; i++) i,
    ];
  }

  /// Climb order of the current AUTO ladder — indices into
  /// FragmentPresets.all. Plain 0→1→2 unless a per-node winner or a
  /// subscription suggestion shifted the starting rung.
  List<int> _autoOrder = const [0, 1, 2];

  /// Position within [_autoOrder] (0-based). Exhaustion = last position.
  int _autoStep = 0;

  /// Read-only view of the active climb order (tests/diagnostics).
  List<int> get autoLadderOrder => List.unmodifiable(_autoOrder);

  Future<void> prepare() async {
    if (_prepared) return;
    await singbox.prepare();
    await xray.prepare();
    await amneziaWg.prepare();
    await masterDnsVpn.prepare();
    await stormDns.prepare();
    // v0.5.3: mihomo probes its binary too (flip MihomoCoreState when
    // found); a missing binary keeps the engine honestly disabled.
    await mihomo.prepare();
    // v0.3.1 §21: MDVPN SOCKS port is dynamically allocated per manager
    // instance so parallel test files / concurrent sessions never contend.
    masterDnsVpn.socksPort = await PortAllocator.freePort(prefer: 18000);
    // v0.6.4 §stormdns: same dynamic allocation — prefer 18001 (its
    // default) so it never contends with the mdvpn daemon either.
    stormDns.socksPort = await PortAllocator.freePort(prefer: 18001);
    _prepared = true;
  }

  /// The load sing-box must carry: every profile runnable by sing-box,
  /// WireGuard profiles as endpoints, and SOCKS stubs for upstream daemons.
  List<ProxyProfile> _singboxLoad(List<ProxyProfile> all) => all
      .where((p) => p.enabled)
      .where((p) => switch (p.effectiveCore) {
            CoreKind.singbox ||
            CoreKind.wireguardSingbox ||
            CoreKind.xray ||
            CoreKind.masterDnsVpn ||
            CoreKind.stormDns ||
            CoreKind.unknown =>
              true,
            // v0.5.3: mihomo-owned nodes NEVER ride the sing-box front —
            // they dial through the standalone engine (single truth per
            // node, no stub confusion between the two engines).
            CoreKind.mihomo => false,
            CoreKind.amneziaWg => false, // standalone daemon
          })
      .toList();

  /// Profiles that must be executed by the Xray upstream: either the
  /// detector/user pinned Xray, or an unknown-core profile with an
  /// Xray-only transport (xhttp) — defensive pairing with
  /// `OutboundBuilders.singBoxOutbound` (v0.2.1 W2/W6).
  static bool needsXrayUpstream(ProxyProfile p) =>
      p.effectiveCore == CoreKind.xray ||
      (p.effectiveCore == CoreKind.unknown &&
          (p.transport == Transport.xhttp ||
              // mKCP is engine-ambiguous on the enum (vmess maps it to
              // Transport.quic); the raw param is the truthful signal.
              p.rawParams['type'] == 'mkcp' ||
              p.rawParams['type'] == 'kcp'));

  Map<String, ({String host, int port})> _socksUpstreams(
      List<ProxyProfile> all) {
    final out = <String, ({String host, int port})>{};
    for (final p in all) {
      if (!p.enabled) continue;
      if (needsXrayUpstream(p)) {
        out[p.id] = (host: '127.0.0.1', port: xray.localPort);
      }
      switch (p.effectiveCore) {
        case CoreKind.masterDnsVpn:
          out[p.id] = (host: '127.0.0.1', port: masterDnsVpn.socksPort);
        case CoreKind.stormDns:
          out[p.id] = (host: '127.0.0.1', port: stormDns.socksPort);
        default:
          break;
      }
    }
    return out;
  }

  Future<void> _ensureUpstream(
    ProxyProfile profile, {
    required RoutingProfile routing,
  }) async {
    switch (profile.effectiveCore) {
      case CoreKind.xray:
      case CoreKind.unknown when profile.transport == Transport.xhttp:
        if (xray.currentProfile?.id != profile.id ||
            !await xray.inboundHealthy()) {
          // v0.4.6 WIRING: the fragment profile is re-derived per start so a
          // pill toggle takes effect on the next connect (restart-on-switch
          // policy). Ineligible profiles silently run unfragmented.
          xray.fragment = _fragmentFor(profile);
          final v =
              await xray.validateProfile(profile: profile, routing: routing);
          if (!v.ok) {
            throw ConfigValidationError(
              'Xray rejected this configuration.',
              problems: [v.message ?? 'validation failed'],
            );
          }
          if (xray.status == RuntimeStatus.running) await xray.stop();
          final r = await xray.startProfile(profile: profile, routing: routing);
          if (!r.ok) {
            throw CoreStartError('Xray failed to start: ${r.message}',
                exitCode: null);
          }
          // W5: never hand sing-box a SOCKS stub whose upstream is not
          // actually listening.
          if (!await xray.inboundHealthy()) {
            throw CoreStartError(
                'Xray SOCKS inbound is not listening after start.',
                exitCode: null);
          }
        }
      case CoreKind.masterDnsVpn:
        masterDnsVpn.profile = profile;
        if (masterDnsVpn.status != RuntimeStatus.running ||
            !await masterDnsVpn.probe()) {
          if (masterDnsVpn.status == RuntimeStatus.running) {
            await masterDnsVpn.stop();
          }
          final r = await masterDnsVpn.start();
          if (!r.ok) {
            throw CoreStartError('MasterDNSVPN failed to start: ${r.message}',
                exitCode: null);
          }
        }
      case CoreKind.stormDns:
        // v0.6.4 §stormdns: identical lifecycle to the mdvpn upstream —
        // the front sing-box carries this node as a SOCKS stub.
        stormDns.profile = profile;
        if (stormDns.status != RuntimeStatus.running ||
            !await stormDns.probe()) {
          if (stormDns.status == RuntimeStatus.running) {
            await stormDns.stop();
          }
          final r = await stormDns.start();
          if (!r.ok) {
            throw CoreStartError('StormDNS failed to start: ${r.message}',
                exitCode: null);
          }
        }
      default:
        break;
    }
  }

  /// Full start for one profile.
  /// Safe to call while an engine is already running: the previous topology
  /// is stopped first (otherwise the old process keeps the ports bound and
  /// the old selector active — found by the failover E2E test).
  ///
  /// [warpProfile] — WARP traffic chaining (v0.3.0 §8): when non-null (built
  /// via `WarpRegistrar.toProfile(account)`), the WARP WireGuard endpoint is
  /// materialized inside the front sing-box config and node outbounds dial
  /// through it per [chainWarpOutside]. The chain is real: sing-box itself
  /// dials the WireGuard handshake through the chain.
  ///
  /// v0.5.3 §mihomo: when the resolved engine is [CoreKind.mihomo] (user
  /// pin or the xhttp engine choice) and the binary is present, the node is
  /// served by the STANDALONE mihomo engine — full config ownership, no
  /// sing-box front. [startFor] delegates to [startMihomo] here.
  Future<StartResult> startFor(
    ProxyProfile profile, {
    required List<ProxyProfile> all,
    required RoutingProfile routing,
    required DnsSettings dns,
    ProxyProfile? warpProfile,
    bool chainWarpOutside = true,
  }) async {
    final sw = Stopwatch()..start();
    await prepare();
    if (singbox.status == RuntimeStatus.running ||
        singbox.status == RuntimeStatus.starting) {
      await singbox.stop();
    }
    if (profile.effectiveCore == CoreKind.amneziaWg) {
      amneziaWg.profile = profile;
      final r = await amneziaWg.start();
      if (r.ok) _active = profile;
      return r;
    }
    if (profile.effectiveCore == CoreKind.mihomo) {
      return startMihomo(
        profile: profile,
        all: all,
        routing: routing,
        dns: dns,
      );
    }
    await _ensureUpstream(profile, routing: routing);
    final r = await singbox.startWith(
      profiles: _singboxLoad(all),
      selectedProfileId: profile.id,
      routing: routing,
      dns: dns,
      socksUpstreams: _socksUpstreams(all),
      warpProfile: warpProfile,
      chainWarpOutside: chainWarpOutside,
    );
    if (r.ok) {
      _restartCount = 0;
      _active = profile;
      lastStartupMs = sw.elapsedMilliseconds;
    } else {
      await _stopUpstreams();
    }
    return r;
  }

  /// v0.5.3 §mihomo — STANDALONE START: mihomo owns the whole session.
  /// The whole runnable pool rides the config (selector group ATX), the
  /// mixed inbound serves the OS/front, and the engine's native Clash API
  /// (port 9099) serves the app's delay tests + selector migration.
  Future<StartResult> startMihomo({
    required ProxyProfile profile,
    required List<ProxyProfile> all,
    required RoutingProfile routing,
    required DnsSettings dns,
  }) async {
    final sw = Stopwatch()..start();
    if (mihomo.status == RuntimeStatus.running ||
        mihomo.status == RuntimeStatus.starting) {
      await mihomo.stop();
    }
    final pool = all
        .where((p) => p.enabled && p.effectiveCore == CoreKind.mihomo)
        .toList();
    if (mihomoSingletonPool(profile, pool)) pool.clear();
    final cfg = MihomoConfigGenerator().build(
      profiles: pool.isEmpty ? [profile] : pool,
      selectedId: profile.id,
      routing: routing,
      dns: dns,
    );
    final r = await mihomo.startWithConfig(cfg);
    if (r.ok) {
      _active = profile;
      lastStartupMs = sw.elapsedMilliseconds;
      Logger.instance.info('runtime',
          'mihomo session up: node=${profile.name} api=127.0.0.1:${mihomo.apiPort} '
          'mixed=${mihomo.mixedPort} in ${sw.elapsedMilliseconds}ms');
    }
    return r;
  }

  /// A single-node pool is fine; this predicate exists to keep the (rare)
  /// "profile itself not in `all`" case honest (connect hands us the pinned
  /// copy separately — see startFor callers).
  static bool mihomoSingletonPool(ProxyProfile profile, List<ProxyProfile> pool) =>
      !pool.any((p) => p.id == profile.id);

  /// Phase 5 fast switch: selector swap, no restart — but ONLY when the
  /// target profile actually carries traffic after the swap (v0.3.0 §15/§12):
  ///  * native sing-box profiles (incl. `CoreKind.unknown` non-xhttp ones —
  ///    a gap the §15 test found) always qualify;
  ///  * Xray/MDVPN-owned profiles qualify only while their daemon is
  ///    actually serving its local SOCKS endpoint (a dead stub would break
  ///    the traffic path silently).
  Future<bool> hotSwitch(
    ProxyProfile next, {
    required RoutingProfile routing,
    required DnsSettings dns,
  }) async {
    final cur = _active;
    // v0.6.4 §mihomo: standalone mihomo sessions hot-switch through the
    // engine's OWN selector (Clash API PUT /proxies/ATX) — sub-second, no
    // restart, the same path FlClash uses. Handled BEFORE the sing-box gate
    // below because a mihomo session runs no front engine at all.
    if (next.effectiveCore == CoreKind.mihomo &&
        mihomo.status == RuntimeStatus.running) {
      final api = mihomo.api;
      if (api == null) return false;
      // The target must actually be a member of the RUNNING config —
      // otherwise a 404 lies as a "switch failed".
      final tags = await api.proxyTags();
      if (tags == null || !tags.contains(next.name)) return false;
      return api.select(MihomoConfigGenerator.atxSelector, next.name);
    }
    if (singbox.status != RuntimeStatus.running) return false;
    switch (next.effectiveCore) {
      case CoreKind.singbox:
      case CoreKind.wireguardSingbox:
        break;
      case CoreKind.unknown:
        if (needsXrayUpstream(next)) return false; // stub only via xray path
        break;
      case CoreKind.xray:
        if (xray.status != RuntimeStatus.running ||
            !await xray.inboundHealthy()) {
          return false;
        }
        break;
      case CoreKind.masterDnsVpn:
        if (masterDnsVpn.status != RuntimeStatus.running ||
            !await masterDnsVpn.probe()) {
          return false;
        }
        break;
      case CoreKind.stormDns:
        if (stormDns.status != RuntimeStatus.running ||
            !await stormDns.probe()) {
          return false;
        }
        break;
      case CoreKind.amneziaWg:
        return false; // standalone daemon, never in the front selector
      case CoreKind.mihomo:
        // v0.5.3: mihomo-owned nodes migrate through mihomo's OWN selector
        // (Clash API PUT /proxies/ATX), never the sing-box front.
        return false;
    }
    if (cur != null &&
        (cur.effectiveCore == CoreKind.singbox ||
            cur.effectiveCore == CoreKind.wireguardSingbox ||
            cur.effectiveCore == CoreKind.xray ||
            cur.effectiveCore == CoreKind.masterDnsVpn ||
            cur.effectiveCore == CoreKind.stormDns ||
            cur.effectiveCore == CoreKind.unknown)) {
      return singbox.switchToProfile(next);
    }
    return false;
  }

  /// Phase 5 for Xray: restart only the upstream, then selector swap.
  Future<bool> restartXrayUpstream(
    ProxyProfile next, {
    required RoutingProfile routing,
    required DnsSettings dns,
  }) async {
    if (singbox.status != RuntimeStatus.running) return false;
    if (next.effectiveCore != CoreKind.xray) return false;
    try {
      await _ensureUpstream(next, routing: routing);
      return await singbox.switchToProfile(next);
    } on AppError catch (e) {
      Logger.instance
          .warn('manager', 'xray upstream switch failed: ${e.userMessage}');
      return false;
    }
  }

  void setActive(ProxyProfile p) => _active = p;

  /// Wall-clock duration of the last successful engine start (§25 metrics).
  int? lastStartupMs;

  /// Phase 26: restart-once recovery; further crashes bubble to failover.
  /// [engine] selects which process topology to rebuild: the front engine
  /// (sing-box) or the Xray/MDVPN upstream of the active profile.
  Future<bool> recoverEngine(
    CoreKind engine, {
    required List<ProxyProfile> all,
    required RoutingProfile routing,
    required DnsSettings dns,
  }) async {
    final active = _active;
    if (active == null || _restartCount >= _maxRestarts) return false;
    _restartCount++;
    Logger.instance.warn('manager',
        'recovering $engine (attempt $_restartCount)');

    if (engine == CoreKind.xray && _isXrayOwned(active)) {
      xray.fragment = _fragmentFor(active); // v0.4.6 WIRING: same as start
      final v = await xray.validateProfile(profile: active, routing: routing);
      if (!v.ok) return false;
      if (xray.status == RuntimeStatus.running) await xray.stop();
      final r = await xray.startProfile(profile: active, routing: routing);
      if (!r.ok) return false;
      return singbox.status == RuntimeStatus.running ||
          await singbox.inboundHealthy();
    }

    // MDVPN upstream crash: rebuild only the daemon (v0.3.0 §10 restart),
    // keep the front engine and selector untouched.
    // v0.6.4 §mihomo: standalone mihomo crash → rebuild the mihomo session
    // (startFor delegates to startMihomo). Without this branch the generic
    // path below stopped sing-box and restarted the same topology the
    // crash already proved dead — or worse, restarted the front for a
    // session that never had one.
    if (engine == CoreKind.mihomo && active.effectiveCore == CoreKind.mihomo) {
      final r = await startFor(active, all: all, routing: routing, dns: dns);
      return r.ok;
    }

    if (engine == CoreKind.masterDnsVpn && active.effectiveCore == CoreKind.masterDnsVpn) {
      if (masterDnsVpn.status == RuntimeStatus.running) {
        await masterDnsVpn.stop();
      }
      masterDnsVpn.profile = active;
      final r = await masterDnsVpn.start();
      if (!r.ok) return false;
      // Readiness is the SOCKS greeting probe — no readiness, no recovery.
      return masterDnsVpn.probe();
    }

    // v0.6.4 §stormdns: StormDNS upstream crash → rebuild only the daemon,
    // front engine and selector untouched (same shape as the mdvpn branch).
    if (engine == CoreKind.stormDns && active.effectiveCore == CoreKind.stormDns) {
      if (stormDns.status == RuntimeStatus.running) {
        await stormDns.stop();
      }
      stormDns.profile = active;
      final r = await stormDns.start();
      if (!r.ok) return false;
      return stormDns.probe();
    }

    await singbox.stop();
    final r = await startFor(active, all: all, routing: routing, dns: dns);
    return r.ok;
  }

  /// Back-compat alias used for front-crash recovery.
  Future<bool> recoverFront({
    required List<ProxyProfile> all,
    required RoutingProfile routing,
    required DnsSettings dns,
  }) =>
      recoverEngine(CoreKind.singbox,
          all: all, routing: routing, dns: dns);

  Future<void> _stopUpstreams() async {
    if (xray.status == RuntimeStatus.running) await xray.stop();
    if (masterDnsVpn.status == RuntimeStatus.running) await masterDnsVpn.stop();
    if (stormDns.status == RuntimeStatus.running) await stormDns.stop();
  }

  Future<void> stop() async {
    await _stopUpstreams();
    if (amneziaWg.status == RuntimeStatus.running) await amneziaWg.stop();
    // v0.5.3: a STANDALONE mihomo session dies with everything else.
    if (mihomo.status == RuntimeStatus.running) await mihomo.stop();
    await singbox.stop();
    _active = null;
    _restartCount = 0;
    // NOTE (v0.4.6 §user): stop() deliberately does NOT reset the fragment
    // AUTO ladder — the escalation loop itself restarts engines between
    // rungs, and a reset here would rewind the climb into an infinite loop.
    // The ladder rewinds at exactly ONE point: beginAutoLadder() on the
    // next connect.
  }

  // ---- v0.4.6 §user: fragment AUTO escalation ladder --------------------
  // With fragmentPreset == auto, an Xray start tries the fragment profiles
  // in a safe CLIMB ORDER instead of one fixed preset: per-node winner →
  // subscription suggestion → plain conservative-first, always WRAPPING so
  // every rung is tried before a connect gives up. The ladder state lives
  // here — the single authority over Xray starts — and only progresses on
  // an EXPLICIT advanceAutoLadder() from the callers' probe loop (see
  // ConnectionController.connect / VpnSession._connectProfile).
  // beginAutoLadder() is the ONLY rewind point, so every fresh connect
  // starts from its first rung while engine restarts inside one connect
  // keep the climbed position.

  void _resetAutoEscalation() {
    _autoStep = 0;
    _autoOrder = const [0, 1, 2];
  }

  /// Advance the AUTO ladder to the NEXT rung of the active climb order
  /// (callers do this after a failed probe, BEFORE the retry start) and
  /// report whether a further attempt is meaningful. The order wraps
  /// through every rung, so this returns false only when the LAST rung of
  /// the order has been reached — all three presets tried, none helped.
  /// Always false for non-auto presets.
  bool advanceAutoLadder() {
    if (fragmentPreset != FragmentPreset.auto) return false;
    if (_autoStep >= _autoOrder.length - 1) {
      return false; // every rung of the climb order has been tried
    }
    _autoStep++;
    return true;
  }

  /// Test/debug hook: rewind the AUTO ladder to its first rung.
  void resetAutoLadder() => _resetAutoEscalation();

  /// The fragment profile the current/next start of [fragmentPreset] emits
  /// for logging/diagnostics: the fixed preset's profile, or the AUTO rung
  /// at the current ladder index. Null when the pill is off. Per-node
  /// eligibility is applied separately in [_fragmentFor].
  FragmentProfile? get currentAutoFragment {
    if (!tlsFragmentEnabled) return null;
    if (fragmentPreset != FragmentPreset.auto) {
      return FragmentPresets.profileFor(fragmentPreset);
    }
    return FragmentPresets.all[_autoOrder[_autoStep.clamp(0, _autoOrder.length - 1)]];
  }

  /// Public fragment resolution for callers that generate the Xray config
  /// OUTSIDE the manager's own start path (VpnSession._startXrayUpstream on
  /// Android) — same eligibility + AUTO-rung semantics as the manager's
  /// internal starts. Null ⇒ run unfragmented.
  FragmentProfile? fragmentFor(ProxyProfile profile) => _fragmentFor(profile);

  Future<void> dispose() async {
    await stop();
    for (final s in _exitSubs) {
      await s.cancel();
    }
    await _anyExitCtrl.close();
    await singbox.dispose();
    await xray.dispose();
    await amneziaWg.dispose();
    await masterDnsVpn.dispose();
    await stormDns.dispose();
  }
}
