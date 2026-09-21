# iOS 首次构建验证

日期：2026-09-15。环境：macOS 27.0，Xcode 27.0 (27A266a)，iPhoneOS 27.0 SDK。

## 结果
完整 Debug 无签名 generic/platform=iOS 构建返回 0，日志包含 BUILD SUCCEEDED。
应用输出：`/tmp/OpenMinis-build-check/Build/Products/Debug-iphoneos/Minis.app`。
已核验 CFBundleDisplayName=MinisX、MinimumOSVersion=16.0、arm64 Mach-O 主程序，应用尚未签名或安装到设备。

## 复现命令
```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis   -configuration Debug -destination 'generic/platform=iOS'   -derivedDataPath /tmp/OpenMinis-build-check CODE_SIGNING_ALLOWED=NO build
```

依赖已按 BUILDING.md 从源码生成：LAME 3.100、FFmpeg 6.1.2（MP3 支持）、iSH 固定提交 de124dd66124a15239cea1465164f74980ada245、ARM64 VDSO、RootfsPatch.bundle、Alpine 3.21.0 rootfs。
Homebrew 工具：Ninja、Meson、LLVM、LLD、libarchive、pkg-config；Homebrew 自动升级了部分宿主依赖与 tesseract/ffmpeg，未更换项目自建媒体库版本。
本地空 ProviderCustomization.xcconfig 保留，无凭据。

## 源码改动
MemoryManagementView.swift 工具栏的 #available 从 ToolbarContentBuilder 移到 ToolbarItem 内的 ViewBuilder，placement 使用 navigationBarTrailing。保留 iOS 17+ 且启用同步时显示菜单的条件；不提高主应用 iOS 16 部署目标。
原有三个 MinisX 改名文件保留。未改日历能力、子模块源码或共享规则。

## 检查与限制
- git diff --check 通过。
- Harness 测试：30 项执行，29 项通过，1 项按能力探测跳过非 UTF-8 文件名测试；最初沙箱内该项权限错误，沙箱外已正确跳过。
- 存在既有编译警告，包括未来 Swift 6 严格并发诊断；本轮不扩大范围整改。
- 未执行真机 UI、同步行为、签名、安装、Release 或模拟器构建。
- Pi 独立审查尚未执行：自动审批拒绝向 DeepSeek 发送固定的 11 个相关源码/配置/任务文件，要求对此内容和目的地的明确授权。未绕过。
- 审查输入已通过 Harness check --repo，固定材料归档在 evidence/review-input-002.tar.gz。无审查报告，不标记审查通过。
- iSH 子模块中仅有未跟踪 build-ios/ 构建产物，无已跟踪源码差异。

## 日志存档
- `OpenMinis-build-check.log.gz`：SHA256（原日志）`db898d3b02d9164ac7b4fdeb065d6a89335bb89fb96540891b82bef1742f9834`
- `OpenMinis-lame-build.log.gz`：SHA256（原日志）`118051dd5d5ab5bbb3c0373ff94c33d9c2baaaf91db70f885d78d83414794f02`
- `OpenMinis-ffmpeg-build.log.gz`：SHA256（原日志）`f60fef3212edaf9903d2b33c93ac6de5dc9b73a325178db95874be2559d0502b`
- `OpenMinis-ish-build.log.gz`：SHA256（原日志）`27150ef22e7c73a2f2a439d3c4963e9d0065fc07a1685cdcec0460fba4ce4377`
- `OpenMinis-rootfs-build.log.gz`：SHA256（原日志）`b49574d256baefb8967745e6352a543b9896c715b6f48b672f2fc90c1904f95e`
- `OpenMinis-harness-tests.log.gz`：SHA256（原日志）`ad6a61635005d8031a25a4653c45ecfe20f8d096b05d2dae35c35172e3a86430`

## 独立审查完成更新
用户明确授权后，Pi 0.85.1 / deepseek-flash 已审查固定快照，返回 nonblocking。主 Agent 核实并处理两项低优先级观察，核对实际主应用和扩展 Info.plist。见 reviews/003/report.md 和 resolution.md。此前未获授权、尚未审查的段落为历史状态，当前审查闭环已完成；源码与成功构建时一致。
