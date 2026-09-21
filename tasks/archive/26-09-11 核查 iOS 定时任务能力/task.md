# 26-09-11 核查 iOS 定时任务能力
状态：done（代码与官方文档调查完成；真机行为未验证，边界已记录）
更新：2026-09-11

## 用户目标与范围

用户要求：“判断当前的 OpenMinis 在 iOS 下，能否创建定时任务。”本任务调查当前本地版本实际具备的能力，不默认实现新功能。结合会话决定，在新的 Codex Session 通过任务记录恢复开展，作为 Harness 的首个真实任务试用。

区分三类含义：到指定时间自动运行 Agent/脚本；安排本地通知或提醒；通过外部系统安排执行。外部方案只说明当前仓库是否存在支持与边界，不替用户部署服务或推荐购买产品。

## 目标与验收

- [x] 明确回答当前 iOS 版本能否创建定时任务，说明支持的任务类型、实际入口与必要条件。
- [x] 区分创建/持久化、触发、执行三步，说明一次性与周期性是否有实现支持。
- [x] 分别核查前台、后台/挂起、被系统终止和用户强制退出后的适用性；不把通知投递当作 Agent 自动执行，不把后台延长运行当作定时唤醒保证。
- [x] 结论绑定本地代码版本与必要工作区状态，给出文件/行号/调用链证据；否定结论说明搜索范围，不能仅凭未搜到关键词下结论。
- [x] 涉及 iOS 平台机制时核查 Apple 官方文档，区分平台允许、项目实际实现和未验证推断；记录版本或配置影响。
- [x] 输出当前任务目录下 findings.md 并向用户简洁回答，记录无法完成的验证。Linux 无法代替 iOS 真机实测，不声称已运行实际定时行为。
- [x] 记录本次恢复、Spec 读取、调查与审查的实际负担；可获取时记耗时/token，不编造统计。

## 恢复信息

分支：ios-annotated。
准备时 HEAD：8399e1f9889f0d04629d560b5b0f881123524b78。
工作区：已有未提交 Harness 文档、skill、脚本和验证证据，以及 AGENTS.md 修改；保留这些工作，不提交、不清理。src/ios 的具体相关文件需要调查时核对是否有工作区差异。
下一步：本次调查已完成；如需设备级可靠性结论，另行按 findings.md 的待测项开展真机验证。
待审批：无。
2026-09-11 恢复：task_state.py inspect 返回 match；实际分支与 HEAD 和准备记录一致，无未完成 Git 操作，保留已有 Harness 工作。应用源码无工作区差异。

## 初步代码入口（仅定位，待核实）

- src/ios/Agent/Chat/AIChatViewModel.swift：搜索 `Scheduled tasks:`、`crontab`，检查其提示说明与实际工具/执行实现的一致性。
- src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift：用户能否经 Agent 请求创建相关任务，工具暴露与调用入口。
- src/ios/NativeOffloads/NotificationOffload.m：schedule、--after、--at、通知触发对象；沿注册与调用链确定可用入口。
- src/ios/Agent/Background/BackgroundKeepAliveManager.swift、src/ios/Agent/Chat/AIChatViewModel+BackgroundTask.swift：生命周期和后台运行限制。
- src/ios/Info.plist 与应用生命周期/通知回调：声明不等于注册或实际调度，核实真实使用。
- src/ios/iSH 与相关 rootfs 初始化：按需要核查 cron/at 可用性、进程生命周期与恢复，不凭 Linux 命令存在推断 iOS 后台可靠执行。

搜索时排除 Vendor、生成资源、minified JS 和本 Harness 的合成样例，避免概念同名误报。CodeGraph 可用且索引适用时优先使用，缺失或过时时直接读源码。

## Spec 阅读清单

必读：docs/specs/ios-sandbox-ish-summary.md :: iOS Sandbox Environment: iSH Virtualization Summary > 2. iOS Integration Layer > 2.3 ISHShellExecutor (`src/ios/iSH/ISHShellExecutor.m`)
用途：确认 shell 执行与 iOS 集成描述，按实际标题定位并对照代码。

必读：docs/specs/ios-sandbox-ish-summary.md :: iOS Sandbox Environment: iSH Virtualization Summary > 4. Native Offload System
用途：定位原生通知等 offload 的暴露方式和依赖。

按需参考：同文档 > 5. Agent Execution Flow；以及 > 2. iOS Integration Layer 的其他相关小节。
用途：核查从 Agent 到命令/原生工具的路径。保留祖先引言与必要依赖；上游描述不自动作为实现事实。

## 授权与边界

允许源码/历史/必要官方文档读取、只读命令和有意义的本地检查；可写本任务 findings.md、任务进展与检查点。不得为调查擅自修改应用代码、注释、共享规则或 skill，不提交、不推送、不调用外部模型发送项目材料。

这是分析任务，不是行为变更或缺陷修复，现有 Harness 不强制启动 Pi 代码审查。若结论存在需独立验证的关键疑点，再依据具体材料判断审查价值与授权，不为试用强行增加流程。

## 进展与验证

准备阶段仅初步定位；本次已完成主要调用链和 Apple 官方依据核查，结果见 [findings.md](findings.md)。未进行 iOS 构建或真机测试，不把代码可达性视为实际定时执行成功。任务命名和含空格路径沿用已批准约定。

## Harness 试用关联

父任务：[实现 OpenMinis 开发 Harness](<../../active/26-09-11 实现 OpenMinis 开发 Harness/task.md>)。
此前双方正常恢复和隔离案例已初步通过；本次用真实代码分析观察是否能正确续接、控制范围并给出可核实结果，不因本次分析没有代码开发就声称真实开发验收全部完成。

### 本次调查进展

已读取所列必读 Spec 小节及参考 2.1、2.2、2.4、5，逐项对照当前代码。CodeGraph 未提供可用工具，采用直接源码读取。已确认 shell_execute 的进程内 delay、系统一次性本地通知、AlarmKit 一次性/周期性闹钟、快捷指令 Send Prompt 到 Agent 的调用链与后台限制。发现 Spec 的 AlarmOffload 框架和协调器路径/串行执行描述过时，以源码为准；未修改 Spec。Apple 官方来源、文件/行号/调用链、生命周期矩阵、创建与执行边界及未验证事项均已保存到 findings.md。

## 最终结果与验收

交付：[findings.md](findings.md)。当前版本支持一次性系统通知、iOS 26+ 的一次性/每天/工作日闹钟，以及 Apple 快捷指令触发 Agent；没有应用内可跨挂起和终止可靠执行的通用时间调度器。前台/仍有后台运行时间时可做进程内 delay；强退后自动触发及长任务完成不能保证。通知工具存在等待添加回调超时未检查的问题，仅作静态证据记录，未修复。

完成情况：已完成分析文档与任务记录；验收依据为源码、Apple 官方文档和明确的验证边界。未完成的设备实验是已披露的证据限制，本次用户并未要求真机执行验证，因此不阻塞本次分析交付。无待用户判断的范围问题或待审批事项。

验证：恢复 inspect 为 match；最终执行 git diff --check，并对未跟踪的 findings.md 和 task.md 单独进行 diff --no-index --check；核对应用源码与 Spec 无 Git 差异。最终检查点写入后再运行 inspect 确认匹配。未运行应用构建、运行时测试或独立 Pi 审查（分析任务不要求）。

Harness 实际负担及缺失计量见 findings.md 第 5 节。中途记录一次主要调查进展并更新检查点，完成后再更新；未修改父任务、共享规则或 Spec。原有 Harness 文件与 AGENTS.md 改动保留，未提交或推送。
