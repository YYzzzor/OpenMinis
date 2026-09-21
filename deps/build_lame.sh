#!/bin/bash
set -e

# ============================================================================
# LAME 3.100 Build Script for iOS arm64
# ============================================================================
# Cross-compiles LAME as a static library for use with FFmpeg's libmp3lame
# encoder on iOS.
#
# Usage:
#   ./build_lame.sh [clean]
#   MINIS_SDK=iphonesimulator ./build_lame.sh [clean] (iOS 26.0+)
#
# Output:
#   deps/lame-build/lib/libmp3lame.a
#   deps/lame-build/include/lame/lame.h
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAME_VERSION="3.100"
LAME_TARBALL="lame-${LAME_VERSION}.tar.gz"
LAME_SRC_DIR="$SCRIPT_DIR/lame-${LAME_VERSION}"
source "$SCRIPT_DIR/ios_build_target.sh"
LAME_BUILD_DIR="$MINIS_DEPS_ROOT/lame-build"
LAME_WORK_DIR="$LAME_SRC_DIR"
if [ "$MINIS_SDK" = "iphonesimulator" ]; then
    LAME_WORK_DIR="$MINIS_DEPS_ROOT/lame-source"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ============================================================================
# Clean
# ============================================================================
if [ "$1" == "clean" ]; then
    log_info "Cleaning LAME build artifacts..."
    if [ "$MINIS_SDK" = "iphonesimulator" ]; then
        rm -rf "$LAME_WORK_DIR" "$LAME_BUILD_DIR"
    else
        # 源码受版本管理，不再将 clean 等同于删除源码。
        if [ -f "$LAME_SRC_DIR/Makefile" ]; then
            (cd "$LAME_SRC_DIR" && make distclean)
        fi
        rm -rf "$LAME_BUILD_DIR"
    fi
    log_success "Clean completed"
    exit 0
fi

# ============================================================================
# Download source
# ============================================================================
if [ ! -d "$LAME_SRC_DIR" ]; then
    log_info "Downloading LAME ${LAME_VERSION}..."
    cd "$SCRIPT_DIR"
    if [ ! -f "$LAME_TARBALL" ]; then
        curl -L -o "$LAME_TARBALL" \
            "https://sourceforge.net/projects/lame/files/lame/${LAME_VERSION}/${LAME_TARBALL}/download"
    fi
    tar xzf "$LAME_TARBALL"
    rm -f "$LAME_TARBALL"
    log_success "LAME source extracted"
else
    log_info "LAME source already present, skipping download"
fi

# ============================================================================
# Cross-compile for iOS arm64
# ============================================================================
if [ "$MINIS_SDK" = "iphonesimulator" ]; then
    minis_copy_source "$LAME_SRC_DIR" "$LAME_WORK_DIR"
    if [ -f "$LAME_WORK_DIR/Makefile" ]; then
        (cd "$LAME_WORK_DIR" && make distclean)
    fi
fi
log_info "Configuring LAME for $MINIS_TARGET..."

IOS_SDK=$(xcrun --sdk "$MINIS_SDK" --show-sdk-path)
CC="$(xcrun --sdk "$MINIS_SDK" -f clang)"

export CC
export CFLAGS="-target $MINIS_TARGET -isysroot $IOS_SDK -Oz -fPIC -Wno-implicit-function-declaration"
export LDFLAGS="-target $MINIS_TARGET -isysroot $IOS_SDK"

cd "$LAME_WORK_DIR"

./configure \
    --prefix="$LAME_BUILD_DIR" \
    --host=aarch64-apple-darwin \
    --disable-shared \
    --enable-static \
    --disable-frontend \
    --disable-decoder \
    --disable-gtktest \
    --with-pic

log_info "Building LAME..."
make -j$(sysctl -n hw.ncpu)
make install

cd "$SCRIPT_DIR"

# ============================================================================
# Verify
# ============================================================================
if [ -f "$LAME_BUILD_DIR/lib/libmp3lame.a" ]; then
    log_success "LAME ${LAME_VERSION} built successfully"
    echo ""
    echo "  Static library: $LAME_BUILD_DIR/lib/libmp3lame.a"
    echo "  Headers:        $LAME_BUILD_DIR/include/lame/lame.h"
    echo ""
    file "$LAME_BUILD_DIR/lib/libmp3lame.a"
else
    log_error "Build failed — libmp3lame.a not found"
fi
