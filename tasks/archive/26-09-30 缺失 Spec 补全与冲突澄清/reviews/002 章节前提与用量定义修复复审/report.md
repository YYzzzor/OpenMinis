# 章节前提与用量定义修复复审报告

审阅请求：`missing-specs-2026-09-30-002`。使用全新独立的 `gpt-6.1-sol / high` 审阅上下文，依据固定审阅目录中的 `request.md`、`manifest.json`、`original-report.md`、`fixes.patch` 和 `snapshot/` 进行只读复核。

固定材料目录：`artifacts/spec-reviews/2026-09-30-missing-specs/002 章节前提与用量定义修复复审/`。以下文档和源码行号均相对于该目录的 `snapshot/`。

已独立核验 manifest 所列 **17 份文件的 SHA256 和字节数，全部一致**；原报告 SHA256 也与 manifest 一致。

- `manifest.json` SHA256：`f9ded790a4373ba38c8dd9ead5843c36400a1b6a4d88108e9c81bbc7a6a75b98`
- `fixes.patch` SHA256：`93462488384c198f4c4b9acfe91b6f4122c1713aee84c408b9ff00b210d1fedc`

## 逐项结论

**R1 — 已充分解决。**  
`docs/specs/ios-memory-lifecycle.md:52` 明确区分当前会话 `memoryEnabled=true` 的登记与执行门禁、schema 必填字段 `tool_title/content`，以及执行函数解析 `content` 的范围。第 62 行同样补充专用读取门禁，并链接会话开关及一般文件工具、SOUL 的例外。

对应静态证据为 `AIChatViewModel+MemoryTools.swift:64–71、126–144` 和 `AIChatViewModel+ToolDefinitions.swift:30–37、135–156`。已实际阅读第 50、56、60 行三份完整章节输出；其中 GLOBAL 子节输出保留第 52 行祖先前提，检索输出保留第 62 行自身前提。自动注入章节第 44 行也补充启用条件。本项没有把 Memory 开关扩大为一般文件访问权限。

**R2 — 已充分解决。**  
`docs/specs/ios-memory-lifecycle.md:78` 明确披露可解析日期早于“当前时刻减 30 个日历日”cutoff 时不构建出站记录，区分上传过滤、历史删除、入站和备份；同时补充非空文件仍需解析出非空标记条目、首个标记之前及无标记正文的出站遗漏，以及入站重写不能保证保留普通文字。第 82 行说明备份处理 Markdown 文件，第 96 行补充可观察验收场景。

`docs/specs/ios-sync-and-conflict-resolution.md:62` 提供一致的摘要及定向链接。静态证据为 `ChatStoreSyncHydrators.swift` 的 `parseMemoryEntries:1054–1086`、`buildMemoryDaily:1096–1123` 和 `mergeMemoryDaily:1126–1198`，其中第 1184–1188 行区分无需重写与序列化重写。已实际阅读 Memory 第 74 行及同步第 60 行完整抽取；本地保存、dirty 与构建/上传记录之间的区别得到保留。没有新增接收端同样过滤旧日期或旧内容已经删除的保证。

**R3 — 已充分解决。**  
`docs/specs/ios-usage-cost-and-balance.md:32` 已区分响应原始总输入、缓存命中、归一化新输入，明确 `cached ≤ 总输入`、可选 `miss = 总输入 - cached`、`inputTokens = 总输入 - cached`，避免缓存重复计价。第 24 行允许全部登记请求完成计价后得到合法零总额，同时继续禁止将缺失字段或未计价请求伪装为零。

对应证据为 `DeepSeekRequestUsage.swift:12–30`、`DeepSeekBilling.swift:80–135`，特别是第 117–121 行分项计价；`SessionCostLedger.swift:4–8、17–23、37–52、57–92` 允许合法零值并以 `unpricedCount == 0` 决定总额可用性。已实际阅读用量第 15、26 行完整章节输出。本结论限于源码中的估算和账本规则，不证明 Provider 真实扣费或官方价格一致。

**R4 — 已充分解决。**  
四份新 Spec 的整体范围、静态状态及未运行限定均已移动到首个二级标题之前，即以下文件第 9 行：

- `ios-mcp-integrations.md`
- `ios-memory-lifecycle.md`
- `ios-skills-lifecycle.md`
- `ios-usage-cost-and-balance.md`

已实际阅读本轮全部九份完整 context 输出；每份输出均保留来源正文第 1–10 行。MCP、Memory、Skill 和用量的所选行为章节因此保留整体证据前提，符合 `spec-authoring.md:25、31–39` 和 `spec-context.md:71–73` 的要求。结论依据实际返回正文与源文档核对，没有以“已展开”标签替代阅读。

**R5 — 已充分解决。**  
`docs/specs/ios-mcp-integrations.md:61` 收窄默认回落保证，披露 `NaN/Infinity` 在整数转换阶段可能抛出异常，并明确不能保证任意畸形值回落或握手成功。

对应证据为 `config.py` 的 `resolve_startup_timeout:127–161`：第 151–154 行只捕获 `float(raw)` 转换错误，第 155 行的 `int(fvalue)` 位于该捕获范围之外。`daemon.py:149–151` 调用解析函数，`handle_request:440–442` 将传播的普通异常转换为 `MCP_ERROR`。已实际阅读 MCP 第 59 行完整抽取。这里确认的是解析函数异常边界，不意味着异常会导致整个 daemon 崩溃；文档没有作出这种新增保证。

## 新发现

在 **R1—R5 及五份文档定向修订** 的范围内，未发现需要编号为 R6 的新增阻断、高、中或低等级问题。该结论不能替代主 Agent 的最终验收，也不表示上轮披露的产品缺口或未修改功能已经通过运行验证。

## 实际覆盖与边界

已完整阅读请求、manifest、原报告、修复补丁，固定快照 `AGENTS.md`、`spec-authoring.md`、`spec-context.md`、`resource-efficiency.md`，以及五份修订文档全文。已完整阅读 `checks/results.json` 和九份章节输出：MCP 59；Memory 50、56、60、74；Skill 21；用量 15、26；同步 60。

源码仅核对请求列明的 Memory guard/schema、每日解析/构建/合并、DeepSeek 用量解析/估算/零账本、启动超时解析及 daemon 错误边界。没有重新审查其他功能；其余 outline、`checks/index.txt`、`final-current-task-only.patch` 未阅读。固定材料没有提供 review-task 技能正文，未为此读取动态仓库或其他归档。

本轮为文档修订，没有新增产品计算、请求、后台任务或 I/O 路径，产品运行时资源影响不适用。复核工具仅进行限定文件读取、行号定位和本地哈希核验；没有启动持续监测、服务或网络。章节输出实际保留必要前提；`checks/results.json` 记录的 1,671–2,894 字符、链接、索引和空白检查结果属于准备方证据，本次没有重新运行这些检查。

全程没有修改文件，没有运行构建、测试、模拟器、设备、网络或服务。没有验证真实同步、备份恢复、MCP 握手/OAuth、模型行为、当前官方价格、账户余额，以及 CPU、GPU、内存或能耗。已披露的 Memory 删除传播、GLOBAL 权限措辞和 MCP 重试等产品缺口继续保留。