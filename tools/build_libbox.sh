#!/usr/bin/env bash
# Builds sing-box's libbox AAR from source with gomobile — required for
# F-Droid (no prebuilt binaries may be committed to the source repo).
#
# Usage:  tools/build_libbox.sh [sing-box-ref]     (default: v1.14.0)
# Output: android/app/libs/libbox.aar  (plus classes.jar provenance log)
#
# Prerequisites: Go 1.24+, Android SDK with NDK r28, JDK 17+
#   go install golang.org/x/mobile/cmd/gomobile@latest
#   gomobile init
set -euo pipefail

REF="${1:-v1.14.0}"
WORK="$(mktemp -d)"
# Absolute, because we cd into the sing-box clone below.
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/android/app/libs"

echo "==> Cloning sing-box ${REF}"
git clone --depth 1 --branch "${REF}" https://github.com/SagerNet/sing-box.git "${WORK}/sing-box"
cd "${WORK}/sing-box"

# gomobile bind runs as a tool inside this module: it requires the
# golang.org/x/mobile dependency to be resolvable here.
echo "==> Wiring golang.org/x/mobile into the module"
# Pin x/mobile to the last version whose go directive is <= sing-box's own
# (newer x/mobile requires go 1.26, which drops os.checkPidfdOnce that
# sing-box links against). Resolved from commit 4dd8f1dbf5d2 (2026-06-11).
XMOBILE=v0.0.0-20260611195102-4dd8f1dbf5d2
# x/mobile's go.mod carries a newer toolchain directive; lock the build to
# sing-box's own Go version or the linker rejects its os.checkPidfdOnce
# linkname (removed in Go 1.26).
export GOTOOLCHAIN=go1.25.5
go install golang.org/x/mobile/cmd/gomobile@${XMOBILE}
go install golang.org/x/mobile/cmd/gobind@${XMOBILE}
go get golang.org/x/mobile/bind@${XMOBILE}

export PATH="$(go env GOPATH)/bin:$PATH"

echo "==> Building libbox AAR via gomobile (arm64-v8a + x86_64)"
gomobile bind -v \
  -target=android -androidapi 24 \
  -ldflags=-checklinkname=0 \
  -o "${OUT_DIR}/libbox.aar" \
  ./experimental/libbox

echo "==> Provenance"
echo "sing-box ref: ${REF}" > "${OUT_DIR}/libbox.provenance.txt"
echo "commit: $(git rev-parse HEAD)" >> "${OUT_DIR}/libbox.provenance.txt"
echo "gomobile: $(gomobile version 2>/dev/null || echo 'unknown')" >> "${OUT_DIR}/libbox.provenance.txt"
cat "${OUT_DIR}/libbox.provenance.txt"
echo "==> Done: ${OUT_DIR}/libbox.aar"
