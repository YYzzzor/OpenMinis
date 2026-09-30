# 26-09-30 现有 Spec 审阅问题修复

状态：done
更新：2026-09-30（Asia/Taipei）

## 恢复信息

分支：`main`
最近核验 HEAD：`272da5d9bb8051c82075513df9a395344d4e7f6b`
工作区：大量既有未提交、删除和未跟踪文件；已为本轮允许修改文档及其他既有修改建立独立内容基线，不将整个 Git diff 归因于本任务。
下一步：无；现有文档12项修复完成。缺失Spec另案处理。
待审批：无；以下文档修复已获用户明确授权，产品语义未决事项保持待确认。

## 任务确认与执行边界

确认状态：已确认
确认稿版本：2026-09-30 当前对话，承接上一轮 P0/P1/P2 只读独立审阅及最小修复顺序。
用户依据：“创建一个任务, 修复现有文档中的问题, 缺少的 Spec 稍后再解决”。
真实使用目标：维护者按索引或完整小节读取现有 Spec 时，得到准确的范围、当前实现、例外和可观察验收，不误判备份完备性、许可保障、路由与消费统计。
授权范围：本任务记录及附件；下列 12 份现有文档；如源标题或 description 改变，才重新生成索引；定向只读源码核对、文档静态检查和独立只读复审。
明确排除：新增缺失 Spec（G01—G03）、产品代码、配置、测试代码、验证脚本源码、其他既有任务及历史审查材料；不运行构建、单元/UI 测试、模拟器、真机或远端服务；不提交、推送、另建对话或 worktree。
执行位置：当前对话，当前仓库 main 脏工作区。
设备与数据：不操作设备、账户、备份包或用户业务数据。
首轮验证与停止条件：先核对备份类别和凭证路径，修正文档后检查完整章节读取；再覆盖其余问题。按 12 项修复完成、静态检查及必要复审通过即收尾，不以全产品运行验证扩大范围。
产品语义：不改变当前实现，不将未满足要求改写成预期行为；无法由源码确定的决定保持待维护者确认。

## 目标与验收

- [x] S01：写清环境变量元数据、值及 providers 凭证路径的导出/恢复依赖。
- [x] S02：区分 snapshotAt、聊天截止筛选与跨类别一致快照，保留当前限制。
- [x] S03：保留严格 HTTP 路由要求，并披露未知 POST 路径进入 RPC 的现状。
- [x] S04：区分上下文占用快照、实际 token 累计、请求成本和账户余额。
- [x] S05：fetch 产物目录为 browser，原生 WKDownload 为 workspace。
- [x] S06：写清空第三方候选链进入 System 的现状和未决降级语义。
- [x] S07：voice_corrections 排除普通 UI，但保留显式导出例外。
- [x] S08：最低 iOS 26.0 与历史 availability 分支明确分开。
- [x] S09：Agent 生命周期改用现存 Provider、语音和同步 Spec 链接。
- [x] S10：dirty 入队具备初始化和类别开启前提；补齐与恢复不冒称验证成功。
- [x] H01：Harness 旧 URL/iSH 章节选择器替换为现存标题并实际读取成功。
- [x] H02：会话资源和当前许可级别小节就近链接已知偏差，抽取后仍可定位。
- [x] 标题、description、索引、章节原文、链接、whitespace 及未涉及文件基线检查通过。
- [x] 独立只读复审完成，发现已处理；未验证行为和未决产品语义仍明确保留。

## 上下文与决定

本轮仅修复上一轮已确认的 12 项文档问题。原编号延续，不将严重度与 P0/P1/P2 批次混用。不新增 MCP、用量或 Skill/Memory Spec，也不实施相应产品改动。

允许修改：
- `docs/specs/ios-backup-restore.md`
- `docs/specs/debug-server-api.md`
- `docs/specs/ios-provider-model-routing.md`
- `docs/specs/ios-browser-automation.md`
- `docs/specs/ios-voice-input-lifecycle.md`
- `docs/specs/ios-system-entry-points.md`
- `docs/specs/ios-agent-run-lifecycle.md`
- `docs/specs/ios-sync-and-conflict-resolution.md`
- `docs/specs/minis-url-scheme.md`
- `docs/specs/ios-tool-permissions-and-side-effects.md`
- `docs/harness/spec-context.md`
- `docs/harness/operations.md`

不修改日历 P2 正文、iSH/设备能力正文、AGENTS 或 Harness 规则语义。索引目前已正确；标题/description 不变则仅 check 不写入。
本轮只修正文档表述和阅读关联，不改变产品模块、数据流或状态，不新增功能设计图。
资源：纯文档无新增产品运行资源影响；读取和检查限定选定文件，不运行性能采样。

## Spec 阅读清单

必读全文：
- `docs/harness/spec-authoring.md`：状态、场景、验收和证据。
- `docs/harness/spec-context.md`：完整章节与预算、精确选择器。
- `docs/specs/index.md`：现存文档路由。
- `docs/specs/resource-efficiency.md`：每轮主 Agent 自查和 reviewer 必读。
- 上述 10 份现有 Spec：逐项修复范围及旁支前提。

定向关键章节：
- `ios-backup-restore.md::iOS Backup and Restore > 备份范围`、`凭证与加密`、`导出完成与可恢复中断`、`恢复顺序与事务边界`。
- `debug-server-api.md::Debug Server API > HTTP 入口`。
- `ios-provider-model-routing.md::MinisX iOS Provider 与模型路由 > 配置变化和用量归因`。
- `ios-voice-input-lifecycle.md::MinisX iOS 语音输入生命周期 > Provider 解析与 failover`。
- `ios-sync-and-conflict-resolution.md::MinisX iOS 同步与冲突处理 > 启停、离线与发送`。
- `minis-url-scheme.md::Minis URL Contract > 资源作用域 > 会话资源`及`已知实现偏差`。
- `ios-tool-permissions-and-side-effects.md::iOS Tool Permissions and Side Effects > App 工具许可 > 当前级别`及`命令匹配与已知缺口`。

源码按需参考：BackupExporter/Importer/Secrets、DebugServer、AIChatViewModel 的 context usage 与 token 累计及 Billing、BrowserUseOffloadBridge/ConcurrentTools、VoiceProviderResolver/VoiceInputPanel、ChatStore.markDirty、工程 deployment target。只读取相关符号，不扫描其他归档。

## 实现计划

- [x] 核对当前分支、HEAD、工作区、规则和原审阅编号；建立本轮内容基线。
- [x] 创建任务，按源码复核写入 12 项文档修订。
- [x] 检查索引、outline、完整关键章节、Harness 示例、本地链接和 whitespace。
- [x] 固定本轮选定材料，独立只读复审，记录原始报告和逐项处置。
- [x] 核对无关文件基线、记录完成与边界，按 archive-task 归档本任务。

## 进展与验证

已完成 12 项修订和首轮静态检查：10 份修改 Spec 的 outline、17 项完整章节、130 处本地链接、已跟踪与8份未跟踪文档 whitespace 检查均通过。标题与 description 未变，索引仅执行 check，未写入。51 个既有文件基线中，排除授权修改的12份，其余39份哈希在首轮检查时未变化。独立复审已完成，12项逐项判断均充分，无新增或残留确定文档错误；主Agent已记录处置并接受有界文档验收。

详细检查和边界见[验证记录](verification.md)。未运行产品构建或测试。
上一轮源代码检查和历史日历运行证据不是本轮运行验收结果；本轮不会新增相应声明。

## Spec 同步

上述12份文档已修订；索引内容保持原字节。G01—G03 缺失 Spec 明确延期。

## 阻塞与纠偏

无。未决产品语义以文档状态表达，不构成本轮有限文档修复的待审批事项。

## 审查

已使用全新 GPT-6-Astra medium、fork_turns=none，只读固定文档及直接必要源码，资源规范全文必读。详见[原始报告](<reviews/001 现有 Spec 条件与现状修复/report.md>)、[逐项处置](<reviews/001 现有 Spec 条件与现状修复/resolution.md>)和[固定材料清单](<reviews/001 现有 Spec 条件与现状修复/manifest.json>)。原始固定任务副本的未勾选状态属于审查前版本，不覆盖历史快照；本任务状态在此收尾更新。


## 完成依据

2026-09-30：S01—S10/H01—H02的12项文档修复、静态验收和独立复审完成，无文档范围实质待办。待运行验证及待维护者确认只保留为产品证据/决策边界，不作为已完成事实。G01—G03明确排除；没有新增独立Spec，没有产品/测试代码改动、提交或推送。按archive-task归档当前任务，检查点仅针对本任务建立。

## 并行工作区变化

归档前发现并保留了一项并行改动：AGENTS.md 的代码审阅模型从 GPT-6-Astra medium 改为 GPT-6.1-Sol high。本轮未修改该文件。原始审阅按委派时规则完成；本轮仅修正文档，未涉及代码审阅，当前 review-task 和 collaboration 仍保留原审阅指引，因此不为此重复审阅或修改共用规则。最终核对中12份修订文档及17份审阅源码均与固定材料一致，其余38份基线文件未变；AGENTS 的并行版本另存哈希，以免错误归因。原始报告、清单与首轮静态记录保持原字节。
