#!/usr/bin/env bash
# Build rclone as a static library for iOS and package it as an XCFramework.
#
# Produces deps/frameworks/Rclone.xcframework with two slices:
#   ios-arm64            (device)
#   ios-arm64-simulator  (simulator)
#
# Both slices are required by the device and simulator build workflows.
#
# Which backends get linked is decided by deps/rclone-mobile/backends/backends.go,
# not here. rclone itself is a go.mod dependency (pinned version), never
# vendored — upgrading is a one-line change to that file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/deps/rclone-mobile"
OUT="$ROOT/deps/frameworks"
BUILD="$ROOT/deps/build/rclone"
IOS_DEPLOYMENT_TARGET="${MINIS_IOS_DEPLOYMENT_TARGET:-26.0}"
if ! [[ "$IOS_DEPLOYMENT_TARGET" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "error: invalid MINIS_IOS_DEPLOYMENT_TARGET" >&2
  exit 1
fi

command -v go >/dev/null || { echo "error: go toolchain not found" >&2; exit 1; }

mkdir -p "$BUILD" "$OUT"
cd "$SRC"

build_slice() {
  local sdk="$1" minflag="$2" tag="$3"
  echo "==> $tag"
  CC="$(xcrun --sdk "$sdk" -f clang) -isysroot $(xcrun --sdk "$sdk" --show-sdk-path) $minflag -arch arm64" \
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
    go build -buildmode=c-archive -trimpath -ldflags="-s -w" \
      -o "$BUILD/$tag/librclone.a" ./librclone
}

build_slice iphoneos          "-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET"        device
build_slice iphonesimulator   "-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"   simulator

# c-archive emits librclone.h next to each .a; both slices share one header.
for t in device simulator; do
  mkdir -p "$BUILD/$t/include"
  mv "$BUILD/$t/librclone.h" "$BUILD/$t/include/" 2>/dev/null || true
done

rm -rf "$OUT/Rclone.xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD/device/librclone.a"    -headers "$BUILD/device/include" \
  -library "$BUILD/simulator/librclone.a" -headers "$BUILD/simulator/include" \
  -output "$OUT/Rclone.xcframework" >/dev/null

echo "==> $OUT/Rclone.xcframework"
du -sh "$OUT/Rclone.xcframework" | awk '{print "    size:", $1}'
