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
OUT_DIR="$(dirname "$0")/../android/app/libs"

echo "==> Cloning sing-box ${REF}"
git clone --depth 1 --branch "${REF}" https://github.com/SagerNet/sing-box.git "${WORK}/sing-box"
cd "${WORK}/sing-box"

echo "==> Building libbox AAR via gomobile (arm64-v8a + x86_64)"
gomobile bind -v \
  -target=android -androidapi 24 \
  -o "${OUT_DIR}/libbox.aar" \
  ./experimental/libbox

echo "==> Provenance"
echo "sing-box ref: ${REF}" > "${OUT_DIR}/libbox.provenance.txt"
echo "commit: $(git rev-parse HEAD)" >> "${OUT_DIR}/libbox.provenance.txt"
echo "gomobile: $(gomobile version 2>/dev/null || echo 'unknown')" >> "${OUT_DIR}/libbox.provenance.txt"
cat "${OUT_DIR}/libbox.provenance.txt"
echo "==> Done: ${OUT_DIR}/libbox.aar"
