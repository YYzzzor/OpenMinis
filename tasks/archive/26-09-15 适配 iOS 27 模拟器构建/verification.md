# 验证记录

环境：macOS 27.0、Apple Silicon、Xcode 27.0 (27A266a)、iOS Simulator SDK 27.0。使用显式 DEVELOPER_DIR，不变更全局 xcode-select。

## 已通过
- `bash -n` 检查新增入口与依赖脚本；`plutil -lint` 检查 project.pbxproj；`git diff --check`。
- `xcodebuild -showBuildSettings -sdk iphonesimulator`：arm64，最低27.0，MINIS_DEPS_ROOT=deps/simulator。
- 真机回归：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/OpenMinis-build-check CODE_SIGNING_ALLOWED=NO build`，BUILD SUCCEEDED。使用原真机依赖。
- 模拟器 LAME 3.100、FFmpeg 6.1.2、iSH 库及 Linux VDSO 构建成功。
- `xcrun vtool -show-build deps/simulator/frameworks/FFmpeg.framework/FFmpeg`：IOSSIMULATOR / minos27.0 / sdk27.0；七个 framework plist 均 iPhoneSimulator / 27.0。
- LAME/FFmpeg 副本清理 dry-run 未引用原源码目录；初次构建中发现的 .deps include 缺失已修复。
- iPhone18 Pro / iOS27.0 首次 bootstatus 完成。

## 最终结果
- `bash scripts/build_ios_simulator.sh --skip-deps` 最终 BUILD SUCCEEDED；采用本地 ad-hoc 签名，保留 App Group entitlement。
- 真机 Debug 对最终 ContentView 拆分再次 BUILD SUCCEEDED；所有原真机依赖 SHA256 不变。
- ContentView 原启动语句抽取后逐条比较（忽略空白）不变；修饰符链仅在原顺序上拆为计算属性，没有增加额外容器或状态。
- simctl install 成功，运行截图见 evidence/simulator-launch.png；首次使用页面及位置权限弹窗可见，显示名 MinisX。日志含 FileProvider domain registered OK / refreshRemoteDeviceSessions 完成。没有操作权限弹窗、输入账号或发送聊天。
- App 与三个扩展的 simulator plist 均最低27.0；详细标识见 evidence/bundle-identities.json。
- 初次无签名启动的 App Group nil 崩溃已通过正确 simulator 签名解决，未修改 App Group 业务逻辑。
- 完整构建和启动日志压缩保存在 evidence/；运行范围仅启动冒烟验证。

## 范围限制
没有验证 Release、Intel 模拟器、真机安装、iCloud、日历权限/事件、共享扩展和完整 Agent 工作流。模拟器启动不替代真机功能测试。
