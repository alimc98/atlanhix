# NEXUS

**A production-grade, cross-platform proxy/VPN client for Windows, Linux and
Android.** Flutter UI · dual-core architecture (sing-box + Xray-core) ·
intelligent core detection · health engine · auto-failover · WARP chaining ·
subscription management.

> NEXUS is an independent implementation. It does not copy code from Throne,
> sing-box, Xray or any other client; it generates configurations for proven
> engines and supervises them. See `THIRD_PARTY_LICENSES.md` for the projects
> that make this possible.

## Feature highlights

| Area | What you get |
|---|---|
| **Cores** | sing-box + Xray-core with **intelligent CoreDetector** (confidence-scored, inspects the whole config — transport, security, params — not just the scheme) |
| **Protocols** | VMess, VLESS, Trojan, Shadowsocks (SIP002+legacy), Hysteria/2, TUIC, WireGuard, AmneziaWG, AnyTLS, ShadowTLS, Naive, SSH, SOCKS/HTTP, XHTTP, Reality, MasterDNSVPN (adapter) |
| **Import** | URI lists, Base64 subscriptions, Clash/Clash.Meta YAML, sing-box JSON, Xray JSON, `.conf` files, clipboard, QR, `nexus://import` deeplinks |
| **Subscriptions** | auto format detection, dedup, `subscription-userinfo` traffic/expiry parsing, background updates, offline-first |
| **Health** | layered probes (TCP/TLS/HTTP-through-proxy), TestScheduler with priority classes, health states |
| **Smart engine** | NodeScorer (5 strategies), Smart Connect, auto-failover, CDN detection, opt-in Xray fragmentation with cached profiles |
| **WARP** | device registration via Cloudflare's documented API, WireGuard endpoint generation, chainable with any node |
| **Chain builder** | proxy → WARP, WARP → proxy, multi-hop with technical validation (no UDP-in-UDP) |
| **Routing** | domain/suffix/keyword/IP/GeoIP/port/process rules, per-service profiles (Google→WARP, Iran-direct, AI, streaming, gaming), DNS modes incl. fake-IP |
| **UI** | original design system (dark/light/OLED), desktop sidebar + mobile bottom nav, EN/FA with full RTL, accessible, 60 fps graphs |
| **Security** | secrets in OS secure storage (vault-referenced, never in the DB), redacting logger, no telemetry |

## Quick start

```bash
flutter pub get
flutter run -d windows   # or linux / android
flutter test             # unit + widget suites
flutter analyze          # zero-error policy
```

Cores (`sing-box`, `xray`) are not bundled by default — drop the binaries into
the app's `cores/` directory or set their paths in Settings → Cores.
See `BUILD.md` for the exact per-platform layout.

## Documentation

* `docs/ARCHITECTURE.md` — layers, core runtime model, config pipeline
* `docs/PROTOCOL_SUPPORT.md` — full protocol matrix & core-detection signals
* `docs/PLATFORM_ARCHITECTURE.md` — Windows/Linux/Android internals (TUN, privileges, IPC)
* `design/` — DESIGN_SYSTEM, COLORS, TYPOGRAPHY, COMPONENTS, UX_RULES
* `BUILD.md`, `DEVELOPMENT.md`, `TROUBLESHOOTING.md`, `SECURITY.md`

## Status

Working, tested today: configuration import/normalize/export pipeline,
core detection, config generation for both engines, health/scoring/failover
engines, chain planner, routing compiler, subscription engine, WARP
registration client, design system & responsive UI shell, EN/FA l10n,
41+ passing tests, zero analyzer errors.

Remaining milestones (tracked in `DEVELOPMENT.md`): bundled core binaries per
platform, Windows/Linux TUN elevation UX, Android libbox engine binding,
per-app proxy UI, desktop tray menus.

## License

NEXUS code: MIT (see `LICENSE`). Third-party components retain their own
licenses — see `THIRD_PARTY_LICENSES.md`.
