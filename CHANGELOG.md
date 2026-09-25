# Changelog

## v0.4.3 — 2026-09-26

Full fix pack for the three user complaints reported after the 0.4.2 install
(test-all all-red, the stuck "Atlanhix core" notification, connect sometimes
not landing on the first tap). Every fix was reproduced from on-device
evidence (Mi 9T / adb logs) and is covered by the updated test suite
(281/281 green, `flutter analyze` clean).

### 1. "Test all nodes" showed × for every node

Root causes found on device (probe API answered a real 598 ms by hand while
the UI painted × on all nodes):

- **Probe engine restart under the running sweep.** The sweep tests chunks
  of 6 nodes; a chunk whose node set differed from the loaded one RESTARTED
  the transient Box mid-sweep (device log: two "probe engine UP :9090"
  lines one second apart, `nodes=6` then `nodes=5`). Every in-flight delay
  test died against the swapped config and the whole list went red.
  Fix: the engine now grows its UNION (missing node ids are merged in) and
  reuses a superset as-is — a restart only happens when the engine is
  actually down. Concurrent starts share one in-flight future.
- **Xray-owned nodes were never really testable.** They have no sing-box
  outbound by design; the probe config skipped them and the measurement was
  a lie. Fix: the probe boots ONE real `:xray` child carrying every
  Xray-owned node of the batch (renamed unique tags, one socks inbound per
  node on its own free port, never 2080) and stops it with itself. Node
  hostnames are bootstrap-pinned through the clean-resolver pool first, so
  the poisoned carrier DNS cannot fake another red. Child failed / binary
  absent → the node is answered honestly `engine-off`, never a fake
  timeout.
- **Honesty plumbing.** A Clash-API 404 (`Resource not found` — tag absent
  from the RUNNING config) is no longer misread as a 5 s timeout: the
  client returns null and the sweep reports `engine-off`. The sweep also
  re-checks the live table per node instead of assuming the whole chunk
  landed. The stale live-engine API client cache is validated per use, so
  a disconnected engine no longer masquerades as dead nodes.

### 2. The "Atlanhix core" notification survived closing the app

- `XrayCoreService`: foreground promotion moved out of `onCreate` (merely
  constructing the service for a STOP posted the pill); fail paths now
  drop the notification and stop; OS redelivery with a null action stands
  down instead of running an empty foreground service.
- `AtlanhixVpnService`: `onDestroy` fully removes the foreground pill,
  `onTaskRemoved` runs the complete shutdown path (remove + stopSelf),
  and a sticky restart without a pending config stops instead of flashing
  a notification with no engine.

### 3. Connect sometimes failed from the first tap

- **`LIBBOX_START_FAILED: initialize cache-file: timeout`** (device log
  19:57): the transient probe engine and the VPN engine share the main
  process, and both libbox instances fought over ONE `cache.db`. The probe
  Box now gets its own libbox working dir, and the connect path stops the
  probe engine (and its `:xray` child) before booting the tunnel.
- **Config-generator regression** (this pack's own earlier change, caught
  on device): a LIVE `socksUpstream` port must still emit the socks stub —
  skipping stubs unconditionally broke every Xray-owned connect with a
  native sing-box outbound. Verified by tests on both shapes (probe with
  no upstream → node dropped honestly; session with a live port → stub).
- **First-tap Xray race**: the connect flow waits up to 1.5 s for the
  `:xray` runtime warm-up handshake instead of failing instantly with
  `XRAY_RUNTIME_UNAVAILABLE`.

### Tooling

- `tool/warp_probe_live.dart`, `tool/wg_probe_validate.dart`,
  `tool/udp_control.dart`, `tool/warp_e2e_config.dart`: on-device
  validation harnesses used to reproduce and verify the fixes above.
- Debug build logs and APK chunk artifacts are intentionally not committed.

**Tests:** 281/281 green · `flutter analyze`: 0 errors
**APK:** `build/app/outputs/flutter-apk/app-release.apk` (64.6 MB)
