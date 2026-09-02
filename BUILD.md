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
Place binaries in `<app-data>/cores/` (or configure paths in Settings → Cores):

```
cores/
  sing-box.exe   (or sing-box)   # >= 1.11 (wireguard endpoints, clash api)
  xray.exe       (or xray)       # >= 1.8 (xhttp, reality, fragmentation)
```

Layout per platform/arch (auto-detected by `CoreBinaryRegistry`):

| Platform | Arch | Files |
|---|---|---|
| Windows | x64 / ARM64 | `cores/windows-x64/sing-box.exe`, `xray.exe` |
| Linux | x64 / ARM64 | `cores/linux-x64/sing-box`, `xray` (chmod +x) |
| Android | arm64-v8a | `jniLibs/arm64-v8a/libsingbox.so` (libbox engine) |

Linux TUN note: grant the core the capabilities it needs instead of running
the app as root:

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
