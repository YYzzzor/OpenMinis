# 26-09-30 缺失 Spec 补全与冲突澄清

状态：active
更新：2026-09-30（Asia/Taipei）

## 恢复信息

分支：main
最近核验 HEAD：272da5d9bb8051c82075513df9a395344d4e7f6b
工作区：大量既有未提交、未跟踪与删除项；本轮建立51份非任务文件内容基线，仅按本轮开始时字节归因文档修改。
下一步：固定本轮文档及必要源码，进行独立只读复审并处置意见。
待审批：无；用户授权文档补全与冲突修复。产品语义未决事项不由本任务决定。

## 任务确认与执行边界

确认状态：已确认
确认稿版本：当前对话2026-09-30，承接P0/P1/P2独立审阅、12项现有文档修复与Skill/Memory只读调查。
用户依据：“创建一个任务, 可以补充缺失的 Spec 文档, 并修复当前冲突的 Spec”。
真实使用目标：维护者处理MCP调用、消费统计、Skill启停或Memory撤销时，能够按需读取准确的条件、例外和验收，不误判开关、凭证、费用与跨设备删除保证。
授权范围：新增ios-mcp-integrations.md、ios-usage-cost-and-balance.md、ios-skills-lifecycle.md、ios-memory-lifecycle.md；修订直接相关既有Spec、生成index.md；本任务及附件、文档静态检查、必要独立只读复审。
排除：产品代码、配置、测试或脚本源码、AGENTS/Harness共用规则、无关工作区修改、其他任务与历史附件；不运行构建、测试、模拟器、真机、外部服务，不提交、推送、新建对话或worktree。
执行位置：当前对话，/Users/huyuanzhao/Coding/Projects/OpenMinis的main工作区。
设备与数据：无设备、账号、用户备份或业务数据操作。
首轮检查：Memory开关、GLOBAL授权及撤销/同步边界；再核对MCP与费用身份。文档静态检查及独立复审完成即停止，不扩展为产品修复或全功能运行验收。

## 目标与验收

- [ ] 补充MCP配置、发现/调用、传输、OAuth/秘密、启停、错误与资源边界。
- [ ] 补充上下文占用、token累计、会话费用与余额的独立定义和证据边界。
- [ ] 补充Skill导入/更新、会话覆盖、发现与读取、失败和删除契约。
- [ ] 补充Memory作用域、默认值、注入、读写、编辑、撤销、同步与已知冲突。
- [ ] 修订已有Spec中的不充分通用措辞与缺失关联，不把产品缺陷改写为约定。
- [ ] description和index一致、outline可解析、关键完整章节在预算内可读取、链接有效、whitespace通过。
- [ ] 固定文档和必要源码，完成独立只读复审及逐项处置。

## 上下文与决定

G01、G02、G03承接此前缺口；G03经本轮前调查确定为Skill与Memory两份独立Spec。文档区分维护要求、当前源码状态、已知缺口、待验证与待维护者决定。无需新增设计图：本任务仅治理文档，不修改产品模块、数据流或状态。不选择全面隐私隔离、自动化触发等未授权的新产品保证。

## Spec 阅读清单

全文必读：docs/harness/spec-authoring.md、docs/harness/spec-context.md、docs/specs/index.md、docs/specs/resource-efficiency.md，以及四份新增Spec。
关联必读：ios-provider-model-routing.md、ios-tool-permissions-and-side-effects.md、ios-sync-and-conflict-resolution.md、ios-agent-run-lifecycle.md、ios-backup-restore.md、minis-url-scheme.md、ios-sandbox-ish-summary.md的相关完整章节。
源码按需：MCPStore/MCPOAuthController与iOS挂载CLI，AIChatViewModel/Billing/MemoryTools/ToolDefinitions/SlashCommands，SkillStore、MemoryWriteRevoker、管理界面，V2 Memory/Skill hydrators，BackupExporter/Importer，DeepSeekBilling/BalanceClient/SessionCostLedger及相关测试入口。
不读取其他归档任务作为背景；以前对话中的调查仅作定位，关键声明以当前源码重核。

## 实现计划

- [x] 读取当前规则、分支、HEAD、索引，建立内容基线与本任务。
- [x] 核对源码与已有规范，撰写四份Spec和定向修订。
- [x] 生成索引，检查章节、完整抽取、链接、whitespace和保护文件。
- [ ] 独立只读复审、保存原始报告与处置。
- [ ] 记录有限文档验收、归档并建立本任务检查点。

## 进展与验证

已新增MCP、用量费用、Skill、Memory四份Spec，并修订七份直接关联文档及生成索引。index --check、11份outline、14处完整章节来源及预算核对、188处本地文件/锚点链接、12份文档whitespace检查通过。43份范围外基线文件保持不变；仅保存本轮开始时工作区到当前文档的补丁，不将HEAD全量diff归因本任务。章节正文经工具加引用前缀，检查以逐行同一来源对照，首次直接原文子串检查因包装不同失败后已纠正。

未执行产品运行验证。没有新增产品资源开销，无需性能采样；只读扫描和输出限于指定材料。

## Spec 同步

四份新Spec与七份既有Spec已同步，index新增四行，原有索引行保持不变。源description为唯一索引描述来源。新增Spec披露现状与缺口，不把待决定事项或源码路径提升为运行保证。

## 阻塞与纠偏

产品语义未决事项明确标记，不阻止披露现状；若关键源码或文档被并行修改，先核对变化后重新绑定受影响证据，保留他人改动。

## 审查

待固定材料后安排。根AGENTS指定全新gpt-6.1-sol/high；review-task及collaboration仍有旧Astra规则，本任务按更直接的根入口参数执行，不修改共用规则。
