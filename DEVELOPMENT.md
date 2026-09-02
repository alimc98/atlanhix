# DEVELOPMENT

## Layout

```
lib/
  main.dart                 composition root bootstrap
  core/
    runtime/                PROCESS SUPERVISION (v0.2)
                            binary_manager · core_process (ManagedProcess,
                            PortAllocator, exit classification) · core_runtime
                            (contract) · singbox_runtime · xray_runtime ·
                            external_runtimes (AWG, MDVPN) · core_manager ·
                            clash_api_client
    core_detector.dart      engine selection with confidence
    configgen/              sing-box + Xray renderers (engine-validated)
    health/                 latency_tester (TCP/TLS/SOCKS-HTTP probes),
                            test_scheduler, HealthStore
    scoring/                node_scorer (5 strategies)
    fragmentation/          fragment profiles + eligibility engine
    cdn/                    CDN signals
    logger.dart             redacting logger
  domain/                   entities + typed errors
  protocols/                adapters per format, importer, sniffer
  routing/                  models, compiler, builtin profiles
  chain/                    chain planner & validation
  warp/                     WARP registrar + HTTP transport
  data/                     JsonStore (versioned), repos, vault, codecs
  application/              ConnectionController (state machine), services
  presentation/             shell + screens + widgets
  theme/  localization/     tokens/themes, EN/FA
  platform/                 system_proxy (WinINET/gsettings), vault factory
test/
  parsers_test.dart         17 parser/format tests
  engines_test.dart         detector + generators
  engines2_test.dart        scorer/routing/chain/health
  runtime_test.dart         REAL engine runs (sing-box check/run, xray -test)
  runtime_lifecycle_test.dart ManagedProcess + CoreManager hot-switch cycles
  widget_test.dart          widgets + RTL/Persian smoke
```

## Conventions

* Zero analyzer errors; `flutter analyze` gates every change.
* Real engines are the source of truth: config changes must pass
  `runtime_test.dart` (sing-box check / xray -test actually run).
* New protocol = new adapter + sniffer entry + tests. No UI changes.
* Never fake runtime state; surface `—` and error classifications instead.

## Roadmap (ordered, remaining)

1. **Android libbox binding** — `libsingbox.so` in `NexusVpnService`, method
   channel, per-app allow/deny, real VPN states (Phases 8–10).
2. **Windows/Linux TUN elevation UX** — UAC relaunch for the core only;
   setcap detection + instructions (Phases 11–12).
3. **WARP chain runtime** — materialize ChainPlan detours through sing-box
   config (Phase 19) using the existing ChainPlanner.
4. **Tray** — `tray_manager` menu (connect/disconnect/current node/quit).
5. **QR import** — mobile_scanner on Android, image decode on desktop.
6. **Drift migration** — optional SQLite backend behind existing repos.
7. **Xray stats API** — replace `traffic → null` for Xray sessions.
8. **Performance passes** — 1000-node sweep benchmark (spec §62).

## Release checklist

- [ ] flutter analyze: 0 issues
- [ ] flutter test: all green (runtime tests require cores/ present)
- [ ] manual: import → detect → generate → validate → connect → failover
- [ ] secrets check: no plaintext credentials in store or logs
- [ ] THIRD_PARTY_LICENSES.md current
