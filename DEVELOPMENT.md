# DEVELOPMENT

## Layout

```
lib/
  main.dart                 composition root bootstrap
  core/                     primitives, logger, core_detector, configgen,
                            health, scoring, fragmentation, cdn
  domain/                   entities (ProxyProfile, Subscription, health),
                            typed errors
  protocols/                adapters per format, importer, sniffer
  routing/                  models, compiler, builtin profiles
  chain/                    chain planner & validation
  warp/                     WARP registrar (X25519 + CF API), HTTP transport
  subscription/             (see application/subscription_service.dart)
  data/                     JsonStore (versioned), repos, vault, codecs
  application/              ConnectionController, SubscriptionService,
                            AppDependencies
  presentation/             shell + screens + widgets
  theme/                    tokens, 3 themes, ThemeExt
  localization/             ARBs + generated bindings
  platform/                 vault_factory (flutter_secure_storage)
android/  windows/  linux/  platform shells
test/     parsers_test, engines_test, engines2_test, widget_test
```

## Conventions

* Zero analyzer errors; `flutter analyze` gates every change.
* Layer rule: presentation → application → domain; protocols/core are
  importable by application+; domain imports nothing app-side.
* New protocol = new adapter file + registration in `MultiFormatImporter`
  (+ sniffer entry). No UI changes.
* Every parser/validator change ships with tests (see test/parsers_test.dart
  as the template).

## Roadmap (ordered)

1. **Core runners** — `CoreManager` process supervision wired to
   ConnectionController for desktop (`sing-box run`, `xray run`, version
   detection, crash backoff). The seams (`CoreAdapter` in docs/ARCHITECTURE.md
   §3) are defined; the process glue is next.
2. **TUN elevation UX** — Windows UAC relaunch for the core, Linux setcap
   detection & instructions.
3. **Android libbox** — bind `libsingbox.so` in `NexusVpnService`, per-app
   allow/deny, stats over the method channel.
4. **Tray** — `tray_manager` menu (connect/disconnect/current node/quit).
5. **QR import** — mobile_scanner on Android, image decode on desktop.
6. **Drift migration** — optional swap of JsonStore for SQLite using the same
   repository interfaces.
7. **Performance passes** — 1000-node sweep benchmark (spec §62).

## Release checklist

- [ ] flutter analyze: 0 issues
- [ ] flutter test: all green
- [ ] manual: import → detect → generate → validate → connect → failover
- [ ] secrets check: no plaintext credentials in store file
- [ ] THIRD_PARTY_LICENSES.md current
