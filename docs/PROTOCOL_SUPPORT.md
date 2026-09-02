# NEXUS — Protocol Support Matrix

Legend: ✅ full · 🟡 partial/conditional · ❌ not available · 🔧 external engine

| Protocol | Parse inputs | Engine | Transport/TLS notes | Status |
|---|---|---|---|---|
| **VMess** | `vmess://` (base64 JSON), Clash YAML, sing-box/Xray JSON | sing-box, Xray | ws, grpc, h2, tcp, httpupgrade; TLS; alterId handling | ✅ |
| **VLESS** | `vless://`, JSON, Clash Meta YAML | sing-box, Xray | ws/grpc/h2/xhttp; TLS; **Reality**; `flow=xtls-rprx-vision` (Xray) | ✅ |
| **Trojan** | `trojan://`, JSON, YAML | sing-box, Xray | TLS, ws/grpc; password | ✅ |
| **Shadowsocks** | `ss://` (SIP002 + legacy), YAML, JSON | sing-box (+Xray where applicable) | 2022 ciphers via sing-box; plugin field parsed, plugin execution 🔧 | ✅ |
| **Hysteria2** | `hysteria2://`/`hy2://`, YAML, JSON | sing-box | password/auth, obfs (salamander), up/down bandwidth, insecure TLS, SNIs, port hopping ranges parsed 🟡 (hop applied where engine supports) | ✅ |
| **Hysteria (v1)** | YAML, JSON | sing-box | auth_str, alpn, up/down | 🟡 |
| **TUIC** | `tuic://`, JSON | sing-box | uuid+password, congestion control, ALPN | ✅ |
| **WireGuard** | `.conf` (INI), `wireguard://` 🔧 | sing-box `wireguard` endpoint; AmneziaWG daemon if AWG params present | private key, peer pub, endpoint, allowed-ips, DNS, MTU, keepalive, reserved | ✅ |
| **AmneziaWG** | `.conf` with `Jc/Jmin/Jmax/S1/S2/H1..H4` | 🔧 `amneziawg-go` | version-tolerant parameter map; unknown AWG params preserved & surfaced | ✅ |
| **AnyTLS** | YAML/JSON, `anytls://` | sing-box | password, TLS | ✅ |
| **ShadowTLS** | YAML/JSON | sing-box | v1/v2/v3 params | 🟡 |
| **NaiveProxy** | `naive+https://`, JSON | sing-box | user/pass, TLS | 🟡 |
| **SSH** | JSON, `ssh://` | sing-box | user/password or private key | 🟡 |
| **SOCKS / HTTP** | `socks://`, `http(s)://` proxies, JSON | sing-box, Xray | user/pass | ✅ |
| **XHTTP** | `vless://…?type=xhttp` | Xray | mode (auto/packet-up/stream-up/stream-one), path/host, extra params | ✅ |
| **XTLS/Reality** | any VLESS/VMess/Trojan with reality params | Xray (preferred) | publicKey, shortId, spiderX, fingerprint (utls) | ✅ |
| **Clash / Clash.Meta YAML** | full `proxies:` lists | → normalized | maps to internal model; unsupported proxies reported per-item | ✅ |
| **sing-box JSON** | full config (outbounds/endpoints) | sing-box | outbounds imported; non-proxy branches preserved in raw view | ✅ |
| **Xray JSON** | full config | Xray | outbounds imported; raw passthrough supported | ✅ |
| **WARP** | generated in-app (Cloudflare registration API) | sing-box WireGuard endpoint | client_id → `reserved` bytes; endpoint auto | ✅ |
| **MasterDNSVPN** | TOML snippets / URI (adapter-defined) | 🔧 `mdvpn-client` (Go, MIT) | DNS-tunnel transport; client exposes SOCKS5 which NEXUS ingests; config wizard + import; **adapter ships, engine binary must be provided/installed** | ✅ adapter / 🔧 engine |

## Import channels

URI list · Base64 subscription · subscription URL (auto format detect,
`subscription-userinfo` header parsing) · clipboard · QR (camera on Android,
image file on desktop) · local file (`.json/.yaml/.yml/.conf/.txt`) ·
deeplink (`nexus://import?url=…`).

## Core detection signals (CoreDetector)

| Signal family | Examples |
|---|---|
| Transport exclusivity | `xhttp` → Xray-only; `hysteria2/tuic/anytls/shadowtls` → sing-box-only |
| Flow | `flow=xtls-rprx-vision` → Xray |
| Reality placement | reality + xhttp/vision → Xray; plain reality VLESS → sing-box ok |
| Fragmentation need | `fragment` requested → Xray (freedom) |
| WireGuard/AWG params | `Jc/Jmin/Jmax/S1/S2/H1-H4` present → AmneziaWG |
| Native config bodies | sing-box `endpoint.wireguard` / Xray `outbounds` shape |
| Custom payloads | Unknown JSON shapes → `custom` profile with engine pinning |

Each signal contributes evidence with weight; final output is
`CoreChoice { core, confidence 0..1, reasons[] }`. UI shows it in the node
detail screen and allows override.

## MasterDNSVPN (§21) — implementation status

* **Spec**: TCP-over-DNS tunneling; custom transport protocol with ARQ
  (selective retransmission), multi-resolver load balancing, AES/ChaCha20
  payload encryption, ~5–7 B header overhead. Authoritative source:
  `github.com/masterking32/MasterDnsVPN` (MIT).
* **Integration**: external Go client binary (`mdvpn-client`) supervised by
  `MasterDnsVpnManager`; NEXUS generates `client_config.toml` +
  `client_resolvers` from a wizard (resolver list, server public key, subdomain,
  ports, encryption method/key, MTU, SOCKS mode), launches it, and treats its
  local SOCKS5 listener as an upstream — consumed by sing-box (`socks` outbound)
  which provides TUN/system-proxy/routing on top. This keeps MDVPN fully
  chainable (MDVPN → proxy, proxy → MDVPN) and routeable.
* **Not faked**: without the engine binary the UI shows
  "engine not installed" with install guidance; nothing pretends to connect.
