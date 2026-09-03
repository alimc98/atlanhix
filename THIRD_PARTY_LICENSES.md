# Third-Party Licenses & Attributions

Atlanhix is an **independent implementation**. No source code was copied from
the projects below. They are credited because Atlanhix either (a) generates
configurations consumed by their engines, or (b) follows documented,
protocol-level interfaces they maintain.

## Engines executed by Atlanhix (user-provided binaries)

| Project | License | Role |
|---|---|---|
| [sing-box](https://github.com/SagerNet/sing-box) | GPL-3.0 (with linking exception for *-libbox builds) | Primary proxy engine: Shadowsocks, VMess, VLESS, Trojan, Hysteria/2, TUIC, AnyTLS, WireGuard endpoints, TUN, DNS, Clash API |
| [Xray-core](https://github.com/XTLS/Xray-core) | MPL-2.0 | Secondary engine: VLESS/VMess/Trojan with Reality, XHTTP, XTLS vision, freedom-fragment |
| [AmneziaWG-Go](https://github.com/amnezia-vpn/amneziawg-go) | MIT | External daemon for AmneziaWG obfuscation profiles |
| [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN) | MIT | External client for the DNS-tunnel transport (adapter + TOML generation) |
| [wireguard-go / wireguard-windows](https://git.zx2c4.com/) | MIT | WireGuard protocol reference (used via sing-box endpoints) |

## Reference architectures studied (no code reuse)

| Project | License | What was learned |
|---|---|---|
| [Throne (Nekoray)](https://github.com/throneproj/Throne) | GPL-3.0 | Multi-core supervision model, SUID/capability strategy for TUN, subscription UX, route-profile data flow |
| [Hiddify](https://github.com/hiddify/hiddify-app) | Apache-2.0 | Fragmentation profiles, config preview UX |
| [wgcf](https://github.com/ViRb3/wgcf) | MIT | WARP device-registration API usage (OpenAPI spec), license binding, MTU guidance (1280) |

## Dart packages (pub.dev â€” see each repository for its license)

| Package | License |
|---|---|
| flutter, flutter_localizations | BSD-3-Clause |
| http, crypto, yaml, intl | BSD-3-Clause |
| cryptography | Apache-2.0 |
| flutter_secure_storage | BSD-3-Clause |
| path_provider, connectivity_plus | BSD-3-Clause |
| qr_flutter | MIT |
| window_manager, tray_manager | MIT |
| flutter_lints | BSD-3-Clause |

## Design references

Inter (SIL OFL 1.1), Vazirmatn (SIL OFL 1.1), JetBrains Mono (SIL OFL 1.1).

---
All trademarks belong to their respective owners. This file must be updated
when new third-party components are introduced.
