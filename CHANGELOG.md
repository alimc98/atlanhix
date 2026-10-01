# Changelog

## v0.6.1 — پریتی ویندوز: همان پنج فیکس روی دسکتاپ

**بار اول وصل نمی‌شود (دسکتاپ):** پروب تونل در ConnectionController هم
کناری‌ها را سری می‌چرخاند (۴ × ۶s = ۲۴s بدترین حالت برای موتور سرد).
حالا موازی‌اند — بدترین راند = کندترین کناری (۶s)، اولین موفقیت برنده،
و خطای نهایی همان آخرین شکست واقعی است (پریتی VpnSession probeTunnel
همان نسخه).

**آپدیت درون‌اپی (ویندوز):** UpdateChecker حالا asset پلتفرم خود را
انتخاب می‌کند — ویندوز ZIP (`Atlanhix-v*-windows-x64.zip`؛ پوشه cores
داخل باندل است، پس همان zip عملا نصب‌کننده است)، اندروید APK. شاخه
ویندوز: دانلود داخل اپ به Downloads (پیشرفت در دیالوگ، استریم HTTP
واقعی) → باز شدن Explorer روی فایل → یک unzip روی نصب قبلی.
دیگر مرورگر/گیتهاب دستی لازم نیست.

**پینگ/سوییت/xhttp/داشبورد:** مشترک بین دو پلتفرم بودند (TcpPinger،
متریکس mihomo، پیل‌ها) — از v0.6.0 روی هر دو فعال‌اند. فقط #۲ و #۳
پلتفرم‌محور بودند که این نسخه پریتی ویندوز را کامل می‌کند.

## v0.6.0 — xhttp روی mihomo، پینگ واقعی، بار اول، آپدیت درون‌اپی

> ۱- توی هسته mihomo کانفیگ xhttp reality به جای xhttp روی tcp می‌رود ·
> ۲- بار اول کانکت می‌زنیم وصل نمی‌شود، بار دوم وصل می‌شود ·
> ۳- آپدیت جدید دانلود نمی‌شود — باید داخل خود اپ دانلود و نصب شود ·
> ۴- فونت total traffic و geo route بزرگ است و کنار هم جا نمی‌شوند ·
> ۵- هنوز پینگ‌ها بالاست

**۱. xhttp→tcp (ریشه واقعی):** باینری mihomo باندل‌شده اندروید v1.19.31
است و xhttp را کامل پشتیبانی می‌کند؛ مشکل از پارسر Clash YAML بود —
`_transport` فقط ws/grpc/h2/httpupgrade را می‌شناخت و `network: xhttp`
را روی `Transport.tcp` می‌انداخت و کل بلوک `xhttp-opts` (path/host/mode/
xmux/padding) گم می‌شد. حالا xhttp/splithttp → Transport.xhttp،
xhttp-opts خوانده می‌شود و همه فیلدها (به‌همراه dialect لینک Xray و
blob extra=) در rawParams حفظ می‌شود؛ round-trip پارسر→مولد mihomo با
۸ تست پین شد. (فورک هسته لازم نبود.)

**۲. بار اول وصل نمی‌شود:** بودجه probe تونل با کلاک startup (۱۵s)
کپ می‌شد در حالی که حلقه warm-up داخلش ۳ راند × ۴ کناری × ۸s (تا ۹۶s)
طراحی شده بود — موتور سرد که هنوز upstream را dial نکرده وسط راند اول
کشته می‌شد؛ بار دوم با کش‌های گرم/DNS pin/فرزند زندهٔ mihomo فوری پاس
می‌شد. حالا کناری‌های هر راند «موازی» می‌چرخند (بدترین راند = ۸s نه
۳۲s) و probe بودجه مستقل ۳۲s دارد (probeTimeout ≠ startupTimeout).

**۳. آپدیت درون‌اپی:** روی اندروید دیگر مرورگر/گیتهاب در کار نیست —
کانال `dev.atlanhix/updater` با DownloadManager فایل APK را داخل سندباکس
اپ دانلود می‌کند (پیشرفت ۰–۱۰۰٪ در دیالوگ) و بعد سیستم اینستالر را روی
فایلfire می‌کند (FileProvider + ACTION_INSTALL_PACKAGE؛ پرمیشن
REQUEST_INSTALL_PACKAGES اضافه شد). دسکتاپ همان جریان قبلی بازکردن URL
را دارد.

**۴. پیل‌های داشبورد:** total traffic و geo route فشرده شدند — پدینگ
۱۲/۹→۹/۷، آیکون ۱۸→۱۴، لیبل ۹→۸، مقدار ۱۶→۱۳px — تا کنار هم جا شوند.

**۵. پینگ v2rayNG-سبک:** TcpPinger جدید — TCP handshake خام به
server:port (بدون موتور/تونل/URL). دکمه تست دو فاز شد: فاز ۱ tcping همه
نودها (سریع، ستون را فوری پر می‌کند)، فاز ۲ تست URL واقعی فقط برای
نودهای زنده (آمار Smart Switch دست‌نخورده). ستون لیست tcp-first نشان
می‌دهد؛ آمار URL از TCP ایزوله شد (lastTcpMs جدا در HealthStore —
نشتی قبلی `latencyMs ?? handshakeMs` حذف شد).

## v0.5.9 — the five user-reported blockers

> ۱- کره زمین توی نسخه دارک اصلا واضح نیست و خط اتصال کالیبره نیست ·
> ۲- خیلی از کانفیگ‌ها وصل نمی‌شن · ۳- هسته mihomo به همه کانفیگ‌ها وصل
> نمی‌شه · ۴- پینگ کانفیگ‌ها خیلی بالاست (۸۰۰–۱۲۰۰ms اینجا، ≤۱۵۰ms جای دیگر) ·
> ۵- وسط اتصال، تپ روی کانفیگ دیگه کار نمی‌کنه

**۱. کره + کالیبراسیون (دارک‌مود):** overlay پین‌ها/خط‌ها شعاع را
`min(shortestSide·0.60, height·0.60)` می‌گرفت در حالی که شیدر کره را
`R = min(w·0.52, h·0.50)` می‌کشد → پین‌ها و خط لینک ~۲۰٪ بیرون‌زدگی داشتند.
حالا overlay دقیقاً فرمول شیدر را استفاده می‌کند. برای خوانایی در تم
تاریک (پس‌زمینه #0A0B0E) چراغ‌های شب ×۱.۳۰→×۲.۴۰، رُلیف بافت شب
×۰.۵۰→×۰.۹۵ و crush نویز ۰.۲۲→۰.۱۰ شد.

**۲. کانفیگ‌هایی که وصل نمی‌شدند:** کاناری‌های fallback پروب همگی https
بودند (هندشیک TLS داخل تونلِ نیمه‌بوت). کاناری http
(`cp.cloudflare.com/generate_204`) اول زنجیره شد + ریشه‌ی اصلی #۲ همان
متریکس ناقص mihomo (#۳) و گیت‌های v0.5.7/0.5.8 بود.

**۳. mihomo ناقص:** مولد فقط vless/vmess/trojan/ss را ترجمه می‌کرد →
hysteria2/tuic/anytls/shadowtls/socks/http از کانفیگ حذف می‌شدند. متریکس
کامل: hysteria2 (up/down + obfs salamander)، hysteria (auth-str/udp)،
tuic (v4 token یا v5 uuid+password — هرگز هر دو)، anytls، shadowtls
(به‌شکل ss + plugin shadow-tls — تایپ standalone در mihomo وجود ندارد)،
socks5/http. گروه ATX حالا نود انتخاب‌شده را اولِ لیست می‌گذارد (select
به اولین عضو default می‌شود) و ATX-AUTO پروب http خودش را دارد.

**۴. پینگ متورم:** پیش‌فرض تست https بود → هندشیک TLS کامل داخل تونل در
هر پینگ (۳–۴×RTT). پیش‌فرض `http://www.gstatic.com/generate_204` شد (همان
روش V2rayNG/NekoBox). دمِ reply SOCKS که با sleep ۲۵ms + blind read جمع
می‌شد، حالا دقیق (ATYP→extra 4 / len+2 / 16+2) خوانده می‌شود؛ pollهای ۴ms
→ ۱ms؛ `handshakeMs` (RTT کانکت SOCKS) از `latencyMs` (fetch کامل) جدا شد.

**۵. تپ هنگام اتصال:** `selectNode` وسط اتصال فقط pick را ذخیره می‌کرد و
فلو نود قبلی را ادامه می‌داد. حالا هر تپِ وسط اتصال «برنده» است: مالکیت
attempt با identity عوض می‌شود، فلو قدیمی در گیتِ generation کنترلر و حتی
وسط کاناری‌های پروب‌اش abort می‌شود (بدون stop تونل — جانشین مالکیت را
دارد)، و نود جدید از همان فانل redial می‌شود (سلکتورِ کانفیگ روی نود تازه
default می‌شود). hold پروب-انجین هم ref-count شد تا خروجِ فلو قدیمی
محافظ ریدیل را وسط boot دریوزد. تپ روی نود در حال dial شدن redial اضافه
نمی‌زند؛ تپ وقتی idle فقط انتخاب است.

## v0.5.8 — the connect gate no longer refuses its own connect

> «وقتي كانكت ميزني فقط ميچرخه و وصل نميشه ،‌به هيچ كانفيگي وصل نميشه»

**Root cause: v0.5.5's tap-feedback phase wedged the connect flow it was
supposed to speed up.** v0.5.5 added `markStarting()` — the dashboard flips
to "Connecting…" the instant the user taps, instead of sitting on
"Disconnected" while the pre-connect ladder measures. But that phase
(`starting`) was also a member of the controller's `isBusy` set, and the
controller's own `connect()` opens with `if (isBusy) return false`.

So the actual sequence on every tap was:

1. `VpnSession.connect()` → `controller.markStarting()` → phase = `starting`
2. `_connectProfile` → … → `controller.connect(...)`
3. the gate `if (isBusy) return false` sees `starting` → **silent refusal**
4. the service never starts, no permission dialog, no engine, no probe
5. the UI spins on `starting` forever — for EVERY config, because no config
   was ever attempted

This also explains why the v0.5.7 canary fallback did not cure the report:
that fix (probe honours Settings → Delay test URL, then independent
Cloudflare/gstatic canaries) lives BELOW the wedge. The probe was never
reached, so it had no chance to succeed. The two fixes now compose: the
flow reaches the probe, and the probe judges tunnels honestly.

Fixes:
- `AndroidVpnController.wedgeArmed` — the phases that genuinely mean "a
  previous session owns the tunnel" (preparing/validating/reconnecting/
  stopping). The cosmetic `starting` no longer gates `connect()`; the flow
  re-lands the phase itself (`preparing → starting → validating → …`).
- `AndroidVpnController.resetToIdle()` — every pre-tunnel gate failure
  (`NODE_NOT_RUNNABLE_ON_ANDROID`, `NO_RUNNABLE_NODE`,
  `CORE_NOT_RUNNABLE_ON_ANDROID`, `XRAY_RUNTIME_UNAVAILABLE`, upstream start
  failures, config generation failure, unexpected exceptions) now lands a
  TERMINAL phase instead of leaving the spinner on `starting` forever.
- Regression pins: `starting` must not arm the gate (controller + session
  level), the probe must actually run after a tap, a gate failure must end
  the spinner, and `resetToIdle` must never trample a live session.

## v0.5.7 — connect never succeeds, update never works, clipboard nags

Three user-reported bugs. The first two had been shipped broken for several
releases; the third is new.

### 1. Connect spins forever and never connects (the serious one)

> «وقتي كانكت ميكني فقط ميچرخه و وصل نميشه، به هيچ كانفيگي وصل نميشه»

**Root cause: the tunnel-verification probe had a single hardcoded canary.**
Every "did the tunnel actually work?" check requested
`https://www.gstatic.com/generate_204` — six call sites (five in
`connection_controller.dart`, one in `vpn_session.dart`). That is a
Google-hosted URL, and the app's audience is on networks where it is
routinely blocked or intercepted.

The consequence is exactly what was reported. The tunnel comes up fine, the
probe fetches an unreachable canary, `testHttpViaSocksProxy` returns
`ok: false`, and `connect()` throws `ProbeError` and tears the whole session
down. It fails **identically for every config**, because the failure has
nothing to do with the config — only with the canary. Hence "no config
connects".

Fixes:
- The probe now honours **Settings → Delay test URL** first. That setting
  already drove the node-list tester and Smart Switch, so a user who had
  already set a reachable URL was still failed at the final gate.
- On failure it falls back through independent canaries
  (`cp.cloudflare.com`, then gstatic **last**) and passes if any answers.
  One blocked host can no longer fail every node at once.
- The same fallback now applies to the monitor, the switch re-verify, the
  crash-recovery verify, the fragment-ladder re-probes, and the Android
  3-attempt warm-up loop.

### 2. Update prompts forever, and Download does nothing

> «نسخه برنامه بروز نميشه و الان كه نسخه جديد روي گيت هاب اومده همش پيام
> آپديت ميده و وقتي دانلود رو ميزني هيچي نميشه»

Two independent defects.

- **`kAppVersion` had drifted to `0.5.1+8`** while pubspec was at 0.5.5. The
  checker compared every GitHub tag against a version no shipped binary
  ever had, so it reported an update on **every launch, forever**. Corrected
  to 0.5.7+13, and a new test (`app_version_consistency_test.dart`) now
  **fails the build** if the constant and pubspec ever disagree again —
  that drift is what let this survive five releases unnoticed.
- **Download did nothing on desktop.** The button called `openUrl` on the
  `dev.atlanhix/vpn` channel, which is implemented *only* by the Android
  host. On Windows/Linux that threw `MissingPluginException`, swallowed
  into a log line. Now: native channel → `Process.run` of the platform
  opener (`start` / `xdg-open` / `open`) → and if even that fails, a
  snackbar shows the URL with a copy button instead of doing nothing.

Also fixed here: the **Windows zip was failing CI on every release since
v0.5.4**. The workflow pinned
`mihomo-windows-amd64-v1.19.31.gz`, which 404s — MetaCubeX ships `.zip`
archives, not a bare `.gz`. The step now resolves the latest release's asset
by name pattern, so a new upstream tag cannot break the build again.

### 3. Any clipboard content was offered as a subscription

> «هر چيزي توی كليپ بورد باشه رو هي ميخواد add subscribe كنه در صورتي كه
> اصلا ساب نيست»

The clipboard is read on **every app resume**, and the test for "is this a
subscription?" was merely *"is it an http(s) link with a host?"* — which is
true of every URL ever copied. A news article, a Telegram invite, a GitHub
link: all offered as a subscription.

`classify()` now requires a URL to actually **look like** a subscription:
a known provider path (`/sub`, `/subscribe`, `/api/v1/client/subscribe`) or
a token query key (`token=`, `uuid=`), no fragment, no known social/host
blocklist hit, and — for the opaque-token shape — a bare single-segment
path. Bare origins and prose-embedded links are rejected. Deliberately
conservative: a false negative costs one manual paste, a false positive nags
the user on every resume.

### Verification

`flutter analyze` 0 errors · **422 tests passing** (was 417; +5 new for
these three bugs) · debug APK builds. **Not verified on a physical device**
— the connect fix is reasoned from the code and covered by unit tests, but
whether a given node's tunnel truly carries traffic can only be confirmed on
a real network.

## v0.5.6 — leak & crash sweep: the long-session audit

No new features. A full-project review turned up three crash-class defects
and a dozen leaks that only showed up after the app had been running for a
while — exactly the class of bug that makes a VPN client feel "broken after
a few hours".

### Crashes

- **SOCKS probe leaked its socket on 5 of 7 exit paths**
  (`core/health/latency_tester.dart`): only the success path and `catch`
  closed the `RawSocket`. The five early `return`s (write failed / greeting
  rejected / CONNECT failed / request write failed) bypassed both — and a
  `return` is not a throw, so `catch` could never clean up. Those are the
  branches a *degraded* tunnel takes, i.e. the 30 s active-node monitor hit
  them continuously and leaked a socket per probe. Now closed in a
  `finally`.
- **Clipboard import could crash on a deactivated context**
  (`nodes_screen.dart`, `subscriptions_screen.dart`): `Clipboard.getData` is
  a platform-channel round trip; one branch reached
  `ScaffoldMessenger.of(context)` with no `mounted` guard while the other two
  branches in the same function had one. Worse in subscriptions, where the
  context is the `StreamBuilder` builder's rather than the State's.
- **`RangeError` in the per-app routing list** (`apps_routing_screen.dart`):
  the empty-name fallback sat *after* `.characters.first`, where it was dead
  code (`toUpperCase()` is non-nullable) — so a blank app label (managed /
  OEM work profiles) threw inside the `ListView` item builder.

### Leaks that grew with use

- **Engine log collectors** (`singbox` / `xray` / `external` / `mihomo`
  runtimes): stdout/stderr subscriptions were discarded, so every connect,
  restart, fragment-ladder rung and `recoverEngine` stacked another live pair
  holding the `ManagedProcess`, its controllers and (through the closure's
  capture) the whole runtime. Now cancelled on `stop()` and before
  re-collecting.
- **`ClashApiClient` orphans**: the throwaway probe in mihomo's
  `_waitApiReady`, every non-success path of `probe_engine._startWith`,
  `probe_engine.stop()`, and two sites in `dependencies`. Each owns a lazily
  built `HttpClient`.
- **Clean-DNS client** (`core/net/clean_dns_client.dart`): closed only on
  `onDone`/`onError`, so a caller-side `.timeout()` — which subscription
  fetch and update-check both use, and which is the *expected* failure mode
  on the target networks — orphaned it. Now also closes on send-throw and on
  `StreamController.onCancel`.
- **Missing `dispose()`**: `logs_screen` (permanent listener on the
  app-lifetime `Logger`, each retained listener copying up to 2000 lines per
  log line), `nodes_screen` (repository change stream), `warp_chain_card`
  (no `dispose()` at all, plus 22 undisposed dialog controllers),
  `routing_editor_screen` (`TabController`, and two controllers that were
  fields on *StatelessWidgets* — a fresh one per rebuild, structurally
  impossible to dispose; both are now Stateful), `dns_scan_screen`,
  `routing_diagnostics_screen`.
- **Unbounded maps**: `clean_dns_client._pins` checked its TTL but never
  evicted expired entries; `HealthStore.reset` had *no caller anywhere*, so
  nodes dropped by a subscription refresh kept their stats and 20-record
  history forever. Added `retainOnly`, wired into the refresh path.

### The globe (carried over from the v0.5.5 shader work)

- **Shader time was the wall clock** — it jumped backwards on an NTP
  correction, popped every 100 s as the modulo wrapped, and made every frame
  non-deterministic. Now accumulated from the ticker's frame delta.
- **Route didn't retract on disconnect**: `disconnecting` counted as
  "route visible", so the arc stayed at full strength while the tunnel was
  already going down. Now fades; `error` deliberately keeps it.
- **Every animation rate was frame-rate dependent** (`dt` hardcoded to
  1/60): a 120 Hz phone ran the globe at double speed and the connect
  animation at double speed. Now derived from the ticker's real delta, with
  rates expressed per second.
- **`FragmentShader` was never disposed** — one leaked GL program per globe
  rebuild.
- **Shader was washing the planet pale**: `exp(-max(r - R, 0) / …)` is
  exactly `1.0` inside the disc, so the "atmosphere" halo added full-strength
  fog across the whole planet; and the key light had `z = -0.30`, pointing
  *away* from the camera, leaving the terrain unlit. Rim crescent narrowed
  to a tight limb ridge, the leftover point-cloud dot grid removed, and the
  source pin brought back to the brand palette (it was mint green).

### Diagnostics

- `android_vpn.dart`: a start generation the system service never
  acknowledged and a genuinely slow engine both reported the same generic
  `engineNotReady`; the two are now distinguished.

### Verification

`flutter analyze` clean of errors (187 pre-existing lint infos, down from
194) · 417 tests passing (up from 408) · debug APK builds. Not verified on a
physical device — the fixes around resource lifetime want a real soak test
(connect/disconnect repeatedly, watch fd count and RSS).

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
