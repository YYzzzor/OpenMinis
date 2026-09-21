#!/bin/bash
# 由各依赖脚本 source；默认保持真机输出，模拟器使用独立目录。
MINIS_SDK="${MINIS_SDK:-iphoneos}"
case "$MINIS_SDK" in
    iphoneos)
        MINIS_DEPS_ROOT="$SCRIPT_DIR"
        IOS_DEPLOYMENT_TARGET="${MINIS_IOS_DEPLOYMENT_TARGET:-26.0}"
        MINIS_PLATFORM="iPhoneOS"
        MINIS_TARGET="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
        ;;
    iphonesimulator)
        MINIS_DEPS_ROOT="$SCRIPT_DIR/simulator"
        IOS_DEPLOYMENT_TARGET="${MINIS_IOS_DEPLOYMENT_TARGET:-26.0}"
        MINIS_PLATFORM="iPhoneSimulator"
        MINIS_TARGET="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
        ;;
    *)
        echo "Unsupported MINIS_SDK: $MINIS_SDK (use iphoneos or iphonesimulator)" >&2
        exit 1
        ;;
esac
if ! [[ "$IOS_DEPLOYMENT_TARGET" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Invalid MINIS_IOS_DEPLOYMENT_TARGET: $IOS_DEPLOYMENT_TARGET" >&2
    exit 1
fi

# 上游脚本在源树内构建；仅在模拟器副本中清理和重新配置，保护真机产物。
minis_copy_source() {
    local source="$1" destination="$2"
    mkdir -p "$destination"
    rsync -a --delete --delete-excluded --exclude='build-ios/' --exclude='.git' \
        --exclude='*.o' --exclude='*.lo' --exclude='*.a' \
        --exclude='*.dylib' --exclude='.libs/' \
        "$source/" "$destination/"
}
