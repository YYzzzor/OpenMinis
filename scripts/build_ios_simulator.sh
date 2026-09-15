#!/bin/bash
set -euo pipefail

# 原生依赖与 Xcode 必须使用同一个 SDK；仅为当前进程选择 Xcode。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MINIS_SDK=iphonesimulator
export MINIS_IOS_DEPLOYMENT_TARGET=26.0
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 18 Pro}"
SIMULATOR_OS="${SIMULATOR_OS:-27.0}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/build/ios-simulator}"

case "${1:-}" in
    "")
        bash "$REPO_ROOT/deps/build_lame.sh"
        bash "$REPO_ROOT/deps/build_ffmpeg.sh"
        bash "$REPO_ROOT/deps/build_ish.sh"
        ;;
    --skip-deps) ;;
    *) echo "Usage: $0 [--skip-deps]" >&2; exit 2 ;;
esac

# rootfs 是 Linux guest 数据，可供真机和模拟器共同使用。
if [ ! -f "$REPO_ROOT/deps/resources/alpine-rootfs.zip" ]; then
    bash "$REPO_ROOT/deps/prepare_alpine_rootfs.sh"
fi
# Xcode 的资源引用保持共用位置；初次只构建模拟器时也要准备这些资源。
if [ ! -f "$REPO_ROOT/deps/resources/libvdso.so.elf" ]; then
    mkdir -p "$REPO_ROOT/deps/resources"
    cp "$REPO_ROOT/deps/simulator/resources/libvdso.so.elf" "$REPO_ROOT/deps/resources/"
fi
if [ ! -d "$REPO_ROOT/deps/resources/RootfsPatch.bundle" ]; then
    cp -R "$REPO_ROOT/deps/simulator/resources/RootfsPatch.bundle" "$REPO_ROOT/deps/resources/"
fi

xcodebuild -project "$REPO_ROOT/src/ios/Minis.xcodeproj" \
    -scheme Minis -configuration Debug \
    -destination "platform=iOS Simulator,name=$SIMULATOR_NAME,OS=$SIMULATOR_OS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
