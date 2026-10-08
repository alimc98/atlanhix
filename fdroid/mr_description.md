# MR description — paste into fdroiddata MR !51694 (after retitle to "New app: Atlanhix")

## Abstract

Atlanhix is a production-grade, ad-free, tracking-free proxy/VPN client for
Android, Windows and Linux. Users import a node link (VLESS incl. XHTTP/REALITY,
VMess, Trojan, Shadowsocks, Hysteria2, TUIC, WireGuard/AmneziaWG, MasterDNSVPN),
pick an engine, and connect with one tap.

Why I wrote it: most open-source proxy clients cover one protocol family or one
engine. Atlanhix unifies sing-box and Xray-core behind one UI with a
capability-aware engine matrix that picks the right core per protocol, plus a
health-scoring / smart-switching / fragmentation ladder layer built for
unstable, censored networks.

Screenshots and icon live in the upstream repo under
`fastlane/metadata/android/en-US/images/` (dashboard + stats).

## Checklist

### Policy

- [x] The app complies with the inclusion criteria.
- [x] The original app author has been notified — I am the author
      (https://github.com/alimc98).
- [x] The upstream app source code repo contains the app metadata in a Fastlane
      folder structure: `fastlane/metadata/android/en-US/` with
      title/short_description/full_description, icon, phoneScreenshots and
      changelogs/21.txt (en-US included).

### Docs

- [x] Read the guide (first contribution).
- [x] Metadata follows the best practice in the templates.
- [x] Metadata validated with `fdroid readmeta` / `fdroid lint` /
      `fdroid rewritemeta` (fdroidserver 2.4.5) — clean.
- [x] Read the Quick Start Guide.

### Merge Request Setup

- [x] Title follows "New app: app name" format.
- [x] Fork (gitlab.com/alimc98/fdroiddata) is public; branch `com.atlanhix.app`
      is not protected.
- [x] No related fdroiddata/RFP issues exist yet; only one app in this MR.

### Metadata

- [x] `metadata/com.atlanhix.app.yml`, valid YAML, LF line endings.
- [x] No summary/description/images duplicated here — provided upstream.
- [x] Releases are tagged (`v0.6.6`); auto update enabled:
      `AutoUpdateMode: Version v%v`, `UpdateCheckMode: Tags`.
- [x] Issue tracker and author contact present in metadata.
- [x] `AuthorName` added.
- [x] External repo handling: the sing-box core (libbox, v1.14.0) is compiled
      from source inside the recipe via gomobile — no external AAR/repo
      dependency; the committed prebuilt `android/app/libs/libbox.aar` is
      removed at build start. Recipe was verified locally, including the
      required `-ldflags=-checklinkname=0` for sing-box's pidfd linkname.
- [ ] Reproducible builds: **not enabled** — Flutter + gomobile toolchains are
      not byte-reproducible in practice; reason stated here as required.
- [x] Only the latest version (0.6.6 / versionCode 21) is kept; no disabled
      versions; `commit` is the full hash
      `068e0237b7cf418cda83a6f99594d3ae03d548ee`.

### Pipeline

- [x] All pipelines pass.
- [x] Reports tab: no warnings/errors outstanding.
