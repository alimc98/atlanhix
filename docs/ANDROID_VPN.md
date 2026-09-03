# Android VPN Runtime — Setup & Architecture (v0.3.0)

> Status: **IMPLEMENTED (architecture complete) / E2E NOT VERIFIED** —
> this repository's build environment has **no Android SDK/toolchain**, so
> no APK was compiled and no on-device test ran. Everything below describes
> the real implemented architecture, not a verified runtime. Do not treat
> Android VPN as "production ready" until the E2E checklist at the bottom
> passes on a device.

## Architecture

```
Flutter (Dart)                         Android (Kotlin)
────────────────                       ────────────────
ConnectionController
  └─ AndroidVpnController              (lib/platform/android_vpn.dart)
       └─ MethodChannel
          "dev.atlanhix/vpn"    ⇄     MainActivity (channel handler)
             prepare / start / stop / state      │
                                                 ▼
                                    AtlanhixVpnService (VpnService)
                                      ├─ state machine (10 states)
                                      ├─ Builder → establish() → TUN fd
                                      ├─ per-app routing (include/exclude)
                                      └─ VpnEngine.start(config, fd)
                                           └─ libbox / sing-box engine
                                                └─ packets → TUN
```

### Components (all in `android/app/src/main/kotlin/com/example/nexus/vpn/`)

| File | Role |
| --- | --- |
| `VpnEngine.kt` | Engine interface + `UnavailableEngine` default that **fails honestly** when no native engine artifact is bundled (no fake TUN, ever) |
| `AtlanhixVpnService.kt` | Foreground `VpnService`: real state machine, TUN establishment, per-app routing, DNS handoff, restart handling, `onRevoke` cleanup, multi-start guard |
| `AtlanhixVpnChannel.kt` | Platform-channel contract (`prepare/start/stop/state`) + VPN permission consent flow |
| `MainActivity.kt` | Registers the channel, launches the consent dialog, routes results |

### State machine (§5)

`IDLE → REQUESTING_PERMISSION → PREPARING → STARTING → VALIDATING → CONNECTED`
with `RECONNECTING` (engine crash / system restart), `STOPPING → STOPPED`,
`FAILED` (every failure path carries a human-readable detail).

**CONNECTED is never set natively.** The service reaches `VALIDATING` when
the TUN fd exists and the engine accepted the config; the Dart controller
then performs a **real HTTP probe through the tunnel** and only then flips
to connected. A `start()` that merely returns cannot fake a tunnel.

### Engine artifact (the one remaining Android gap)

The service needs a real tunneling engine bound behind `VpnEngine`. The
canonical integration is sing-box **libbox**:

1. Obtain/build the libbox AAR for Android
   (`sing-box` publishes `libbox` bindings; follow the official
   `golang`/`gomobile` build recipe of the sing-box project — see
   THIRD_PARTY_LICENSES.md for its license obligations).
2. Add it to `android/app/build.gradle.kts` as an implementation dependency
   (or place the AAR in `android/app/libs/` and add a flatDir repo).
3. Replace `UnavailableEngine` with a `LibboxEngine` implementing
   `VpnEngine`:
   * `start()` → `libbox.NewClient(configJson)` with
     `setTunFileDescriptor(fd)` bound through a `libbox.CommandClient` /
     `BoxService` per the libbox API of the vendored version, wiring
     `onStarted/onFailed/onCrashed/onStopped` to the engine callbacks.
4. Rebuild: `flutter build apk` (requires the Android SDK; see BUILD.md).

No substitute engine is acceptable: a local SOCKS listener is not a TUN and
must never be presented as one.

### Per-app routing (§6)

`includeApps` / `excludeApps` are passed in the start handoff; include wins
over exclude (Android semantics). Packages are validated against
`PackageManager`; unknown packages are skipped and the limitation is
documented. Persistence lives with app settings; the handoff always carries
the current lists (see `AndroidVpnController.buildHandoff`).

### DNS (§7)

The TUN builder receives the resolver list from the generated sing-box DNS
configuration — DNS queries resolve **inside** the tunnel; no plaintext DNS
path exists outside the TUN (all routes, including `::/0`, go through the
tunnel). IPv4/IPv6 addresses come from the same generated config. DNS
failure diagnostics flow through the standard probe error kinds
(`dns | tcp | tls | http | proxy | timeout`).

## On-device E2E checklist (must pass before any "verified" claim)

1. `flutter build apk` succeeds with the libbox artifact.
2. Grant VPN permission → state machine reaches `VALIDATING`.
3. Real HTTP probe through the tunnel succeeds → `CONNECTED`.
4. Kill the engine process (adb shell kill) → `RECONNECTING` → recovered.
5. Revoke VPN from system settings → `onRevoke` → clean FAILED/STOPPED, no
   leaked fd/service.
6. Toggle per-app include/exclude → traffic from excluded apps bypasses the
   tunnel (verified via a "what is my IP" app).
7. DNS leak test (e.g. dnsleaktest.com) shows only the configured resolvers.
8. 20 connect/disconnect cycles → no leaked service instances, no stale
   notifications.
