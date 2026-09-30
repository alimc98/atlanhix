# Changelog

## v0.5.5 — the planet that actually renders + instant-connect ladder

### The globe (user report: "همیشه نمی‌آید، اگر هم بیاید خیلی کم‌رنگ است")

- **ROOT CAUSE — shader never compiled**: `planet.frag` declared
  `#version 460 core` (desktop GLSL). Flutter's FragmentProgram only
  accepts ES 3.20 — every device failed the compile, fell into the CPU
  catch and threw the baked land mask away with it. Now `#version 320 es`:
  the GPU planet is real on device.
- **Reference look** (dark rocky planet sheet): hard WHITE rim light
  anchored upper-left (a second rim-key lobe, not just a uniform edge),
  domain-warped fbm relief with raked bump shading, brighter warm
  night-lights, inner atmosphere ring + tighter halo, planet 30% larger
  in frame.
- **No more double-dimming**: the backdrop's Opacity(0.5) wrapper is gone
  and the top vignette eased from 0.86 to 0.42 — the rim-lit limb shows
  through the hero.
- **Fallback planet upgraded**: keeps the baked land mask even when the
  shader fails; real continents scroll with yaw (ColorFilter cutouts from
  the mask's land/lights channels), stronger rim sweep.

### The connect speed (user report: "کانکت دیر وصل می‌شود")

- **Instant phase**: the controller flips to STARTING on the tap itself —
  spinner, "Connecting…" and the globe wake up immediately.
- **Early handover ladder**: the pre-connect sweep no longer blocks the
  handshake. The first healthy measurement (or a healthy node already in
  the health store) hands the node to the tunnel start immediately; the
  hard budget dropped from 9 s to 3.5 s. The sweep keeps measuring in the
  background and the armed Smart Switch migrates when a materially faster
  node lands (margin logic untouched).
- The dial lands on the EXACT ladder pick — no re-ranking that could
  undo the early handover. Manual node selection semantics unchanged.

### The dashboard

- **GEO ROUTE × TOTAL TRAFFIC collision — fixed for good**: the two chips
  now share ONE hero-top row (LayoutBuilder); GEO ROUTE gets exactly the
  width left over. Two independent budgets can never sum past the hero
  again.
- **Recommended Nodes section removed from the dashboard** (user request);
  node selection lives in the Nodes tab.

## v0.5.4 — the signature 3D globe (GPU planet + live connection route)

### The planet

- **Real GPU 3D globe** (`assets/shaders/planet.frag`): cinematic dark
  planet — rocky fbm relief, day/night terminator, cool-white rim light,
  state-driven atmosphere, baked night-lights, hairline land dots. The
  six-token brand palette only; no neon.
- **CPU fallback**: if the fragment program cannot load (old GPU / test
  env), the same composition renders procedurally — the visual never
  breaks.
- **Land mask from existing data**: the planet's continents and city
  lights are baked at runtime from the same world-atlas point cloud the
  point globe uses (512×256, ~2 ms, one-shot). Zero new assets.

### The connection

- **Great-circle route** user → node via true slerp, elevated by route
  length (Tehran→NYC flies higher than Tehran→Baku); draws on during
  connecting, stays with a subtle glow while connected.
- **Packet flow**: four faint light particles travel source → destination
  once connected; both endpoints pulse.
- **Smooth destination morph**: switching nodes (London → Hong Kong →
  Singapore) slides the pin along the great circle — never teleports.
- **Honest geography**: destination = the tunnel's real exit fix once
  connected, the node's own location before that (host geolocation,
  then country hints in the node name/host: "DE-01", flag emoji, TLD).
  No hints → no pin — the globe stays calm instead of inventing one.

### The app around it

- The globe is the app background on every tab (v0.5.2's contract kept);
  the dashboard hero rides it unchanged.
- Tapping a node moves the destination immediately — selection previews
  before connecting.
- Slow cinematic rotation (≈60 s/rev), horizontal drag to spin, tilt on
  vertical drag, inertia, auto-resume; ticker fully stops when the app
  backgrounds. Steady repaints throttled to 30 fps.
- Visual state machine maps 1:1 from the real connection phases — no
  invented VPN state; error stays premium (a breath on the rim, not a
  red screen).

### Engineering

- New pure-math module `lib/presentation/globe/globe_geo.dart` (slerp,
  distances, arc lift, country heuristics) — 15 unit tests.
- 28 new tests total (globe math + widget states + backdrop mapping);
  suite: 405 green. `flutter analyze` 0 errors; `flutter build apk`
  verified with the shader bundled.

## v0.5.3 — mihomo as the standalone third engine + user-reported fixes

### mihomo (Clash.Meta) engine

- `MihomoConfigGenerator`: full Xray↔mihomo translation including
  `extra=<json>` links — xmux → reuse-settings, downloadSettings →
  download-settings, x-padding-*, transport family 1:1.
- `MihomoRuntime`: child process with readiness through its own Clash
  API (smart switch/delay tests work unchanged against it).
- Android: `:mihomo` service alongside `:xray`, libmihomo.so arm64
  bundled; Windows: mihomo.exe in the release zip, BinaryManager
  aliases `clash-meta`.
- Settings → Engine picker: Auto / sing-box / Xray / mihomo (per-node
  pins still win).

### User-reported fixes

- **Sticky manual pick**: a manual node selection survives disconnects
  AND keeps the smart switch OFF across them — the ladder no longer
  re-arms over the user's head; only an explicit enable hands back to
  auto (`test/manual_selection_hold_test.dart` pins this).
- **Perf**: globe tickers throttled, tab bodies moved to IndexedStack —
  LiveMonitor/CPU/RAM/battery and speed/latency readouts no longer remount
  on tab switches; ladder progress stream throttled (250 ms).
- **UI**: traffic/route chips cap their width (no more collision on
  narrow phones); nav labels scale instead of truncating ("das…").

## v0.5.2 — smart-switch pro pack + live ladder readout + Windows cores-path fix

### Smart switch, the professional shape (user dial-in)

- **Percent margin (default 30%)**: a challenger node must beat the
  incumbent's REAL measured delay by ≥N% (plus the legacy ms floor)
  before the tunnel migrates — jitter-driven ping-pong is dead. All
  three dials live in Settings and apply to a running ladder.
- **Active-node recheck every 30 s**: one URL test of the server in use;
  a dead incumbent is abandoned within one cycle.
- **Others-rescan every 10 min**: a full REAL-delay batch over the rest
  of the pool through the live engine.
- **Pre-connect ladder**: with the switch ON and no explicit pick, the
  first connect measures the WHOLE runnable pool (one transient engine
  boot, ≤9 s) and lands on the fastest healthy node.

### First-connect reliability (Android)

- The transient probe engine and the VPN engine share one libbox working
  dir; they now take turns via a probe idle-latch (stopLocked
  handshake) + a settled stop, and the tunnel probe retries 3× inside
  the same startup budget — the "first tap fails, second works" report
  is fixed at the source.

### Live dashboard

- **GEO ROUTE globe**: home/exit IP geolocation, map→sphere morph, the
  Iran→Romania great-circle arc, and the globe as the app backdrop.
- **Live ladder readout**: while the pre-connect ladder counts through
  the pool, the hero word AND the GEO ROUTE chip show per-node progress
  ("testing 5/11 · 180 ms") — real landed measurements, not a spinner.
- Per-node up/down usage, per-subscription node filters, clipboard
  import, live monitor (battery/temp/CPU/RAM), MTU optimizer, animated
  tab slide + expressive nav pill.

### Windows cores path fix ("فراخوانی هسته‌ها مسیر اشتباه بود")

- `resolveCoresDir` probed exactly ONE layout (`<exe>\cores\windows-x64`)
  and fell back to a CWD dir that exists nowhere near the exe — any
  other placement (engines next to the exe, `cores\` without the
  platform nesting, `bin\`) read as `binaryMissing`. Every common layout
  is now probed for a dir that actually CONTAINS engines, the manager
  accepts a runtime override, and every miss logs the full candidate
  list for one-glance diagnosis.

## v0.5.1 — Windows identity, Play Protect round 2, desktop UI sync

### Play Protect, round 2 (user report: still blocking 0.5.0 installs)

- The 0.5.0 builds carried the `com.example.nexus` application id — the
  classic template marker and a strong negative signal in Play Protect's
  sideload heuristics — and the "hasn't seen an app from this developer
  before" banner is ALSO shown for ANY first build from a brand-new
  signing key. Both fix with exposure/time, but the id is now removed
  from the equation: the app ships as **`com.atlanhix.app`** (Kotlin
  source tree moved; service action strings and diag paths follow).
  Requires a FRESH INSTALL (new app identity, old 0.5.0 will not
  "upgrade" over it — that is expected).
- Verified end-to-end: the CI-built APK downloads and installs
  (signature SHA-256 `23d9c819…` matches the local keystore exactly).

### Windows desktop gets its own identity (user request)

- The executable was the Flutter template name **nexus.exe** — now
  **atlanhix.exe** (BINARY_NAME + window title + FileDescription/
  InternalName/OriginalFilename/ProductName version resources).
- The app icon is now the ATLANTHIX wordmark on the app's dark rounded
  tile (multi-resolution ICO built from the brand PNG).
- The rail brand lockup is the NEW branding: intro wordmark + theme-
  aware logotype (the old stacked monogram block is gone).
- The circular white ConnectButton that floated at the rail's bottom is
  REMOVED — the dashboard power pill is the single connect control on
  every platform, matching mobile (v0.4.7 decision, now desktop too).
- The Windows zip now lands next to the APKs automatically: a new
  tag-driven GitHub Actions workflow builds the v7a/v8a/universal APKs
  (release-keystore injected from repo secrets) AND the Windows x64 zip
  (with official sing-box/Xray cores bundled) on every `v*` tag.

## v0.5.0 — Boot 2.7× faster (measured), UI-lag fixes, subscription edit + auto-update, notification sync

### Release-signed APKs fix Play Protect "app blocked" (user report)

- The release builds were signed with the ANDROID DEBUG KEY — Google
  Play Protect flags sideloaded debug-signed packages
  ("app blocked / to protect your device"). A dedicated upload keystore
  (`android/app/atlanhix-release.jks`, 25-year validity) signs every
  release build now; credentials ride `android/key.properties`
  (gitignored — CI/fresh clones fall back to the debug key so builds
  still complete).
- Because the signing key changed, upgrading OVER an old install
  requires uninstall first (Android rejects signature mismatches).
- A **universal APK** (both arm64-v8a + armeabi-v7a in one file,
  versionCode 7) ships next to the per-ABI splits (v7a=1007, v8a=2007).

### UI fixes (user reports)

- The appbar wordmark read ~50% too large on the phone — halved.
- Settings → About showed a hardcoded 'Atlanhix 0.4.1' regardless of
  the installed release — now derived from the same compiled-in
  constant the update checker uses (`Atlanhix 0.5.0 (build 7)`).

### Cold boot cut from ~3.2 s to ~1.2 s — MEASURED, not guessed (user report: "برنامه خيلي دير بوت ميشه")

- A per-stage stopwatch now logs every bootstrap phase under the `boot`
  tag (logcat-visible), so future regressions are measurements. The
  device numbers that drove this round:
  - `profiles.load` **2.8 s** → the ONE-TIME Keystore/EncryptedSharedPreferences
    init inside flutter_secure_storage 9.x, paid on the process's first
    vault call. Fix: the profile load is now TWO PHASES — the store decode
    runs inline (no vault touch), the batch secret resolution moved to a
    deferred pass that fires right after the first frame (`endOfFrame` +
    a microtask). Profiles render with `@vault:` tokens in place of
    secrets (nothing on screen ever shows them); `connect()` awaits the
    deferred pass first, so a tap within the first seconds simply waits
    out the already-started Keystore init. Deferred cost measured:
    **0.3–1.6 s post-paint, off the launch path**.
  - `warpRepo.load` **0.65 s** → same Keystore cost via the WARP vault
    reads. Fix: store-only fast load + the two secrets ride the same
    deferred pass (WarpAccount rebuilt with resolved values). Stage now
    **41 ms**.
  - Section loads (`subscriptions/chains/routing/settings`) run
    **in parallel** instead of six sequential awaits.
- Result on the test device (Xiaomi, debug build, warm-ish): bootstrap
  total **3232 → 1191-1200 ms** (4 consecutive runs), first frame
  `Displayed` +2.4–3.8 s (was +4.0–4.6 s). Release/JIT-less builds boot
  substantially faster still.

### In-app lag (user report: "خيلي لگي كار ميكنه")

- **Nodes tab repainted per sweep record.** Every scheduler result
  rebuilt + re-filtered + re-sorted the whole list — a 40-node sweep
  fired 40 full list rebuilds per second. Records now coalesce into ONE
  post-frame repaint per burst.
- **Hero moon artwork decoded at full 1536×1024** and GPU-downscaled to
  ~1/4 of those pixels every app start; decode now caps at 1200 px
  width (`cacheWidth`), cutting ~6 MB of decode + upload for pixels
  that were thrown away.
- (Earlier this release, same thread: the 9 s traffic-graph animation no
  longer runs hidden/off-tab; the connected-watcher drops to 15 s in
  the background; the dashboard repaints per sweep record only for the
  active node's chip.)


### Subscription auto-update actually works + per-subscription interval (user request)

- `SubscriptionService.dueNow()` existed since v0.4 but NOTHING ever called
  it — auto-update was dead wiring. A foreground pump now ticks every 60 s
  (`startAutoUpdatePump`, wired in bootstrap behind the first await
  boundary so the catch-up fetch never contends with boot I/O) and
  refreshes due subscriptions serially. A process killed for a day
  catches up on the next open (overdue `nextUpdate` fires on the first
  tick). Deliberately NO background scheduler: no work_manager battery
  cost, the next open is the catch-up point.
- A never-successful subscription retries on a 5-minute floor so a dead
  URL cannot hammer the radio every minute.
- Edit dialog on every subscription card (pencil icon): name, URL,
  auto-update toggle and the update interval in MINUTES (10/20/… as
  requested). A changed URL resets the etag + recorded error, marks the
  sub `neverUpdated` and triggers an immediate refresh; an unchanged URL
  just saves. The card shows the interval + next due time under the
  traffic bar while auto-update is on.
- v0.5 BUGFIX: `SubscriptionRepository._subToJson` never persisted
  `screenXrayOnly` / `screenRisky` / `status` although the service sets
  them on every update — screening counters and the failed/ok badge
  silently reset on every app restart. Persisted now (and `status` also
  round-trips through `Subscription.fromJson`).

### New intro artwork (user request)

- The intro screen now shows the user-provided ATLANTHIX wordmark
  (`assets/brand/intro.png`, transparent background over the app's
  `#0A0B0E` ground) replacing the previous `intro.jpg` artwork.
- The five nav tab icons are the user's CLEANED tiles, supplied as a dark
  set and a light set (`nav_*_dark.png` / `nav_*_light.png`). The shell
  picks the set from the ambient theme brightness. The user's "light"
  source files carried WHITE glyphs (invisible on the light theme's
  white surface), so the light set was programmatically tinted to the
  light theme's ink (#101216) preserving the alpha shape — verified over
  both backgrounds before shipping.

### Notification now matches the REAL VPN state (user report)

- Root cause: the native state machine NEVER reaches CONNECTED on its own
  — Dart flips to connected only after a REAL probe through the tunnel
  (§5) — so the foreground notification froze on "Validating tunnel…"
  for a session that was fully up (and "Stopping…"/"Failed" cases showed
  stale text until revoke/stop).
- Fix: Dart mirrors its probe verdicts to the service via three new
  platform-channel methods (`notifyConnected` / `notifyDisconnected` /
  `notifyDied`); the service (same process — no `android:process`) keeps
  a live static instance and updates its notification immediately.
  Best-effort fire-and-forget on the Dart side: desktop and tests have
  no channel and the state machine can never break on a mirror miss.

### Battery + lag (user request)

- **Traffic graph animation ran forever, even hidden.** The 9 s hero
  `AnimationController..repeat()` never stopped — unlike Timers,
  controllers ignore app lifecycle. `TrafficGraph` is now a lifecycle
  observer (stop on paused/hidden/detached, resume on resumed) and the
  dashboard wraps the hero in `TickerMode` outside
  connected/validating.
- **Native watcher throttled in background.** The connected watcher woke
  the CPU every 2 s around the clock to refresh counters nobody was
  watching. `setWatchCadence` drops it to 15 s while hidden (main.dart
  lifecycle hook) and restores 2 s on resume.
- **Dashboard rebuilt per sweep record.** `_healthSub` called
  `setState` for EVERY scheduler result — a 40-node batch probe
  repainted the whole dashboard 40×. It now repaints only when the
  record belongs to the active node (the chip it feeds).
- **Boot race with Smart Switch.** On resume the ladder armed instantly
  and its first probe storm contended with the first paints; arming is
  deferred 12 s (still cancelled by disconnect/theme changes).

### Previous

## v0.5.0 (unreleased) — Smart Switch fix + full WARP IP-range scan + hero traffic graph + AWG manual-add fix

### Node list shows jitter + success rate (user request)

- The node row's latency cell grew a second line: `±40 ms · 100% up` — the
  stdDev derived from HealthStore's stored variance (ms²) so the number is
  human-comparable against the latency above it, plus the share of OK
  probes in the recent 20-sample window. These are the same composite
  inputs the Smart Switch ladder ranks on (see below), so the list now
  shows every factor behind a migration decision.
- Honesty rules: fewer than 2 samples → jitter omitted (never a fake
  `±0`); a never-tested node renders an empty subline under the `—`.
- `_NodeTile` became public `NodeTile` for testability; the subline
  formatter (`nodeMetricSubline`) is a top-level function with unit tests
  (variance→stdDev derivation, missing-history omission, rate clamping)
  and three widget tests (fail+ok mix, never-tested, measured-steady).
  Suite 315/315 green.

### Smart Switch now ranks by latency + jitter + success rate (user request)

- The ladder's ranking was latency-only, so a fast-but-flaky node outranked
  a slower rock-solid one and failure history was invisible. The new
  composite score (`SmartSwitch._score`), healthy-first as before:
  latency 0–1000 pts (last → avg → 5000 ms fallback), success rate
  0–500 pts (share of OK probes in the recent 20-sample window), jitter
  0–200 pts — HealthStore stores the recent VARIANCE (ms²), the score
  consumes its square root so the penalty stays latency-comparable, and a
  node with no history yet scores the neutral middle (never a phantom
  perfect-stability bonus).
- The `Smart Switch tolerance` margin now rides the COMPOSITE score:
  a steadier challenger (less jitter / better success rate) needs a
  smaller latency lead to steal the connection; the margin keeps its
  latency-shaped intuition (score points vs ms are in the same order of
  magnitude).
- Switch logs now carry the full decision context: `lat=…, jit=…, ok=…%,
  score=…, margin=…`.
- Tests: `test/smart_switch_composite_score_test.dart` (spiky-vs-steady,
  flaky-vs-reliable, composite-margin migration and hold, legacy
  invariants). Suite 309/309 green.

### Manual-add AmneziaWG 3.1 nodes lost their parameters (user report)

- **The AWG form never rendered.** The whole WireGuard/AmneziaWG section
  (keys, Jc/Jmin/Jmax, S1..S4, H1..H4, I1..I5, Hpk, padding, dialect
  flags) was nested INSIDE the `_isTcpFamily` spread (vless/vmess/trojan)
  in the node editor — a WireGuard protocol never satisfies that, so
  hand-adding an AWG 3.1 node offered NO parameter fields at all. The
  block is top-level now, gated on the WireGuard protocol only.
- **Editing an AWG node wiped its params.** `_save` built a FRESH empty
  `AmneziaParams` from the (never-rendered) controllers on every save.
  With the form fixed the controllers carry the stored values, and the
  form-not-exposed fields (masquerade sugar, unknown `extra`) are now
  carried over from the stored profile explicitly. Explicitly cleared
  fields DO clear — the form is the source of truth.
- `AmneziaParams.copyWith` added (null = keep) for the carry-over.
- `AppDependencies.bootstrapForTest()` — a minimal temp-store +
  in-memory-vault composition for editor tests (no engines/sockets).
- Regression tests: `test/node_editor_awg_test.dart` (form renders for
  WireGuard, filled fields store a full AmneziaParams + AmneziaWG core,
  edit-save keeps masquerade/extra, explicit clear clears). Suite
  295/295 green.

### Dashboard: hero traffic graph (user mockup)

- New `TrafficGraph` widget replaces the hairline speed graph in the
  dashboard hero: layered glass waves (download = silver with an
  emerald rim light, upload = green, plus softened depth echoes behind),
  glow-cored edge lines, a needle-bar "burst" at the NOW edge, twinkling
  specks and a floating glass pill that rides the strongest crest with
  the current speed (↑/↓ arrow glyph drawn in-path, no icon font).
- Smooth-motion pipeline: 5-tap [1 2 3 2 1]/9 kernel turns the spiky
  per-second counters into rolling hills, midpoint-cubic ribbons, and a
  slow sine relaxation on a repeating 9 s phase animator so the scene
  breathes even on an idle link. The burst reads the RAW last sample
  (smoothing is for the silhouette, not the current speed).
- Same ring-buffer samples as before (no data-pipeline change);
  `SpeedGraph` remains for other callers. Golden test
  (`test/goldens/traffic_graph.png`) + zero-traffic and empty-list
  robustness tests added.

### Smart Switch never switched (device report: "the auto switch does not switch")

- **Stale-incumbent bug.** `SmartSwitch.start(currentId:)` seeded the
  recommendation store one sweep too late: the first evaluation compared
  its fresh winner against the STALE `currentId` parameter and re-elected
  the dead incumbent as "no change". `best` is now seeded synchronously —
  a dead incumbent is abandoned on the FIRST sweep.
- **The card path never subscribed.** `_smartSub` was created only on the
  connect auto-pick path; enabling the switch from the Nodes-tab card
  fired recommendations into the void and the tunnel never migrated.
  Both paths now share one `_armSmart()` that subscribes BEFORE start.
- **Real tolerance field (user request).** New setting
  `smartSwitchMarginMs` (default 60): a challenger must beat the active
  node's latency by this many ms before the tunnel migrates. 0 = any
  strictly-better healthy node wins; a DEAD active node is always
  abandoned regardless of the margin. Editable in Settings → "Smart
  Switch tolerance"; edits live-apply via `syncSmartTuning()` (which also
  fixed the interval field silently re-enabling a switch the user had
  turned off).

### WARP endpoint scan: full IP range (WarpServer coverage)

- The scanner swept 10 hard-coded hosts; it now sweeps the FULL WARP
  class-C networks — 162.159.192.0/24, 162.159.193.0/24,
  162.159.195.0/24, 188.114.96.0/24 (1,024 IPs × 6 ports = 6,144
  candidates) with a real WireGuard handshake, 8-way concurrency, a
  900 ms per-candidate budget and a 30 s whole-sweep deadline + cancel
  button. The best responder is saved as the endpoint override.
- `WgHandshakeProbe.probe` grew an `onSend` hook so the sweep cancels its
  budget the moment the first reply lands instead of waiting out
  per-candidate timeouts sequentially.

Tests: smart_switch_test.dart (switch/beat-margin/dead-incumbent/re-seed),
warp_scan_range_test.dart (probe plumbing). Suite 288/288 green;
analyze clean on the touched files.

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
