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
    // ---- WARP (§30) ----
    this.warpEnabled = false,
    this.warpChainMode = WarpChainMode.warpAsOutbound,
    // ---- Diagnostics (§7 Diagnostics) ----
    this.trafficStats = true,
    this.connectionLogs = true,
    this.debugLogging = false,
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

  // WARP
  bool warpEnabled;
  WarpChainMode warpChainMode;

  // Diagnostics
  bool trafficStats;
  bool connectionLogs;
  bool debugLogging;

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
        'warpEnabled': warpEnabled,
        'warpChainMode': warpChainMode.name,
        'trafficStats': trafficStats,
        'connectionLogs': connectionLogs,
        'debugLogging': debugLogging,
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
        warpEnabled: j['warpEnabled'] as bool? ?? false,
        warpChainMode: WarpChainMode.values.firstWhere(
            (e) => e.name == j['warpChainMode'],
            orElse: () => WarpChainMode.warpAsOutbound),
        trafficStats: j['trafficStats'] as bool? ?? true,
        connectionLogs: j['connectionLogs'] as bool? ?? true,
        debugLogging: j['debugLogging'] as bool? ?? false,
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
enum CorePreference { auto, singbox, xray }

/// §30 — WARP integration shape. `warpAsOutbound` = the generated config
/// contains a real WARP outbound that rules can target (Google → WARP etc.).
/// `chain` = traffic chaining Proxy ⇄ WARP via the existing chain planner.
enum WarpChainMode { warpAsOutbound, chain }

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
