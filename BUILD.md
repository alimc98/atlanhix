# BUILD

## Prerequisites

* Flutter 3.24+ (developed on 3.47.2 / Dart 3.13)
* Windows: Visual Studio 2022 with "Desktop development with C++"
* Linux: `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`
* Android: Android SDK 35, NDK r27, JDK 17

## Run / build

```bash
flutter pub get
flutter run -d windows|linux|android
flutter build windows|apk|linux
```

## Core binaries (engines)

NEXUS supervises external engines; it does not implement tunnel protocols.
Place binaries in `cores/<platform>-<arch>/` (repo root, git-ignored) or set a
custom directory in Settings → Cores. `BinaryManager` searches, in order:

1. user-configured cores dir
2. `Directory.current/cores/<platform>-<arch>/`  (dev layout)
3. PATH

Layout (all from **official releases** — never random mirrors):

```
cores/
  windows-x64/  sing-box.exe   xray.exe
  windows-arm64/ …
  linux-x64/    sing-box       xray
  linux-arm64/  …
```

Download steps (current versions at time of writing):

```bash
# sing-box (GPL-3.0, official SagerNet releases)
curl -L -o sb.zip \
  https://github.com/SagerNet/sing-box/releases/download/v1.14.0/sing-box-1.14.0-windows-amd64.zip
# Xray-core (MPL-2.0, official XTLS releases)
curl -L -o xr.zip \
  https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-windows-64.zip
```

Extract so the final layout is `cores/windows-x64/sing-box.exe` and
`cores/windows-x64/xray.exe`. `flutter test` auto-detects them and runs the
REAL engine integration suite; without them those tests skip with a printed
reason. AmneziaWG (`amneziawg`/`amneziawg-go`) and MasterDNSVPN
(`mdvpn-client`) binaries follow the same layout when used.

Linux TUN note: grant the core capabilities instead of running the app as root:

```bash
sudo setcap cap_net_admin,cap_net_bind_service=+ep cores/linux-x64/sing-box
```

Android VPN note: the `NexusVpnService` foreground service and VpnService
permission are already wired in the manifest; the libbox engine binding is a
listed milestone in `DEVELOPMENT.md`.

## Verify

```bash
flutter analyze   # must report 0 errors
flutter test      # 41+ tests: parsers, engines, generators, widgets, l10n
```
