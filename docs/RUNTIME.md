# NEXUS Runtime (v0.2.1)

How NEXUS actually routes traffic. Everything here is implemented and covered
by `test/runtime_test.dart`, `test/runtime_lifecycle_test.dart` and
`test/e2e_test.dart` against real engine binaries (sing-box 1.14.0,
Xray 26.3.27).

## Traffic-path topology (v0.2.1 — wiring fixed)

```
NEXUS probe/controller
   │
   ▼
sing-box front (mixed inbound 127.0.0.1:P, selector "proxy")
   ├── native outbound ─────────────────────► remote server
   ├── wireguard endpoint ──────────────────► wg remote
   ├── Xray SOCKS stub ──► xray socks-in ──► xray outbound ──► remote
   └── MDVPN SOCKS stub ──► mdvpn socks ───► DNS tunnel ─────► remote
```

**Invariant (verified by E2E):** the CoreDetector's engine decision controls
the actual traffic path. Xray-owned profiles are *never* built as native
sing-box outbounds — `OutboundBuilders.singBoxOutbound` returns `null` for
them, and `CoreManager._socksUpstreams` provides the SOCKS stub pointing at
the Xray local inbound. The stub is only emitted after Xray is confirmed
listening (`inboundHealthy`).

## Proof that Xray is IN the path (not merely started)

1. `XrayConfigGenerator` writes an **access log** per session
   (`accessLogPath`, truncated at each start).
2. The E2E test sends an HTTP request whose destination is the local mock
   server, then asserts the access log contains the destination address.
3. If sing-box had bypassed Xray (the pre-fix bug), the access log would
   remain empty → test fails.

## Engine lifecycle (CoreManager.startFor — full pipeline)

1. `prepare()` — detect binaries, allocate free loopback ports (mixed 2080 *,
   clash API 9097 *, xray socks 2081 *; * = preferred, falls back to any free).
2. **Stop previous topology if running** (failover fix: prevents orphaned
   old-process binding + stale selector).
3. Start upstream (Xray/MDVPN) if needed: generate config →
   `run -test` (Xray) → spawn → readiness (SOCKS inbound TCP) →
   re-check `inboundHealthy`.
4. Start sing-box front: generate config (**with** SOCKS stubs) →
   `check` → spawn → readiness (Clash API + mixed inbound).
5. Connectivity verification — classified HTTP probe through the tunnel.
6. Only now: state → CONNECTED; system proxy applied; monitors start.

## Fast switching (Phase 5) — verified, zero-restart for same family

| Scenario | Mechanism | Engine restart |
|---|---|---|
| sing-box-family → sing-box-family | Clash API selector swap | **no** |
| xray → xray | Xray process restart only, then swap | Xray only |
| cross-family | upstream start/stop + swap | affected upstream |
| AWG | standalone daemon | full |

## Failover (Phase 6) & crash recovery (Phase 26)

* Active-node monitor (default 30 s) probes through the tunnel.
* Threshold breach → `NodeScorer.rank` → up to 4 verified candidates.
* `CoreManager.onAnyExit` merges sing-box + Xray + MDVPN + AWG exit streams;
  the controller routes: front crash → `recoverFront` (restart once);
  upstream crash → `recoverEngine(upstream)` (restart once, front untouched).
* Recovery verify-fail → automatic failover. Bounded everywhere.

## Traffic (Phase 24) — real bytes only

sing-box Clash API `/connections` polled 1 s → `upload/downloadTotal` →
dashboard speeds (deltas) + session totals. Xray-fronted sessions report `—`
(stats API milestone) — never invented.

## System proxy (Phase 13)

Windows WinINET (capture → set → restore) with `InternetSetOption` refresh;
Linux GNOME gsettings when present. Restore runs on every disconnect path.

## External daemons

* **AmneziaWG** — external `amneziawg`/`amneziawg-go`; standalone TUN (no
  chaining by design); states: AVAILABLE / NOT INSTALLED / RUNNING / etc.
* **MasterDNSVPN** — external `mdvpn-client` in SOCKS5 mode; NEXUS generates
  `client_config.toml`; localhost SOCKS ingested by sing-box (Phase 17).

## E2E verification harness (test/e2e_test.dart)

Deterministic local topology, no external network needed:

```
probe → sing-box mixed → selector → outbound → MockSocksServer
                                             → MockHttpServer
```

* Native: outbound is `shadowsocks` → sing-box ss-server (second process).
* Xray: outbound is SOCKS stub → xray socks-in → vless → xray vless-server
  (third process). **Access-log assertion** proves the path.
* Failover: dead candidate fails verify → alive candidate wins.
* Crash: `taskkill` the engine → classify → restart once → probe OK.
* Leaks: 20 cycles → 0 processes / 0 ports / 0 temp files (externally checked).
* Real-credential tests: env-gated (`NEXUS_E2E_*_URI`), clean SKIP when unset.
