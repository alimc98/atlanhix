# NEXUS — Platform Architecture

NEXUS keeps every OS-specific behavior behind two seams: the **platform layer**
(Dart method channels / FFI in `platform/`) and the **core engines** (external
processes or Android services). The UI never branches on `Platform.isX` except
for layout decisions.

## Windows

| Concern | Approach |
|---|---|
| Cores | bundled/user-provided `sing-box.exe`, `xray.exe` (x64, ARM64 where published); user-mode processes |
| TUN | sing-box `tun` inbound using **wintun** driver; elevation prompt (UAC) only when TUN enabled; sing-box runs elevated, UI stays unprivileged, IPC via loopback + Clash API |
| System proxy | WinINET per-user proxy settings (HTTP+SOCKS) set via `platform/windows` channel; always restored on exit/crash via watchdog |
| Tray | `tray_manager` + `window_manager`; single-instance guard |
| Secrets | DPAPI (`win32` credential vault) via `flutter_secure_storage` |
| Process routing | via core `process`-based route rules (Xray/sing-box where supported) |

## Linux

| Concern | Approach |
|---|---|
| Cores | `sing-box`, `xray` (x64/ARM64); user-mode for local proxy |
| TUN | sing-box `tun` inbound (`/dev/net/tun`); capabilities policy: `cap_net_admin`+`cap_net_bind_service` on the core binary (documented `setcap` step in installer) instead of running the whole app as root |
| DNS | resolv.conf management with backup/restore + leak guard; fake-IP inside core |
| Tray | StatusNotifier/AppIndicator (`tray_manager`) |
| Secrets | Secret Service (libsecret) via `flutter_secure_storage`; fallback documented |

## Android

| Concern | Approach |
|---|---|
| VPN transport | **VpnService** (Android VpnService API) wrapping sing-box `tun` stack: the Flutter app talks to a foreground `VpnService` (engine mode), matching the architecture proven by SagerNet/sing-box for Android |
| Foreground service | `connectedDevice`/`dataSync` type contract, persistent notification with connect state + quick disconnect, battery exemptions requested explicitly |
| Always-on | honored via system setting; kill/revoke handling: service restart + user notification |
| Per-app proxy | `addAllowedApplication`/`addDisallowedApplication` |
| QR import | camera (mobile_scanner) + file |
| Storage | Keystore-backed secure storage; DB in app-private dir |
| Split APKs | arm64-v8a primary; armeabi-v7a where core binaries publish it |

## Privilege & IPC model (all desktop platforms)

```
┌───────────────────────────┐        ┌──────────────────────────────┐
│ NEXUS UI (unprivileged)   │  HTTP  │ sing-box / xray (maybe root) │
│  • all state & UI         │◄──────►│  • Clash API (sing-box)      │
│  • spawns/kills cores     │ loop-  │  • local inbound ports       │
│  • owns DB/settings       │ back   │  • TUN when elevated         │
└───────────────────────────┘        └──────────────────────────────┘
        │ stdin/stdout pipes (logs)              ▲
        └────────────────────────────────────────┘
```

* Elevation is granted **only to the core process**, never the app shell.
* All control traffic stays on loopback; Clash API is bound to `127.0.0.1`
  with a generated secret.
* Core lifecycle is owned by `CoreManager` with crash classification and
  bounded auto-restart; the UI observes state, never processes directly.

## Binary management

`CoreBinaryRegistry` resolves each engine per `(platform, arch)`:

1. bundled path (Android jniLibs / desktop `bin/`), then
2. user-provided path (Settings), then
3. marked *missing* (UI shows honest install state).

Version detection (`--version` parse) + size/hash sanity; no silent runtime
downloads by default — updates are explicit with checksum verification.

## Network awareness

`NetworkChangeMonitor` (connectivity_plus + OS events) triggers:
Wi-Fi↔Ethernet↔cellular transitions → re-verify active node; TUN restart on
link change; subscription updates paused on metered networks unless allowed.
IPv6: dual-stack dialing left to cores (`domain_strategy` configurable);
probes resolve both A/AAAA.
