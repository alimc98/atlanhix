Atlanhix

A production-grade, cross-platform proxy/VPN client for Windows, Linux, and Android.

Atlanhix is a modern VPN and proxy client built with Flutter, combining a native Flutter UI with a dual-core runtime based on sing-box and Xray-core.

It provides intelligent core detection, advanced health monitoring, automatic failover, Smart Switch, subscription management, WARP chaining, endpoint scanning, advanced routing, and a unified cross-platform experience.

«Independent implementation

Atlanhix does not copy code from Throne, sing-box, Xray, or other clients. It generates and manages configurations for established networking engines and supervises their runtime.

See ""THIRD_PARTY_LICENSES.md"" (THIRD_PARTY_LICENSES.md) for third-party components and their licenses.»

---

✨ Features

⚡ Dual-Core Engine

Atlanhix supports multiple networking engines and intelligently determines which engine should handle each configuration.

- sing-box
- Xray-core
- Intelligent "CoreDetector"
- Confidence-scored core selection
- Full configuration inspection
- Transport-aware detection
- Security-aware detection
- Parameter-aware detection
- Engine-level configuration validation
- Process supervision
- Crash recovery

---

🌐 Protocol Support

Supports a broad range of modern proxy and VPN protocols:

- VMess
- VLESS
- Trojan
- Shadowsocks
  - SIP002
  - Legacy formats
- Hysteria
- Hysteria 2
- TUIC
- WireGuard
- AmneziaWG
- AnyTLS
- ShadowTLS
- Naive
- SSH
- SOCKS
- HTTP
- XHTTP
- Reality
- MasterDNSVPN adapter

---

📥 Import & Subscriptions

Import configurations from virtually any common source:

- URI lists
- Base64 subscriptions
- Clash / Clash.Meta YAML
- sing-box JSON
- Xray JSON
- ".conf" files
- Clipboard
- QR codes
- "Atlanhix://import" deep links

Subscription management includes:

- Automatic format detection
- Node deduplication
- "subscription-userinfo" traffic parsing
- Subscription expiry parsing
- Background updates
- Offline-first operation

---

🧠 Smart Switch

Atlanhix includes an automatic Smart Switch system that continuously manages multiple configurations.

Instead of relying on a single node, Smart Switch can automatically move between available configurations based on their runtime health and connectivity.

Config A ──┐
Config B ──┤
Config C ──┼──► Smart Switch ──► Active Connection
Config D ──┤
Config E ──┘

Features include:

- Automatic configuration switching
- Health-aware selection
- Failed-node detection
- Automatic recovery
- Continuous connection monitoring
- Integration with Smart Connect
- Integration with automatic failover

The goal is to keep the connection alive without requiring the user to manually switch configurations.

---

🧠 Smart Connect

Smart Connect evaluates available nodes and selects a suitable connection automatically.

- "NodeScorer"
- Multiple scoring strategies
- Health-aware selection
- Automatic failover
- CDN detection
- Connectivity testing
- Optional Xray fragmentation
- Cached fragmentation profiles

Smart Connect and Smart Switch can work together to continuously maintain a usable connection.

---

🩺 Health Engine

Atlanhix uses a layered health engine to determine whether a configuration is actually usable.

Health checks can include:

- TCP probes
- TLS probes
- HTTP-through-proxy probes
- Connection latency
- Runtime state
- Priority-based testing
- Automatic failure detection

Configuration parsing alone does not determine whether a node is usable.

Atlanhix distinguishes between:

PARSED
   ↓
GENERATED
   ↓
VALIDATED
   ↓
EXECUTABLE
   ↓
RUNTIME_CONNECTED
   ↓
E2E_VERIFIED

---

🛜 WARP + AmneziaWG

Atlanhix includes an advanced WARP system built around AmneziaWG 3.1, providing more than simple WARP connectivity.

🔎 WARP Endpoint Scanner

Atlanhix can scan WARP endpoints and identify usable endpoints for the current connection environment.

This allows the application to find a suitable endpoint instead of relying on a single static endpoint.

---

🚀 WARP First

WARP First is designed for situations where the original configuration's IP or network path is filtered.

The traffic path becomes:

Device
   ↓
WARP
   ↓
Proxy / VPN Configuration
   ↓
Internet

This can allow an otherwise unreachable configuration to become usable by establishing the initial connection through WARP.

---

🌍 WARP Last

WARP Last is designed for services that are inaccessible from the user's normal network path.

The traffic path becomes:

Device
   ↓
Proxy / VPN Configuration
   ↓
WARP
   ↓
Destination

This allows WARP to be used as the final hop for destinations that require a different network exit.

---

🔗 WARP Chaining

WARP can be combined with proxy configurations in multiple ways:

WARP → Proxy

Proxy → WARP

Proxy → Proxy → WARP

Atlanhix performs technical validation of chain configurations to prevent invalid combinations such as unsupported UDP-over-UDP paths.

---

🧭 Advanced Routing

Atlanhix provides flexible routing controls for directing different traffic through different network paths.

Supported rules include:

- Domain
- Domain suffix
- Domain keyword
- IP / CIDR
- GeoIP
- Port
- Process
- Service-specific routing

Example:

Google       → WARP
Iran         → Direct
AI Services  → Proxy
Streaming    → Proxy
Gaming       → Custom Route

DNS features include:

- Multiple DNS modes
- Fake-IP
- Custom DNS routing
- Per-route DNS handling

---

🧩 Chain Builder

Build and validate multi-hop connection chains directly inside Atlanhix.

Examples:

Proxy → WARP

WARP → Proxy

Proxy → Proxy → WARP

Proxy → Proxy → Proxy

The chain builder validates technical compatibility before attempting to start the connection.

---

🎨 Modern Cross-Platform UI

Atlanhix uses an original design system built specifically for a VPN/proxy application.

- Dark mode
- Light mode
- OLED mode
- Desktop sidebar navigation
- Mobile bottom navigation
- Responsive layouts
- English / Persian
- Full RTL support
- Accessible interface
- Real-time traffic visualization
- 60 FPS graphs

The interface is designed around real-time connection state, traffic activity, node health, and network controls rather than treating the application as a simple configuration list.

---

📊 Real-Time Traffic

Atlanhix provides real-time network statistics and connection monitoring.

The interface can display:

- Download speed
- Upload speed
- Current traffic
- Connection state
- Node status
- Runtime health
- Connection activity

Traffic visualization is designed to make the active network path immediately understandable.

---

🔐 Security & Privacy

Atlanhix is designed with a privacy-focused architecture.

- Secrets stored using OS secure storage
- Credentials referenced through secure vault mechanisms
- Sensitive values are not stored directly in the application database
- Redacted logging
- No telemetry by default

---

🚀 Quick Start

Requirements

Install Flutter and the required platform toolchains.

Then:

flutter pub get

Run Atlanhix on Windows:

flutter run -d windows

Linux:

flutter run -d linux

Android:

flutter run -d android

Run tests:

flutter test

Run static analysis:

flutter analyze

---

⚙️ Core Binaries

The "sing-box" and "xray" binaries are not bundled by default.

Place the required binaries inside the application's:

cores/

directory, or configure their locations from:

Settings → Cores

See ""BUILD.md"" (BUILD.md) for platform-specific build and binary layout.

---

🏗️ Architecture

Atlanhix separates the UI, configuration pipeline, networking engines, health system, routing engine, and platform integration into independent layers.

A simplified runtime flow:

                    ┌──────────────────┐
                    │   Import / URL   │
                    │ Subscription /QR │
                    └────────┬─────────┘
                             ↓
                    ┌──────────────────┐
                    │     Parser       │
                    └────────┬─────────┘
                             ↓
                    ┌──────────────────┐
                    │   Normalizer     │
                    └────────┬─────────┘
                             ↓
                    ┌──────────────────┐
                    │ Core Detection   │
                    └────────┬─────────┘
                             ↓
                    ┌──────────────────┐
                    │ Config Generator │
                    └────────┬─────────┘
                             ↓
                 ┌────────────────────────┐
                 │   sing-box / Xray      │
                 └────────────┬───────────┘
                              ↓
                    ┌──────────────────┐
                    │  Health Engine   │
                    └────────┬─────────┘
                             ↓
               ┌─────────────┴─────────────┐
               ↓                           ↓
        ┌──────────────┐            ┌──────────────┐
        │ Smart Connect│            │ Smart Switch │
        └──────┬───────┘            └──────┬───────┘
               └─────────────┬─────────────┘
                             ↓
                    ┌──────────────────┐
                    │ Routing / Chain  │
                    └────────┬─────────┘
                             ↓
                    ┌──────────────────┐
                    │   Live Traffic   │
                    └──────────────────┘

---

📦 Project Structure

Atlanhix/
├── android/
├── linux/
├── windows/
├── lib/
│   ├── core/
│   ├── engine/
│   ├── routing/
│   ├── subscriptions/
│   ├── health/
│   ├── platform/
│   └── ui/
├── docs/
├── design/
├── cores/
├── test/
├── BUILD.md
├── DEVELOPMENT.md
├── SECURITY.md
├── THIRD_PARTY_LICENSES.md
└── LICENSE

---

📄 License

Atlanhix source code is licensed under the MIT License.

See ""LICENSE"" (LICENSE).

Third-party components retain their respective licenses.

See ""THIRD_PARTY_LICENSES.md"" (THIRD_PARTY_LICENSES.md).

---

Atlanhix

One client. Multiple engines. Intelligent routing. Smart switching.

Built with Flutter.
Powered by sing-box + Xray-core + AmneziaWG.
