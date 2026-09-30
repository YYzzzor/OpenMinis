# 26-09-29 P0 Spec 文档修复

状态：done
更新：2026-09-29 17:56 CST

## 恢复信息

分支：`main`
最近核验 HEAD：`272da5d9bb8051c82075513df9a395344d4e7f6b`
工作区：大量既有未提交修改，核验时约 27 个修改/暂存项、55 个删除项、22 个未跟踪项；本任务保留并避开无关工作，不切分支、不建 worktree。
下一步：无。本任务仅处理 P0；P1/P2 由维护者后续另行决定。
待审批：无；用户已在当前对话明确要求创建任务并解决全部 P0 文档问题。

## 任务确认与执行边界

确认状态：已确认
确认稿版本：2026-09-29 当前对话，依据上一轮《Spec 文档质量与 iOS 规范覆盖评估》的 P0 清单。
用户依据：“创建一个任务, 然后你把其中存在 P0 级别问题的文档都解决, 其余的先空着.”
真实使用目标：维护者和开发模型从 Spec 索引进入后，能够得到与当前 iOS 源码一致、状态清楚、可用于实施判断的 P0 规范，不再被旧架构、草案或缺失规范误导。
授权范围：创建和维护本任务；修改 `docs/specs/` 下 P0 相关源 Spec 与生成索引；进行静态源码核对和文档校验。明确排除产品代码、测试代码、其他 P1/P2 Spec、构建、模拟器、设备操作、提交和推送。
执行位置：当前对话；`/Users/huyuanzhao/Coding/Projects/OpenMinis`；`main` 当前脏工作区。
设备与数据：不操作设备、账户、用户数据或远端服务。
首轮验证与停止条件：先让一份现有误导性 Spec 与当前源码对齐并验证章节可抽取，再完成同批文档；若源码无法确定产品意图，则在 Spec 中明确标为待维护者确认，不把当前实现直接提升为现行约定。

## 目标与验收

- [x] 重写 `debug-server-api.md`，覆盖当前传输、发现、认证、安全、生命周期和方法来源，移除过时/推测性契约。
- [x] 重写 `minis-url-scheme.md`，区分资源 URL 与导航深链，覆盖当前作用域、解析、渲染和安全边界，移除未来 checklist。
- [x] 重写 `ios-sandbox-ish-summary.md` 为当前 shell runtime 与隔离契约，修正部署版本、并发、挂载和 offload 事实。
- [x] 新增 `ios-tool-permissions-and-side-effects.md`，记录三层授权、有副作用操作和已知间接调用限制。
- [x] 新增 `ios-backup-restore.md`，建立现行 `.minisbak` 格式、加密、完整性、恢复、回滚和不完整结果规范。
- [x] 新增 `ios-agent-run-lifecycle.md`，建立发送、工具循环、停止、重试、恢复、持久化和上下文生命周期规范。
- [x] 六份文档均有准确 description、状态、场景、前提、例外、可观察验收与证据边界；生成索引一致。
- [x] P1/P2 建议保持未实施，只在本任务中记录暂缓范围。

## 上下文与决定

- Harness 治理机制及生成索引已核实有效；本任务只修正文内容与 P0 覆盖，不改变 Harness 规则。
- 当前实现事实不自动成为产品意图。无法从既有确认或稳定接口判断的语义，以“当前实现/已知限制/待维护者确认”标明。
- `debug-server-api` 的逐方法参数目录以运行时 `rpc.discover` 和 `DebugMethodRegistry` 为来源，Spec 不再手工复制完整方法表。
- `minis://` 同时被资源解析和导航路由使用；资源契约保留在原文件，导航行为在其中建立明确边界，后续 P1 仍可拆出跨入口 Spec。
- iSH 文档只保留稳定运行与隔离契约；易漂移的构建产物和类清单不作为长期规范。
- 本任务是文档修复，不改变运行模块协作或数据流，因此不额外绘制拟议功能图。

暂缓：设备能力清单刷新、同步冲突、Provider/模型路由、语音输入、跨入口/system surfaces、浏览器自动化和日历历史状态整理。

## Spec 阅读清单

必读：

- `docs/harness/spec-authoring.md` 全文：文档质量、状态、场景和证据标准。
- `docs/harness/spec-context.md` 全文：章节路由、预算和证据边界。
- `docs/specs/resource-efficiency.md` 全文：本任务工具和文档结构的持续资源约束。
- `docs/specs/debug-server-api.md` 全文及当前 Debug 源码：重写调试契约。
- `docs/specs/minis-url-scheme.md` 全文及资源/深链源码：重写 URL 契约。
- `docs/specs/ios-sandbox-ish-summary.md` 全文及 iSH/runtime 源码：重写运行契约。

按需参考：

- `docs/specs/ios-device-data-capabilities.md` 的“授权与执行条件”：区分系统权限与应用工具权限。
- `docs/backup-streaming-package-design.md`：只作历史/草案来源，已实现部分必须重新由源码确认。
- `tasks/archive/26-09-29 Spec 文档治理与渐进上下文/task.md` 的最终验收与边界：确认前轮没有全产品事实复核。

## 实现计划

- [x] 依据当前源码建立六份文档的事实清单、规范语义和待验证边界。
- [x] 重写三份现有 P0 Spec，保留有效入口链接并移除过时内容。
- [x] 新增三份 P0 Spec，避免按类或文件机械建文档。
- [x] 重新生成索引并验证 description、标题、章节抽取、本地链接与 Markdown 格式。
- [x] 核对最终 diff 仅覆盖授权文档与任务记录，记录未运行范围。

## 进展与验证

已完成六项 P0：重写调试服务、`minis://` 和 iSH runtime 三份旧 Spec；新增工具权限、备份恢复和 Agent 生命周期三份 Spec。文档明确区分现行规范、当前实现、已知偏差和待运行验证。

静态验证：

- `spec_context.py index --check` 通过，六份文档均进入生成索引。
- 六份文档的 outline 均可生成；认证、URL 偏差和 Stop/Retry/Resume 小节可按完整标题路径抽取，并保留 description、顶层状态和章节路线。
- 相对 Markdown 链接均指向存在文件；`spec-context` 的受控阅读 anchor 存在。
- 授权路径的 `git diff --check` 通过；三份新文件另以 no-index whitespace check 验证通过。
- 未运行 iOS 构建、单元/UI 测试、模拟器或真机验证；文档中的相关行为均标为待验证，没有用静态源码或历史测试替代运行证据。

已知实现偏差仍保留而未改代码：`AIChatViewModel+RequestBudget.resolveMinisURL` 的跨会话扫描，以及工具许可对 `sh -c`、`env`、脚本和子进程间接 offload 的覆盖缺口。

## Spec 同步

已同步 `docs/specs/index.md`。P0 长期规范入口已覆盖；P1/P2 暂缓项没有修改。没有修改 Harness 规则、产品代码或测试代码。

## 阻塞与纠偏

无。工作区原有大量未提交修改和任务搬迁保持不动；本任务只新增/修改六份 P0 Spec、生成索引和本记录。

## 审查

本任务为文档与规范修复，未启动代码审查。已按 Spec 写作规则完成静态一致性复核；仍需产品决定的语义（Debug LAN 暴露、shell 最大并发/网络边界、Stop 后排队 prompt）已在对应 Spec 标明，不阻碍本轮 P0 文档修复完成。

## 完成依据

2026-09-29：六份 P0 Spec 及生成索引达到本任务确认的静态验收条件；P1/P2 明确排除，运行验证诚实保留为待验证。任务可归档。
