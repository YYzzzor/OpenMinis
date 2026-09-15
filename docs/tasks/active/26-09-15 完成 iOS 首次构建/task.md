# 26-09-15 完成 iOS 首次构建
状态：done

## 恢复信息
分支：feat/minisx-branding；基准 HEAD：141b9f2。
保留已有 Info.plist、project.pbxproj、AboutView.swift 的 MinisX 改名，以及本地 ProviderCustomization.xcconfig 模板。
下一步：本任务完成；后续签名、安装和功能测试按用户的新任务开展。

## 目标与验收
用户要求准备相关依赖并持续编译直至成功。
- [x] iOS arm64 原生依赖和 rootfs 真实生成，保留原依赖版本与功能。
- [x] Xcode 27 Debug generic/platform=iOS、CODE_SIGNING_ALLOWED=NO 构建成功。
- [x] 必要源码修复经检查、相关验证及固定材料 Pi 审查；报告与处理记录见 reviews/003。
不包含真机安装、签名配置、运行功能保证、Android 构建或提交推送。不测试断电。

## 上下文与决定
使用 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer，不修改系统全局选择。
构建缓存 /tmp/OpenMinis-build-check，日志 /tmp/OpenMinis-build-check.log；原生构建日志 /tmp/OpenMinis-*-build.log。
已阅读 BUILDING.md iOS 构建要求及依赖脚本。若修改内核/挂载语义，再读取相关 Spec；当前仅环境准备。

## 进展与验证
首次尝试已解析 Swift 包并确认缺少原生依赖；补齐空配置后仍缺 alpine-rootfs.zip、RootfsPatch.bundle。
正在安装 Homebrew 工具、初始化固定版本 iSH 子模块、构建 LAME。

LAME 3.100 和 FFmpeg 6.1.2 已成功构建，FFmpeg 已确认包含 ffmpeg_main 和 libmp3lame 支持。iSH 固定提交及嵌套依赖初始化成功。工具安装仍进行中。

依赖准备完成：iSH 静态库、RootfsPatch.bundle、有效 ARM64 ELF VDSO 和 Alpine 3.21.0 rootfs.zip 已生成。Homebrew 安装 ninja/meson/llvm/lld，并自动升级其依赖及宿主 tesseract/ffmpeg（项目仍使用自建 FFmpeg 6.1.2）。开始完整 iOS Debug 无签名构建。

## 编译修复与审查范围
Xcode 27 SDK 的 ToolbarContentBuilder.buildLimitedAvailability 要求 iOS 17.5；MemoryManagementView.swift 在 toolbar builder 中使用 iOS 17.0 availability 分支导致原始编译失败。
最小修复：ToolbarItem 始终声明，版本与 iCloudSyncEnabled 条件移到 item 的 ViewBuilder 内；placement 使用兼容 iOS 16 的 navigationBarTrailing。iOS 17+ 且启用同步时保持原菜单和异步动作，iOS 16 或同步关闭时不显示菜单。不得提高最低部署版本或移除同步功能。
2026-09-15 无签名 Debug iOS arm64 构建已实际成功（exit 0、BUILD SUCCEEDED），应用包显示名 MinisX、MinimumOSVersion=16.0，主可执行文件 arm64。
独立审查仅检查此编译修复是否保留行为，以及现有改名是否意外影响构建标识。原生依赖源代码未修改，仅环境构建；子模块源码、第三方源码、Android、历史证据和本地配置排除。审查不等于真机 UI/同步测试，后者不在本次构建验收范围。
SwiftUI 官方依据：https://developer.apple.com/documentation/swiftui/toolbarcontentbuilder；具体可用性由本机 iPhoneOS27.0.sdk SwiftUI.swiftinterface 验证。

## 最终进展
构建目标已达成，证据与复现步骤见 verification.md。独立审查受外发授权限制尚未完成，任务保留 active。自动审批明确拒绝 Pi/DeepSeek 项目材料外发，未执行模型调用。已归档固定审查输入和构建日志。未提交、未推送。

## 审查授权更新
用户在当前会话明确允许将前述 11 个相关源码、构建配置及任务文件发送给 Pi 审查。使用 Pi/DeepSeek deepseek-flash 独立只读调用，重新准备当前快照。此前自动审批拒绝为历史记录，不代表本次已执行或通过。

## 完成验收（覆盖前述待授权状态）
用户授权后，Pi/DeepSeek 对新固定快照完成实际独立审查，结论 nonblocking。两项低优先级观察已核实处理，见 reviews/003/resolution.md。应用及扩展显示名称已从真实产物核实；无新增源码改动，不重跑构建。依赖准备、无签名 Debug 构建、审查闭环均完成。未提交或推送。

## 提交归档说明
相关源码已按用户要求提交为 6cc5ea9，未推送。文中“未提交”描述为当时执行阶段的历史状态。构建日志、截图、压缩快照及机器检查点保留本地，不随仓库提交；手写任务记录、验证结论和审查报告保留版本管理。
