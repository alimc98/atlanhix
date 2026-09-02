# NEXUS Runtime (v0.2)

How NEXUS actually runs proxies. Everything here is implemented and covered
by `test/runtime_test.dart` + `test/runtime_lifecycle_test.dart` against real
engine binaries (sing-box 1.14.0, Xray 26.3.27 at time of writing).

## Process lifecycle

```
ConnectionController (state machine: Phase 25)
        │
CoreManager ──── prepare() once at bootstrap
        │
        ├── SingBoxRuntime   front engine — mixed inbound 127.0.0.1:P, selector, TUN opt
        ├── XrayRuntime      upstream engine — local SOCKS 127.0.0.1:Q, restarted per node
        ├── AmneziaWgRuntime external daemon (standalone; no chaining) [if binary present]
        └── MasterDnsVpnRuntime external daemon → localhost SOCKS [if binary present]

ManagedProcess: spawn → stdout/stderr pumps → exit watcher → graceful stop
                (SIGTERM / taskkill, escalating to kill after grace).
PortAllocator: free loopback ports (mixed 2080, clash api 9097, xray 2081).
```

## Start pipeline (every connect)

1. `prepare()` — detect binaries (BinaryManager), allocate ports.
2. Validate — `sing-box check -c cfg` / `xray run -test -c cfg`.
   Invalid configs are **never started**; the human-readable engine error is
   surfaced (e.g. `unknown method:`, `outbounds[4]: dns outbound … removed`).
3. Start the upstream engine if the profile needs one (Xray / MDVPN).
4. Start sing-box with **all** runnable profiles in the selector.
5. Readiness probe — Clash API `/version` + TCP connect to the mixed inbound.
6. Connectivity verification — HTTP GET through SOCKS5 CONNECT to the tunnel
   (`gstatic generate_204`), classified DNS/TCP/TLS/HTTP/proxy/timeout.
7. Only now: state → `connected`, system proxy applied, monitors start.

## Switching (Phase 5)

| Scenario | Mechanism | Downtime |
|---|---|---|
| sing-box-family → sing-box-family | Clash API `PUT /proxies/proxy {name: node:<id>}` | ~0 |
| xray → xray | restart Xray process only, then selector swap | Xray restart only |
| cross-family | start/stop needed upstream, then selector swap | upstream start |
| AWG | standalone daemon (own TUN) — no front engine | full |

Verified by tests: the engine keeps `RuntimeStatus.running` across hot switches.

## Failover (Phase 6)

Active-node monitor probes the tunnel every `monitorInterval` (30 s default).
Failure (threshold 2): record → `NodeScorer.rank` → try up to 4 best healthy
candidates through the full verified start pipeline. Bounded; never loops.

## Crash recovery (Phase 26)

`ManagedProcess.onExit` → `classifyExit` (config / port-conflict / binary /
unknown from stderr tail + uptime) → `recoverFront` restarts **once** →
verify → else failover. Restart counter resets on clean start.

## Traffic (Phase 24)

`ClashApiClient.connections()` polls `uploadTotal/downloadTotal` once per
second while connected; the dashboard renders deltas as speeds and the
cumulative session. Xray-only sessions report `—` (its stats API is a listed
milestone) — never invented numbers.

## System proxy (Phase 13)

Windows: WinINET ProxyEnable/ProxyServer/ProxyOverride via `reg`, refresh via
`InternetSetOption`; originals captured and restored on disconnect.
Linux: GNOME gsettings when present. Privacy: all local, no telemetry.

## External daemons

* **AmneziaWG** — external `amneziawg` / `amneziawg-go`, standalone TUN.
  Status exposed as AVAILABLE / NOT INSTALLED / RUNNING / STOPPED / ERROR.
* **MasterDNSVPN** — external `mdvpn-client` in SOCKS5 mode; NEXUS generates
  `client_config.toml` from profile params; the local SOCKS is consumed by
  sing-box as an upstream stub (Phase 17 chaining).

## Android

Manifest + `NexusVpnService` foreground service are in place. Binding the
libbox engine (`libsingbox.so`) into the service is the remaining native
milestone; until then Android reports real states only (no fake "connected").
