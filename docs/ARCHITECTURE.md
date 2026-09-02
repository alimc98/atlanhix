# NEXUS — Architecture

> Working title **NEXUS** (brand is provisional). A production-grade cross-platform
> proxy/VPN client for **Windows, Linux and Android**, built with a Flutter UI and a
> protocol-neutral, core-agnostic Dart application core. It is an independent
> implementation informed by — but not derived from — Throne (GPL-3.0), sing-box
> (GPL-3.0 with linking exception via-* builds), Xray-core (MPL-2.0) and related
> projects. See `THIRD_PARTY_LICENSES.md`.

## 1. Design goals (ordered)

1. **Reliability** — never crash on malformed input; every failure has a typed,
   human-explainable error and a bounded recovery path.
2. **Correctness** — a feature exists only if it is technically real. The
   capability system hides options that a given profile/core/platform cannot honor.
3. **Performance** — no UI jank with 1000+ nodes, fast startup, fast switching,
   process reuse where safe.
4. **Security/privacy** — secrets in OS secure storage, log redaction by default,
   no telemetry.
5. **Extensibility** — new protocols/cores are added by registering adapters,
   not by editing the UI.

## 2. Layered architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│ presentation/   Flutter UI (Material 3 foundation, custom design system) │
│   • shell (responsive: desktop sidebar / mobile bottom nav)              │
│   • dashboard, nodes, subscriptions, warp, chain, routing, logs, settings│
│   • state: ChangeNotifier-based application-scoped controllers            │
├──────────────────────────────────────────────────────────────────────────┤
│ application/    Use-cases & orchestrators (pure Dart, UI-free)           │
│   • ConnectionController   connect/disconnect/switch lifecycle            │
│   • ProfileService, SubscriptionService, RoutingService, SettingsService  │
│   • FailoverCoordinator, SmartSelector, DiagnosticsCoordinator            │
├──────────────────────────────────────────────────────────────────────────┤
│ domain/         Pure models & value types (zero dependencies)            │
│   • ProxyProfile, ChainPlan, RoutingProfile, SubscriptionInfo,            │
│     HealthRecord, NodeScore, CoreDetection, AppError, CapabilitySet       │
├──────────────────────────────────────────────────────────────────────────┤
│ protocols/      Protocol adapters (parser+validator+generator per family) │
│   • VmessAdapter VlessAdapter TrojanAdapter ShadowsocksAdapter            │
│   • Hysteria2Adapter TuicAdapter WireGuardAdapter AmneziaWgAdapter        │
│   • MasterDnsVpnAdapter, ClashYamlAdapter, SingBoxJsonAdapter,            │
│     XrayJsonAdapter, SourceFormatSniffer                                 │
├──────────────────────────────────────────────────────────────────────────┤
│ core/           Engines (pure Dart)                                       │
│   • CoreDetector (confidence-scored), ConfigNormalizer, ConfigValidator,  │
│     ConfigGenerator (sing-box + Xray renderers), ChainPlanner,            │
│     CdnDetector, FragmentationEngine, WarpAccount/WarpRegistrar,          │
│     RoutingCompiler, NodeScorer, health/ (records, TestScheduler),        │
│     diagnostics/ (layered probes), logging/ (redacting logger)            │
├──────────────────────────────────────────────────────────────────────────┤
│ infrastructure/ Process & system boundaries (injected interfaces)         │
│   • cores/: CoreManager, XrayManager, SingBoxManager, WireGuardManager,   │
│     AmneziaWgManager, MasterDnsVpnManager, CoreBinaryRegistry             │
│   • net/: latency prober, public-IP resolver, network-change monitor      │
│   • storage/: Drift database, migrations, SecureVault (OS keyring)        │
│   • subscriptions/: downloader (redirects, header capture)                │
├──────────────────────────────────────────────────────────────────────────┤
│ platform/       Native bindings per OS (the only platform-specific code)  │
│   • android/: VpnService plugin contract (see PLATFORM_ARCHITECTURE.md)   │
│   • windows/: system proxy, tray, admin/elevation helpers                 │
│   • linux/:  TUN permissions, DNS hooks, tray                             │
└──────────────────────────────────────────────────────────────────────────┘
```

Rules enforced by convention + imports:

* `domain/` imports **nothing** from other layers.
* `presentation/` never touches `infrastructure/` or `platform/` directly;
  it consumes `application/` controllers and `domain/` models only.
* All async I/O is off the UI isolate; long parsing uses `compute()`-style
  isolate dispatch for >~100-item batches.

## 3. Core runtime model (two primary cores + specialists)

The application never implements tunnel protocols itself. It *generates configs*
for proven engines and supervises them as processes/services.

| Engine | Binary | Used for | Control plane |
|---|---|---|---|
| **sing-box** | `sing-box` | Shadowsocks, VMess, VLESS, Trojan, Hysteria/Hysteria2, TUIC, AnyTLS, ShadowTLS, NaiveProxy, SSH, SOCKS/HTTP, WireGuard (endpoint), TUN on all platforms, DNS (DoH/DoT/fake-IP), routing | Clash-API (selector hot-switch, delay tests), config file |
| **Xray-core** | `xray` | VLESS/VMess/Trojan with XTLS/Reality/XHTTP and Xray-specific transports, fragmentation (`freedom.fragment`) | config file, restart-on-switch |
| **WireGuard (userspace)** | via sing-box `wireguard` endpoint | native WireGuard profiles | config generation |
| **AmneziaWG** | `amneziawg-go` external daemon | AWG (junk packets, header obfuscation) — *not* in upstream sing-box | conf file, process supervision |
| **MasterDNSVPN** | `mdvpn-client` external daemon | DNS-tunnel transport (custom protocol + ARQ) | TOML config, local SOCKS5 ingestion |

### CoreManager contract

```text
CoreAdapter (interface)
  start(profile-artifact) -> ProcessHandle
  stop() / restart()
  health() -> CoreHealth
  stats() -> TrafficStats
  validate(artifact) -> ValidationResult     # `sing-box check` / `xray -test`
  logs()  -> Stream<LogLine>
  switchProfile(id)                          # sing-box: selector swap via Clash API
                                             # xray: guarded restart (same binary)
Managers: XrayManager · SingBoxManager · WireGuardManager ·
          AmneziaWgManager · MasterDnsVpnManager
```

* **Crash safety**: exit-code + stderr tail capture → classified into
  `config`, `port-conflict`, `binary`, `network`, `unknown`; auto-restart with
  exponential backoff (max 3) before failing over.
* **Fast switching**: if the new profile and old profile run on the same
  sing-box instance, the manager performs a **selector hot-swap** through the
  Clash API (sub-second, no TUN/proxy disruption). Xray-backed profiles restart
  the Xray process only (sing-box keeps running and forwards to the Xray
  local port when chained). Reliability beats micro-optimizations: any doubt →
  clean restart of the affected engine only.

## 4. Configuration pipeline

```
raw input (URI / base64 / YAML / JSON / conf / QR / clipboard / file / URL)
   │ SourceFormatSniffer        (format + encoding detection)
   ▼
ProtocolAdapter.parse           (family-specific, throws ParseError)
   ▼
ProxyProfile                    (universal normalized model)
   │ CoreDetector               (protocol + transport + security + params)
   ▼
ConfigValidator                 (schema, ports, TLS/Reality params, core match)
   ▼
ConfigGenerator                 (sing-box or Xray renderer + routing + DNS)
   ▼
CoreAdapter.validate            (engine self-check, e.g. `sing-box check`)
   ▼
launch / hot-switch
```

`CoreDetector` emits a confidence score (0..1) with per-signal reasons, e.g.:

```
Protocol: VLESS   Transport: XHTTP   Security: Reality
core=xray confidence=0.97
reasons: xhttp transport is Xray-only; reality detected; flow=xtls-rprx-vision
```

The user can override detection per profile (stored, shown in UI).

## 5. State & data flow in the application layer

* `ConnectionController` is the single source of truth for
  `ConnectionState { disconnected, connecting, connected(id), disconnecting, error }`
  and is derived into UI streams.
* Repositories (`data/`) expose `Stream<List<T>>` + CRUD; Drift/SQLite is the
  source of truth; secure values (passwords, private keys, WARP token) live in
  `SecureVault` (Android Keystore / Windows DPAPI / Linux Secret Service) and are
  joined at config-generation time only.
* Health records are append-only; aggregates (score, success rate, jitter) are
  derived on write, cached in memory.

## 6. Health, testing & failover engines

```
TestScheduler (no global timer; priority queue of test jobs)
 ├── ActiveNodeMonitor      — highest priority, interval from settings
 ├── BackgroundNodeTester   — ring-batch, concurrency-limited (default 6)
 ├── SubscriptionTester     — on update / explicit
 └── RecoveryTester         — validates candidate before switching
```

* **NodeScorer** combines `latency + successRate + stability + recentHealth +
  userPriority − failurePenalty` with selectable strategies
  (lowest-latency / most-stable / balanced / manual / smart).
* **FailoverCoordinator**: on threshold breach (default 2 failures) it marks the
  node, takes the best healthy candidate **without waiting for a full sweep**
  (cached scores), validates it with a single probe through the *running* core
  where possible, switches, records the event, notifies.
* **CdnDetector** classifies CDN-fronted nodes (host patterns, Cloudflare IP
  ranges, SNI/transport signals) — signals only, never a hard rule.
* **FragmentationEngine** (opt-in, default off): only for Xray + TLS-family
  transports; injects a `freedom` fragment outbound + routing rule using
  profiles *Conservative / Default / Aggressive / Custom*; successful profile is
  cached per node; sing-box paths are ineligible (documented limitation).

## 7. Chaining & WARP

* `ChainPlanner` validates and materializes ordered chains
  `[profile] → [warp] → [direct]` or `[warp] → [profile] → [direct]`.
  * sing-box: chained via `detour` (outbound under outbound).
  * Xray: chained via `sockopt.dialerProxy` (single Xray instance).
  * Cross-engine chains (e.g. Xray node → WARP) are materialized by routing the
    upstream through the local inbound of the next engine — validated first.
* WARP accounts are registered against Cloudflare's device-registration API
  (the same documented endpoint family used by the official clients and by
  wgcf, MIT). X25519 keypairs are generated locally; responses (token,
  private key, license, client_id, endpoint) are stored in the SecureVault.
  The WARP device is exposed as a WireGuard endpoint and participates in
  chains exactly like a WireGuard profile.

## 8. Subscriptions

* Downloader follows redirects, custom UA, timeout; captures standard
  `subscription-userinfo` (upload/download/total/expire) and `profile-title`.
* Content is decoded (base64 / plain URI list / Clash YAML / sing-box JSON),
  every node is normalized to `ProxyProfile`, deduplicated by a stable
  content-hash, and diffed (`124 → 137 nodes`) for the UI.
* Update scheduling respects per-subscription interval and runs fully async;
  results merge into existing health history by profile identity hash.

## 9. Storage & secrets

* **Drift (SQLite)** for profiles, subscriptions, chains, rules, health stats,
  settings — with explicit schema version + forward-only migrations.
* **SecureVault** for passwords/private keys/tokens (per-OS). The database
  stores only references (vault keys), never secret material, unless the OS
  store is unavailable — in which case the fact is surfaced in Settings.
* **Redacting logger**: passwords, UUIDs, base64 credentials, private keys and
  subscription tokens are masked before any log line is emitted.

## 10. Performance engineering

* UI isolates never touch process I/O; parsing batches run in worker isolates.
* Node list uses `ListView.builder` + value-keyed item widgets; health updates
  patch single items (immutable profile + selector-based rebuilds).
* Subscriptions and 500/1000-node sweeps are chunked with backpressure;
* Core start artifacts are cached and invalidated by profile revision.

## 11. Testing strategy

* **Unit**: every parser, the CoreDetector, validator, scorers, failover state
  machine, routing compiler, chain planner, subscription decoder, WARP
  registrar (HTTP layer faked at the boundary).
* **Widget**: dashboard, node list/detail, subscription card, chain builder.
* **Integration**: import → detect → generate → validate (engine `check`
  binary) → start → probe → disconnect, executed against real cores when they
  are present on the machine and skipped-with-reason otherwise.

## 12. Explicit limitations (honesty policy)

* AmneziaWG is **not** part of upstream sing-box — it is provided through the
  external `amneziawg-go` daemon and marked as such in the UI until installed.
* Fragmentation is an Xray capability; sing-box-only nodes show it disabled.
* Process-based routing on desktops is only as reliable as the OS allows
  (Windows: WFP-based matching is out of scope for v1; we expose per-process
  rules through core `process` matchers where the engine supports them).
* Telemetry: none. Crash reports: local only, redacted.


