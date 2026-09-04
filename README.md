# Atlanhix

**A production-grade, cross-platform proxy/VPN client for Windows, Linux and
Android.** Flutter UI آ· dual-core architecture (sing-box + Xray-core) آ·
intelligent core detection آ· health engine آ· auto-failover آ· WARP chaining آ·
subscription management.

> Atlanhix is an independent implementation. It does not copy code from Throne,
> sing-box, Xray or any other client; it generates configurations for proven
> engines and supervises them. See `THIRD_PARTY_LICENSES.md` for the projects
> that make this possible.

## Feature highlights

| Area | What you get |
|---|---|
| **Cores** | sing-box + Xray-core with **intelligent CoreDetector** (confidence-scored, inspects the whole config â€” transport, security, params â€” not just the scheme) |
| **Protocols** | VMess, VLESS, Trojan, Shadowsocks (SIP002+legacy), Hysteria/2, TUIC, WireGuard, AmneziaWG, AnyTLS, ShadowTLS, Naive, SSH, SOCKS/HTTP, XHTTP, Reality, MasterDNSVPN (adapter) |
| **Import** | URI lists, Base64 subscriptions, Clash/Clash.Meta YAML, sing-box JSON, Xray JSON, `.conf` files, clipboard, QR, `Atlanhix://import` deeplinks |
| **Subscriptions** | auto format detection, dedup, `subscription-userinfo` traffic/expiry parsing, background updates, offline-first |
| **Health** | layered probes (TCP/TLS/HTTP-through-proxy), TestScheduler with priority classes, health states |
| **Smart engine** | NodeScorer (5 strategies), Smart Connect, auto-failover, CDN detection, opt-in Xray fragmentation with cached profiles |
| **WARP** | device registration via Cloudflare's documented API, WireGuard endpoint generation, chainable with any node |
| **Chain builder** | proxy â†’ WARP, WARP â†’ proxy, multi-hop with technical validation (no UDP-in-UDP) |
| **Routing** | domain/suffix/keyword/IP/GeoIP/port/process rules, per-service profiles (Googleâ†’WARP, Iran-direct, AI, streaming, gaming), DNS modes incl. fake-IP |
| **UI** | original design system (dark/light/OLED), desktop sidebar + mobile bottom nav, EN/FA with full RTL, accessible, 60 fps graphs |
| **Security** | secrets in OS secure storage (vault-referenced, never in the DB), redacting logger, no telemetry |

## Quick start

```bash
flutter pub get
flutter run -d windows   # or linux / android
flutter test             # unit + widget suites
flutter analyze          # zero-error policy
```

Cores (`sing-box`, `xray`) are not bundled by default â€” drop the binaries into
the app's `cores/` directory or set their paths in Settings â†’ Cores.
See `BUILD.md` for the exact per-platform layout.

## Documentation

* `docs/ARCHITECTURE.md` â€” layers, core runtime model, config pipeline
* `docs/RUNTIME.md` â€” v0.2.1 runtime wiring, traffic-path topology, E2E harness
* `docs/PROTOCOL_SUPPORT.md` â€” full protocol matrix & core-detection signals
* `docs/PLATFORM_ARCHITECTURE.md` â€” Windows/Linux/Android internals (TUN, privileges, IPC)
* `docs/V0.2_RUNTIME_AUDIT.md` â€” v0.2 feature classification + verification
* `docs/V0.2.1_RUNTIME_WIRING_AUDIT.md` â€” wiring bugs W1â€“W8 + resolution
* `docs/V0.2.1_PERFORMANCE.md` â€” measured timings & resource usage
* `docs/V0.2.1_ANDROID_READINESS.md` â€” Android readiness audit
* `design/` â€” DESIGN_SYSTEM, COLORS, TYPOGRAPHY, COMPONENTS, UX_RULES
* `BUILD.md`, `DEVELOPMENT.md`, `TROUBLESHOOTING.md`, `SECURITY.md`

## Status

Verified with REAL external infrastructure (see `docs/e2e/v0.3.2-live-report.md`):
configuration import/normalize/export pipeline, core detection, **engine-validated
config generation** (sing-box check / xray -test actually run), **real process
supervision with live traffic-path E2E** — a real subscription (12 nodes) parsed,
inventoried and connected: **4 real nodes carried live HTTP 204 traffic through
Xray** (vless+xhttp over TLS and Reality); **real MasterDNSVPN DNS tunnel**
(`u.hixyz.ir`, official client binary) carried real HTTP traffic through the full
`sing-box → MDVPN SOCKS → DNS tunnel` chain, with crash recovery and process
cleanup proven; Smart Connect/failover/crash-recovery cycles with real engines,
chain planner, routing compiler, subscription engine, WARP registration client,
system proxy round-trip, diagnostics, design system & responsive UI shell,
EN/FA l10n, **94 tests passing (incl. live-subscription + live-MDVPN E2E),
0 analyzer errors**.

Terminology used throughout the docs:
`PARSED → GENERATED → VALIDATED → EXECUTABLE → RUNTIME_CONNECTED → E2E_VERIFIED`
(parser support ≠ connectivity; only `E2E_VERIFIED` means real traffic was proven).

Remaining milestones (tracked in `DEVELOPMENT.md`): bundled core binaries per
platform, Windows/Linux TUN elevation UX, Android libbox engine binding
(see `docs/ANDROID_VPN.md`), per-app proxy UI, desktop tray,
subscription auto-update scheduler.

## License

Atlanhix code: MIT (see `LICENSE`). Third-party components retain their own
licenses â€” see `THIRD_PARTY_LICENSES.md`.
