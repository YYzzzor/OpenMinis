# 26-09-15 适配 iOS 27 模拟器构建
状态：done
更新：2026-09-15

## 恢复信息
分支：feat/minisx-branding；最近核验 HEAD：6cc5ea9。
保留任务前 MinisX 改名、MemoryManagementView 编译修复、本地空 ProviderCustomization.xcconfig 及首次构建记录；源码已按用户要求提交，未推送。
下一步：任务已验收，保留构建和审查限制记录。
待审批：无。用户随后明确将是否需要 Pi 审查交由主 Agent 判断，并确认可提交。

## 目标与验收
用户要求完成模拟器构建适配，默认27.0。
- [x] Apple Silicon arm64 iOS 27.0 模拟器 Debug 完整构建成功。
- [x] 模拟器安装启动并保存界面/日志证据。
- [x] 真机依赖不被替换，真机最低部署版本不变，真机 Debug 构建回归通过。
- [x] 主 Agent 根据实际构建、启动和真机回归结果验收；按用户后续授权，本次不再要求 Pi 审查。Pi 未执行，不记为通过。
不涉及 Intel 模拟器、真机签名、Android、图标、日历功能修改、完整功能回归或断电测试。

## 上下文与决定
原生依赖原来只编译 iphoneos arm64；模拟器必须重新编译，不能直接复用同架构真机二进制。
MINIS_SDK=iphonesimulator 选择独立 deps/simulator 输出与工作目录；默认 iphoneos 保留原构建路径与部署版本。
Xcode 根据 sdk 选择 MINIS_DEPS_ROOT，模拟器最低27.0、arm64；真机保持16.0（widget16.2）。
使用 DEVELOPER_DIR 选择已安装 Xcode，不修改系统全局路径。
复用原 Linux guest rootfs；本任务不改变 iSH 内核、挂载或 native offload 协议，因此没有必读运行时 Spec。

## 进展与验证
已确认 Xcode27.0、iOS27.0 runtime 可用。尚未完成本任务构建或运行验收。

2026-09-15 进度：Xcode 实际解析出 simulator arm64 / deployment27.0 / deps/simulator 搜索路径。真机 Debug 回归 BUILD SUCCEEDED，日志 /tmp/OpenMinis-device-regression.log。模拟器 LAME 已完成，FFmpeg 构建中。
首次复制源码排除 .deps 导致 LAME distclean 缺少 include 文件；已保留 .deps 至 distclean。副本 make -n distclean 验证无原源目录引用。真机依赖 SHA256 当前全部保持原值。
XcodeBuildMCP 无法识别现有模拟器（其工具环境未使用已安装 Xcode）；已回退 DEVELOPER_DIR 显式选择的 xcodebuild/simctl，不修改全局配置。

应用首编译在 ContentView.swift 的启动 .task 末尾类型检查超时。仅将原启动闭包完整搬到 @MainActor loadInitialSessions() async，.task 内 await；对比原始语句（忽略空白）完全一致。未改导航分支、初始化时序或状态值。正在重编译模拟器与真机。该必要 Swift 编译修复纳入 Pi 审查。

最终构建与启动：启动函数提取后仍有类型检查超时，继续将原 body 修饰符链分为 navigationContent、sessionEventContent、presentedContent、sessionObservedContent、body，顺序与闭包不变；模拟器与真机均 BUILD SUCCEEDED。
模拟器关闭签名会丢失 App Group entitlement 并在启动强制解包处崩溃；入口改用 CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES 本地 ad-hoc 签名，未更改运行时容器代码。重新构建安装后已进入首次使用界面，FileProvider domain registered OK，权限弹窗显示 MinisX。尚未操作权限弹窗或配置提供商。
最终真机依赖 SHA256 无变化。全部证据在 evidence/。本任务复核的源代码范围包含必要 ContentView 编译修复；首次构建任务的改名、MemoryManagementView 修改为既有基线，不重复扩展其范围。

## 审查
固定审查材料保存在 reviews/001/review-input.tar.gz。自动审批拒绝调用，未执行 Pi；不能将本任务标记为全部验收完成。具体原因和状态见 reviews/001/status.md。用户仍可使用已构建安装的模拟器版本。未提交或推送。

## 后续决策与提交
用户明确要求主 Agent 判断是否需要 Pi，并在实际查看应用后确认可以提交。主 Agent 基于已记录的模拟器构建/安装/启动、真机构建回归和依赖隔离校验接受本任务；没有把未执行的 Pi 审查当成通过。以上进度和 reviews/001 均保留为当时的历史记录。
源码已提交为 6cc5ea9。压缩快照、截图、构建日志和机器检查点仅保留本地，由 .gitignore 排除；仓库中的报告和 manifest 用于记录当时审查范围，完整快照不随提交分发。
