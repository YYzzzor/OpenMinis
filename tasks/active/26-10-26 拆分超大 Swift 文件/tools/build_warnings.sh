#!/bin/bash
# 用全新的 DerivedData 做模拟器 Debug 和 Release 两次完整构建，
# 输出去掉路径和行号后的警告文本多重集合，供拆分前后比较（任务 V0、V3）。
# 用法：build_warnings.sh <输出目录>
set -euo pipefail
OUT="$1"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MINIS_SDK=iphonesimulator
export MINIS_IOS_DEPLOYMENT_TARGET=26.0
SCRATCH="${SCRATCH:-$(mktemp -d)}"
mkdir -p "$OUT"

# Debug：沿用项目构建脚本，换成全新的 DerivedData 保证完整编译。
SIMULATOR_NAME="iPhone 17 Pro" SIMULATOR_OS=26.4 DERIVED_DATA_PATH="$SCRATCH/dd-debug" \
    bash "$REPO_ROOT/scripts/build_ios_simulator.sh" --skip-deps > "$OUT/debug.log" 2>&1 \
    || { echo "Debug 构建失败，见 $OUT/debug.log"; exit 1; }

# Release：模拟器 SDK、整模块优化、不签名，用来编译只在 Release 下生效的代码。
xcodebuild -project "$REPO_ROOT/src/ios/Minis.xcodeproj" -scheme Minis -configuration Release \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$SCRATCH/dd-release" \
    CODE_SIGNING_ALLOWED=NO build > "$OUT/release.log" 2>&1 \
    || { echo "Release 构建失败，见 $OUT/release.log"; exit 1; }

# 警告只保留消息文本：拆分会改变文件名和行号；DerivedData 路径换成占位符。
for cfg in debug release; do
    grep -E ': warning: ' "$OUT/$cfg.log" \
        | sed -E 's/^.*: warning: //' | sed "s#$SCRATCH#<scratch>#g" | sort | uniq -c | sort -k2 > "$OUT/$cfg-warnings.txt" || true
    echo "$cfg: $(awk '{s+=$1} END {print s+0}' "$OUT/$cfg-warnings.txt") 条警告"
done
