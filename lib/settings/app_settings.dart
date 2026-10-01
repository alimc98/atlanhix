import '../data/app_storage.dart';
import '../data/secure_vault.dart';
import 'routing_settings.dart';

/// v0.4.1 §7 — the real persistent application-settings model.
///
/// Every field is a user-visible control on the Settings screen and every
/// field has runtime semantics (consumed by [AppRuntimeWiring.settingsChanged]
/// consumers: the connect flow, the TUN handoff, the generated sing-box
/// config, the notification channel). Nothing here is a decorative toggle.
///
/// Persistence: [JsonStore] section `appSettings` (survives app restart,
/// process death, reboot). Secrets never enter this model — WARP keys live
/// in the vault via [WarpRepository], node credentials in ProfileRepository.
class AppSettings {
  AppSettings({
    // ---- General (§7 General) ----
    this.autoConnect = false,
    this.startOnBoot = false,
    this.keepVpnAlive = true,
    this.showNotifications = true,
    this.language = 'system', // system | en | fa
    this.theme = 'dark', // dark | light | oled
    // ---- VPN (§7 VPN) ----
    this.dnsMode = DnsModeUi.auto,
    this.dnsServers = const [],
    this.remoteDns = '',
    this.domesticDns = '',
    this.ipv6 = IpV6Mode.off,
    this.mtu = 0, // 0 = AUTO
    this.autoReconnect = true,
    this.connectionTimeoutSeconds = 15,
    // ---- Routing (§8) ----
    this.routingMode = RoutingMode.rule,
    // ---- Core (§7 Core) ----
    this.corePreference = CorePreference.auto,
    // ---- v0.4.4 user items 4/5: local port + proxy/TUN mode ----
    this.localPort = 2080, // local mixed proxy port (0 = auto)
    this.proxyMode = false, // true = system-proxy (no TUN), false = TUN
    // ---- v0.4.4 mockup: QUICK SETTINGS pills (opt-in, never silent) ----
    this.iranAppsDirect = false, // Iranian services bypass the tunnel
    this.adsBlock = false, // kill ads domains at DNS level
    this.tlsFragment = false, // Xray/sing-box fragmentation for deep drops
    // v0.4.6 §user: WHICH fragment profile the pill uses (conservative is
    // the safe default). Only meaningful while tlsFragment is on.
    this.fragmentPreset = FragmentPreset.conservative,
    // v0.4.7 §user: MANUAL fragment parameters (preset == manual).
    // Same shape as Xray's freedom `fragment` dial options.
    this.fragmentManualPackets = 'tlshello',
    this.fragmentManualLength = '100-200',
    this.fragmentManualInterval = '10-20',
    // ---- WARP (§30) ----
    // v0.4.8 §user: `off` is a real third state — WARP disabled. The two
    // chain shapes map to the user's two directions:
    //  * warpFirst  = WARP dials the NODE (app → WARP → node → internet) —
    //    for nodes whose handshake the censor has blocked; the WARP hop
    //    masks it. With AmneziaWG-3.1 params this survives carrier DPI.
    //  * warpLast   = the node dials WARP (app → node → WARP → internet) —
    //    sanctions evasion (Cloudflare exit IP).
    this.warpChainMode = WarpChainMode.off,
    // Auto-offer: after N consecutive URL-test failures through the
    // tunnel, the app asks to enable the WARP-first chain for this node
    // (the "this node looks filtered — chain WARP?" prompt).
    this.warpAutoOfferThreshold = 5,
    // URL the filter-detector probes through the tunnel. Empty = the
    // shared scheduler default (gstatic generate_204).
    this.warpProbeUrl = '',
    // v0.5.0 §user: THE delay-test URL — a user-editable field (Settings →
    // Delay test URL) feeding EVERY latency path: the node-list sweep, the
    // Smart Switch ladder, the WARP watchdog and the scheduler's TCP
    // fallback. Empty = gstatic generate_204. An `http://` URL (v2rayNG's
    // default shape) measures TCP+HTTP only — no TLS handshake — and
    // answers ~100 ms where the https default showed ~900 ms.
    this.delayTestUrl = '',
    // ---- Diagnostics (§7 Diagnostics) ----
    this.trafficStats = true,
    this.connectionLogs = true,
    this.debugLogging = false,
    // ---- v0.4.7 §user: Smart Switch (auto-select ladder) ----
    // How often the Smart Switch re-tests the candidate pool (seconds).
    // 0 disables the periodic re-test (single test at connect time).
    this.smartSwitchIntervalSeconds = 120,
    // v0.5.0 §user: switch tolerance (ms) — how much better a challenger
    // node must be before the tunnel migrates (0 = any strictly-better).
    this.smartSwitchMarginMs = 60,
    // v0.5.2 §user — THE PROFESSIONAL SMART SWITCH dials:
    //  * marginPercent — "Switch to a faster server ONLY when it is faster
    //    by N%" (default 30). The challenger's REAL delay must beat the
    //    incumbent's by this share before the tunnel migrates.
    //  * activeRecheckSeconds — "Recheck the server in use every N s"
    //    (default 30): a cheap in-tunnel URL test of the ACTIVE node only.
    //  * othersRescanMinutes — "Re-measure the other servers every N min"
    //    (default 10): a full batch over the rest of the pool.
    this.smartSwitchMarginPercent = 30,
    this.smartSwitchActiveRecheckSeconds = 30,
    this.smartSwitchOthersRescanMinutes = 10,
    // ---- v0.4.9 §user-fix: clipboard dedup (persisted offer memory) ----
    this.clipboardOfferedHashes = const [],
  });

  // General
  bool autoConnect;
  bool startOnBoot;
  bool keepVpnAlive;
  bool showNotifications;
  String language;
  String theme;

  // VPN
  DnsModeUi dnsMode;
  List<String> dnsServers; // custom servers when dnsMode == custom

  /// v0.4.1 § user request: manual DNS entry.
  /// [remoteDns] — the "outside" resolver the tunnel should trust for
  /// blocked/global names: a plain UDP IP (1.1.1.1), a DoT host
  /// (dns.google) or a DoH URL (https://…/dns-query). [domesticDns] — the
  /// resolver used for bootstrap/inside names (e.g. Shecan). Both feed the
  /// AUTO mode when set; empty means the app's measured defaults.
  String remoteDns;
  String domesticDns;
  IpV6Mode ipv6;
  int mtu;
  bool autoReconnect;
  int connectionTimeoutSeconds;

  // Routing
  RoutingMode routingMode;

  // Core
  CorePreference corePreference;

  /// v0.4.4 mockup pills — each is an explicit user switch (routing stays
  /// opt-in per the no-predefined-rules rule; these are the shortcuts).
  bool iranAppsDirect;
  bool adsBlock;
  bool tlsFragment;

  /// v0.4.6 §user: the selected fragmentation intensity for the
  /// TLS-Fragment pill. Maps to the FragmentPresets ids.
  FragmentPreset fragmentPreset;

  /// v0.4.7 §user: manual fragment dial parameters (fragmentPreset ==
  /// manual). `packets` is 'tlshello' or '1-3'; `length`/`interval` are
  /// Xray range strings ('100-200', '10-20').
  String fragmentManualPackets;
  String fragmentManualLength;
  String fragmentManualInterval;

  /// v0.4.4 §user-4: local proxy/mixed port shared by every mode
  /// (TUN front inbound, proxy-mode system proxy, health probes). 0=auto.
  int localPort;

  /// v0.4.4 §user-5: 'Proxy Mode' pill — VPN with NO TUN inbound; the
  /// session sets Android's global http proxy to localPort instead
  /// (API 28+; Mi 9T = API 30). false = full-device TUN tunnel.
  bool proxyMode;

  // WARP
  WarpChainMode warpChainMode;

  /// v0.4.8 §user: consecutive in-tunnel URL-test failures before the
  /// WARP-chain offer fires (user-settable, default 5).
  int warpAutoOfferThreshold;

  /// v0.4.8 §user: the detector's URL. Empty → scheduler default.
  String warpProbeUrl;

  /// v0.5.0 §user: the SHARED delay-test URL (Settings → Delay test URL).
  /// Empty → the gstatic generate_204 default.
  String delayTestUrl;

  /// The probe URL every latency path uses — never empty.
  /// v0.5.9 §ping-fix: the default moved https → PLAIN http. Other clients
  /// (v2rayNG et al.) ping with `http://www.gstatic.com/generate_204`; our
  /// old https default paid a full TLS handshake INSIDE the tunnel on every
  /// measurement — 3-4 round trips through the node — so the same node read
  /// ~150 ms elsewhere and 800-1200 ms here. Plain http over the foreign
  /// exit is un-hijackable-by-carrier (the carrier never sees it) and
  /// measures like the numbers users compare against. The https canaries
  /// in ConnectionController.probeFallbacks remain the fallback chain.
  static const String defaultDelayTestUrl =
      'http://www.gstatic.com/generate_204';
  String get effectiveDelayTestUrl =>
      delayTestUrl.trim().isEmpty ? defaultDelayTestUrl : delayTestUrl.trim();

  /// Back-compat view for the WARP watchdog: an explicit warpProbeUrl wins,
  /// otherwise the shared delay-test URL (which its UI field now edits).
  String get effectiveWarpProbeUrl =>
      warpProbeUrl.trim().isNotEmpty ? warpProbeUrl.trim() : effectiveDelayTestUrl;

  // Diagnostics
  bool trafficStats;
  bool connectionLogs;
  bool debugLogging;

  /// v0.4.9 §user-fix (clipboard dedup): sha256 hashes of clipboard
  /// payloads ALREADY offered (and answered) — persisted so a link that
  /// was added (or declined) never prompts again, across app runs.
  /// Capped: oldest entries are dropped beyond [clipboardOfferLimit].
  List<String> clipboardOfferedHashes;

  static const int clipboardOfferLimit = 64;

  /// v0.4.7 §user: Smart Switch re-test period (seconds). The switcher
  /// re-runs its candidate sweep on this cadence and migrates the tunnel
  /// when a materially better node appears. 0 = test only at connect time.
  int smartSwitchIntervalSeconds;

  /// v0.5.0 §user — Smart Switch tolerance (ms): a challenger node must
  /// beat the active node's latency by at least this much before the
  /// tunnel migrates (jitter guard; 0 = any strictly-better node wins).
  /// A dead active node is always abandoned regardless of this value.
  int smartSwitchMarginMs;

  /// v0.5.2 §user — margin as a PERCENTAGE (default 30): migrate only when
  /// the challenger is ≥ this % faster on the REAL delay test.
  int smartSwitchMarginPercent;

  /// v0.5.2 §user — recheck the ACTIVE node every N seconds (default 30).
  /// 0 disables the active recheck (pool rescans still apply).
  int smartSwitchActiveRecheckSeconds;

  /// v0.5.2 §user — re-measure the OTHER servers every N minutes (default
  /// 10). 0 disables the periodic pool rescan (connect-time ladder only).
  int smartSwitchOthersRescanMinutes;

  /// Effective MTU for the TUN handoff (§24). AUTO resolves to 8500 —
  /// sing-box's own default TUN MTU on mobile (safe for all carriers).
  static const int autoMtu = 8500;
  int get effectiveMtu => mtu < 1280 || mtu > 65535 ? autoMtu : mtu;
  bool get mtuIsAuto => mtu < 1280;

  Map<String, dynamic> toJson() => {
        'autoConnect': autoConnect,
        'startOnBoot': startOnBoot,
        'keepVpnAlive': keepVpnAlive,
        'showNotifications': showNotifications,
        'language': language,
        'theme': theme,
        'dnsMode': dnsMode.name,
        'dnsServers': dnsServers,
        'remoteDns': remoteDns,
        'domesticDns': domesticDns,
        'ipv6': ipv6.name,
        'mtu': mtu,
        'autoReconnect': autoReconnect,
        'connectionTimeoutSeconds': connectionTimeoutSeconds,
        'routingMode': routingMode.name,
        'corePreference': corePreference.name,
        'iranAppsDirect': iranAppsDirect,
        'adsBlock': adsBlock,
        'tlsFragment': tlsFragment,
        'fragmentPreset': fragmentPreset.name,
        'fragmentManualPackets': fragmentManualPackets,
        'fragmentManualLength': fragmentManualLength,
        'fragmentManualInterval': fragmentManualInterval,
        'localPort': localPort,
        'proxyMode': proxyMode,
        'warpChainMode': warpChainMode.name,
        'warpAutoOfferThreshold': warpAutoOfferThreshold,
        'warpProbeUrl': warpProbeUrl,
        'delayTestUrl': delayTestUrl,
        'trafficStats': trafficStats,
        'connectionLogs': connectionLogs,
        'debugLogging': debugLogging,
        'smartSwitchIntervalSeconds': smartSwitchIntervalSeconds,
        'smartSwitchMarginMs': smartSwitchMarginMs,
        'smartSwitchMarginPercent': smartSwitchMarginPercent,
        'smartSwitchActiveRecheckSeconds': smartSwitchActiveRecheckSeconds,
        'smartSwitchOthersRescanMinutes': smartSwitchOthersRescanMinutes,
        'clipboardOfferedHashes': clipboardOfferedHashes,
      };

  static AppSettings fromJson(Map<String, dynamic> j) => AppSettings(
        autoConnect: j['autoConnect'] as bool? ?? false,
        startOnBoot: j['startOnBoot'] as bool? ?? false,
        keepVpnAlive: j['keepVpnAlive'] as bool? ?? true,
        showNotifications: j['showNotifications'] as bool? ?? true,
        language: j['language'] as String? ?? 'system',
        theme: j['theme'] as String? ?? 'dark',
        dnsMode: DnsModeUi.values.firstWhere(
            (e) => e.name == j['dnsMode'],
            orElse: () => DnsModeUi.auto),
        dnsServers:
            (j['dnsServers'] as List?)?.cast<String>() ?? const [],
        remoteDns: j['remoteDns'] as String? ?? '',
        domesticDns: j['domesticDns'] as String? ?? '',
        ipv6: IpV6Mode.values
            .firstWhere((e) => e.name == j['ipv6'], orElse: () => IpV6Mode.off),
        mtu: j['mtu'] as int? ?? 0,
        autoReconnect: j['autoReconnect'] as bool? ?? true,
        connectionTimeoutSeconds: j['connectionTimeoutSeconds'] as int? ?? 15,
        routingMode: RoutingMode.values.firstWhere(
            (e) => e.name == j['routingMode'],
            orElse: () => RoutingMode.rule),
        corePreference: CorePreference.values.firstWhere(
            (e) => e.name == j['corePreference'],
            orElse: () => CorePreference.auto),
        iranAppsDirect: j['iranAppsDirect'] as bool? ?? false,
        adsBlock: j['adsBlock'] as bool? ?? false,
        tlsFragment: j['tlsFragment'] as bool? ?? false,
        fragmentPreset: FragmentPreset.values.firstWhere(
            (e) => e.name == j['fragmentPreset'],
            orElse: () => FragmentPreset.conservative),
        fragmentManualPackets:
            j['fragmentManualPackets'] as String? ?? 'tlshello',
        fragmentManualLength:
            j['fragmentManualLength'] as String? ?? '100-200',
        fragmentManualInterval:
            j['fragmentManualInterval'] as String? ?? '10-20',
        localPort: j['localPort'] as int? ?? 2080,
        proxyMode: j['proxyMode'] as bool? ?? false,
        warpChainMode: WarpChainMode.values.firstWhere(
            (e) => e.name == j['warpChainMode'],
            orElse: () => WarpChainMode.off),
        warpAutoOfferThreshold:
            j['warpAutoOfferThreshold'] as int? ?? 5,
        warpProbeUrl: j['warpProbeUrl'] as String? ?? '',
        delayTestUrl: j['delayTestUrl'] as String? ?? '',
        trafficStats: j['trafficStats'] as bool? ?? true,
        connectionLogs: j['connectionLogs'] as bool? ?? true,
        debugLogging: j['debugLogging'] as bool? ?? false,
        smartSwitchIntervalSeconds:
            j['smartSwitchIntervalSeconds'] as int? ?? 120,
        smartSwitchMarginMs: j['smartSwitchMarginMs'] as int? ?? 60,
        smartSwitchMarginPercent:
            j['smartSwitchMarginPercent'] as int? ?? 30,
        smartSwitchActiveRecheckSeconds:
            j['smartSwitchActiveRecheckSeconds'] as int? ?? 30,
        smartSwitchOthersRescanMinutes:
            j['smartSwitchOthersRescanMinutes'] as int? ?? 10,
        clipboardOfferedHashes:
            (j['clipboardOfferedHashes'] as List?)?.cast<String>() ?? const [],
      );
}

/// §8 — the two user-facing routing modes.
enum RoutingMode { global, rule }

/// §21 — user-facing DNS modes (UI-facing subset of DnsMode).
enum DnsModeUi { auto, system, remote, custom }

/// §23 — IPv6 handling. `off` is the safe default on Iranian mobile
/// carriers where IPv6 routing is inconsistent.
enum IpV6Mode { on, off, auto }

/// §7 Core — engine preference. `auto` defers to CoreDetector.
enum CorePreference { auto, singbox, xray, mihomo }

/// v0.4.6 §user — fragmentation intensity for the TLS-Fragment pill.
/// Each fixed value maps 1:1 to a [FragmentPresets] profile:
///   conservative → tlshello 10-40 / 5-10 ms (safest, first attempt)
///   default      → tlshello 100-200 / 10-20 ms (balanced)
///   aggressive   → 1-3 packets 10-20 / 5-10 ms (hardest to detect, riskier)
/// `auto` climbs the ladder conservative → default → aggressive per connect:
/// the safe preset first, escalating ONLY on a failed tunnel probe, and the
/// winning rung is persisted per node (FragmentLadderCache).
enum FragmentPreset { conservative, defaultPreset, aggressive, auto, manual }

/// §30 (v0.4.8 §user) — WARP integration shape. The WARP endpoint is
/// materialized inside the front sing-box config when an account exists
/// and the mode is a chain shape; `off` is the plain no-WARP topology.
///
///  * [warpFirst] — WARP dials the node: `app → WARP → node → internet`.
///    The CENSOR never sees the node's handshake (it happens inside the
///    WARP tunnel). For filtered/blocked nodes; AWG-3.1 params make the
///    WARP hop itself DPI-resistant on Iranian carriers.
///  * [warpLast] — the node dials WARP: `app → node → WARP → internet`.
///    The EXIT is Cloudflare — sanctions/egress-IP evasion.
///  * [off] — no WARP endpoint at all (the safe default; WARP never
///    silently wraps node traffic).
enum WarpChainMode { off, warpFirst, warpLast }

/// Persistence + change notification for [AppSettings].
///
/// Backed by the same [JsonStore] as every other repository (section
/// `appSettings`), so it survives restart/reboot/process death like the
/// rest of the app's state.
class AppSettingsRepository {
  AppSettingsRepository(this._store);

  final JsonStore _store;
  AppSettings _current = AppSettings();
  final _changes = <void Function(AppSettings)>[];

  AppSettings get current => _current;

  /// Register a listener that fires whenever any setting changes. The
  /// runtime wiring uses this to regenerate configs / update the UI.
  void addListener(void Function(AppSettings) listener) =>
      _changes.add(listener);

  Future<void> load() async {
    final section = _store.section('appSettings');
    if (section.isEmpty) return;
    _current = AppSettings.fromJson(section);
  }

  /// Persist a mutated settings object (whole-object replace keeps this
  /// atomic — partial writes could leave modes/flags inconsistent).
  Future<void> save(AppSettings s) async {
    _current = s;
    await _store.putSection('appSettings', s.toJson());
    for (final l in List.of(_changes)) {
      l(s);
    }
  }
}
