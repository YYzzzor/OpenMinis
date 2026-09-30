# 缺失规范与跨文档契约独立审阅报告

审阅请求：`missing-specs-2026-09-30-001`。审阅对象为本目录 `manifest.json` 所标识的固定快照及 `current-task-only.patch`，不是动态工作区。快照定位信息为 `main`、HEAD `272da5d9bb8051c82075513df9a395344d4e7f6b`；文件内容身份以 manifest 中的 SHA256 为准。

审阅使用新建的 `gpt-6.1-sol / high` 独立审阅上下文，遵循根级 AGENTS 的参数要求。全程只读，没有修改文件，没有运行构建、测试、设备、网络请求或服务。

以下文件及行号均相对于 `snapshot/`；检查附件路径相对于审阅目录。

## 总体结论

发现 **3 项中等问题、2 项低等级问题**，未发现阻断或高等级问题。问题均属于本轮文档契约、静态实现描述或独立章节读取条件，需要定向修改文档。

四份新 Spec 对主要作用域和已知缺口的区分总体准确。特别是 MCP 的全局配置、会话覆盖与共享 daemon，Memory 关闭与一般文件访问的区别，Skill 元数据与附件安装状态，费用估算与账户余额，以及本地删除与跨设备删除之间的边界，均没有被直接升级为已验收产品能力。备份中的内联 MCP 凭证例外和缺少 Memory 删除传播的现状也有明确披露。

但是，Memory 专用工具章节在独立读取时缺少启用前提；Memory 同步章节遗漏实际出站记录的时间及格式门禁；DeepSeek 用量章节混用了原始总输入和归一化新输入。这三项会影响维护者依据 Spec 判断行为和编写验收条件。

## 发现

### R1 — 中：专用 Memory 读写章节独立读取时丢失会话启用前提

**位置：**

- `docs/specs/ios-memory-lifecycle.md:50–66`，尤其第 52 行。
- 相关正确说明位于同文档第 26–36 行，但不在专用读写、GLOBAL 权限及检索章节的祖先正文中。

**触发条件：** 仅读取“专用写入与GLOBAL维护权限”“GLOBAL维护权限”或“检索、排序与资源限制”章节，随后依据该段说明调用或修改专用 Memory 工具。

**问题与影响：** 第 52 行使用“memory_write只要求字符串content”，而检索章节直接描述 `memory_get` 的作用域和返回规则。独立读取这些章节时，读者无法取得当前会话必须开启 Memory 的前提，也无法明确区分关闭后的专用工具拒绝与仍可使用的一般文件路径。

“只要求字符串content”还容易把执行函数的参数解析范围误认为模型工具 schema 的全部必填参数。

**静态证据：**

- `src/ios/Agent/Chat/AIChatViewModel+MemoryTools.swift:64–71`：`executeMemoryWrite` 首先检查 `memoryEnabled`，关闭时返回失败；随后才解析字符串 `content`。
- 同文件第 126–135 行：`executeMemoryGet` 同样先检查 `memoryEnabled`。
- `src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift:30–37`、第 135–154 行：工具登记受启用状态控制；`memory_write` schema 的 required 包含 `tool_title` 和 `content`。
- `checks/ios-memory-lifecycle-50-context.txt`、`-56-context.txt`、`-60-context.txt` 的完整输出没有保留第 26–36 行的会话门禁，也没有在所选正文中直接链接该门禁章节。

**建议：** 在专用读写相关章节增加简短的当前会话启用前提，并链接“默认值、会话开关与生效时点”。将第 52 行改为区分“执行函数解析 content”与“模型工具 schema 的必填字段”，避免使用无条件的“只要求”。这是文档补全，不需要扩展为修改 Memory 产品行为。

---

### R2 — 中：Memory 同步规则遗漏每日记录的出站时间窗口和条目解析门禁

**位置：**

- `docs/specs/ios-memory-lifecycle.md:70`、第 74–80 行。
- `docs/specs/ios-sync-and-conflict-resolution.md:60–64`。

**触发条件：**

- 用户在设置页编辑日期早于出站窗口的日志；
- 用户保存一份非空、但没有可解析时间标记条目的日志；
- 用户在标记条目之前增加普通正文，并期望该正文随每日记录同步。

**问题与影响：** 文档描述编辑保存会请求 dirty，以及每日日志按时间标记做并集合并，但没有说明 dirty 不足以让这些日志生成出站记录。当前出站 builder 还受日期截止和条目格式限制。

因此，读者即使区分了“本地成功、入队、远端成功”，仍缺少判断“是否能够构建同步记录”的必要条件，也无法准确比较 Memory 备份和同步的内容范围。

**静态证据：**

- `src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift:1096–1101`：以当前时间减 30 个日历日计算截止时间；能解析为日期且早于截止时间的 `dateKey` 返回 `nil`。
- 同文件第 1106–1111 行：要求文件非空且 `parseMemoryEntries` 返回非空条目。
- 同文件第 1054–1086 行：只有在 `<!-- … -->` 标记之后形成的非空正文才成为条目；没有标记的正文不会形成出站条目，首个标记之前的正文也不会被编码。
- `src/ios/Views/Settings/MemoryManagementView.swift:309–312`：编辑保存请求 daily dirty，没有在该入口保证上述 builder 条件。
- `src/ios/Agent/Backup/BackupExporter.swift:683–706`：备份复制普通 Markdown 文件，范围不等同于每日同步 builder 的出站范围。

**建议：** 在 Memory 同步章节及既有同步 Spec 的 Memory 例外中补充：

1. 每日记录出站 builder 的当前日期截止条件；
2. 非空文件仍必须解析出至少一个标记条目；
3. 同步的是解析后的条目，备份复制 Markdown 文件，两者覆盖范围不同。

验收场景应包括旧日期日志和无标记正文。不要把这个出站窗口表述为接收端也执行同样过滤，或表述为历史内容已被自动删除；现有静态证据不支持这两项结论。

---

### R3 — 中：DeepSeek 用量段落混用原始总输入与归一化新输入

**位置：** `docs/specs/ios-usage-cost-and-balance.md:32`。

**触发条件：** 请求包含缓存命中，维护者按该段定义实现用量校验、费用计算或测试，尤其是缓存命中数大于新输入数的正常请求。

**问题与影响：** 同一段落先要求 `cache` 不超过 `input`，并校验 `miss = input - cached`，随后又定义“input表示新输入”。这两个 `input` 实际属于不同阶段：

- 校验中的 `input` 是 Provider 返回的总输入；
- 保存、计价中的 `inputTokens` 是扣除缓存后的新输入。

按当前文档统一理解为新输入，会把合法缓存请求判为不一致，或在归一化后再次扣除缓存。

例如，总输入 1,200、缓存命中 900、新输入 300 时，正确关系是 `900 ≤ 1200`、`300 = 1200 - 900`；如果 `input` 被理解为 300，当前段落中的两个校验关系都会失真。

**静态证据：**

- `src/ios/Providers/OpenAI/DeepSeekRequestUsage.swift:15–21`：读取原始 `prompt_tokens` 或 `input_tokens`，检查缓存不超过原始总输入，并用总输入减缓存核对 miss。
- 同文件第 22–23 行：构造结果时保存 `inputTokens: input - cached`。
- `src/ios/Providers/OpenAI/DeepSeekBilling.swift:117–120`：新输入与缓存输入分别计价。
- `src/ios/MinisTests/SessionCostLedgerTests.swift:106–113` 的测试源码使用总输入 100,000、命中 80,000、miss 20,000，并断言归一化输入为 20,000。第 128–134 行提供 Responses 的对应例子。这里只核对了测试断言，没有执行测试。

**建议：** 明确使用“原始总输入”和“归一化新输入”两个名称，并给出：

- `cached ≤ rawInputTotal`
- `freshInput = rawInputTotal - cached`
- 若提供 miss，则 `miss = freshInput`
- 新输入和缓存分别计价一次

保持现有“缺失或不一致字段不猜测为零”的原则。

---

### R4 — 低：新 Spec 的证据状态说明位于旁支章节，未随多数独立章节输出保留

**位置：**

- `docs/specs/ios-mcp-integrations.md:7–11`
- `docs/specs/ios-memory-lifecycle.md:7–11`
- `docs/specs/ios-skills-lifecycle.md:7–11`
- `docs/specs/ios-usage-cost-and-balance.md:7–11`

**触发条件：** 使用受控章节输出直接阅读某个行为章节，没有另行展开“范围、状态与来源”。

**问题与影响：** 四份文档都在第一个二级标题下说明静态实现日期、维护要求及未新增运行证据。该说明不是其他二级章节的祖先正文，因此多数本轮受控输出只有文档导航和所选章节，没有这一整体状态前提。

全文阅读时证据状态清楚；单独章节阅读时则容易丢失“这是静态实现描述而非运行验收”的总限定。部分章节具有自身的未运行措辞，但不能覆盖全部抽取范围。

**证据：**

- 已完整阅读的 MCP 第 23、29 行，Memory 第 50、56、60 行，Skill 第 31 行，以及用量第 34、52 行对应 context 输出没有包含上述整体状态正文。
- `docs/harness/spec-authoring.md:25` 要求作用域、定义和前提放在当前章节或祖先正文，旁支条件需要链接。
- `docs/harness/spec-context.md:71` 明确说明工具无法自动推断旁支依赖；当前输出符合这一限制，没有证据表明抽取工具发生故障。

**建议：** 将一条简短的整体范围和静态证据限定放到首个二级标题之前，保留具体源码入口和详细说明在现有章节。也可以在需要的章节增加明确链接。无需增加模型阅读证明机制或新的依赖账本。

---

### R5 — 低：MCP 非法启动超时值一律回落默认的描述过宽

**位置：** `docs/specs/ios-mcp-integrations.md:61`。

**触发条件：** CLI 配置中的 `startupTimeoutSeconds` 或兼容字段采用 `"NaN"`、`"Infinity"` 等能被 `float()` 接受、但不能转换为整数的字符串。

**问题与影响：** 第 61 行无条件说明“非法值回落默认并警告”。实际实现只覆盖了一部分非法值。对于非有限数值，整数转换位于异常捕获范围之外，会抛出异常，不能取得所描述的默认值及警告结果。

**静态证据：**

- `src/ios/default_mount/usr/local/lib/minis-mcp-cli/utils/config.py:151–155`：异常捕获仅包围 `float(raw)`；随后执行 `int(fvalue)`。
- 同文件第 157–160 行：正常整数转换后才执行范围检查并回落。
- `src/ios/default_mount/usr/local/lib/minis-mcp-cli/daemon.py:149` 调用该解析函数；第 440–442 行的通用异常路径返回 MCP 错误。
- `test_startup_timeout.py:91–99` 的测试源码覆盖普通错误字符串、空值、范围外值、小数和布尔值，没有覆盖上述非有限字符串；没有执行这些测试。

**建议：** 收窄文档保证，说明当前能够回落的非法值类别，并披露非有限值转换路径尚未受到同样保护。若维护者决定修复实现，应另行处理；本轮不应因发现该边界自动扩展产品修改范围。

## 实际阅读范围

### 完整阅读的文档与请求材料

已完整阅读：

- `request.md`、`manifest.json`、`current-task-only.patch`。
- `AGENTS.md`、`.agents/skills/review-task/SKILL.md`。
- `docs/harness/spec-authoring.md`、`docs/harness/spec-context.md`。
- `docs/specs/resource-efficiency.md`、`docs/specs/index.md`。
- `tasks/active/26-09-30 缺失 Spec 补全与冲突澄清/task.md`。
- 四份新 Spec：`ios-mcp-integrations.md`、`ios-memory-lifecycle.md`、`ios-skills-lifecycle.md`、`ios-usage-cost-and-balance.md`。
- 七份修改既有 Spec：`ios-agent-run-lifecycle.md`、`ios-provider-model-routing.md`、`ios-backup-restore.md`、`ios-sync-and-conflict-resolution.md`、`ios-tool-permissions-and-side-effects.md`、`ios-sandbox-ish-summary.md`、`minis-url-scheme.md`。

已完整阅读 `checks/results.json` 及以下 14 份受控章节输出，并与快照中的章节及前提位置核对：

- Agent 生命周期第 153 行；备份第 80 行。
- MCP 第 23、29 行。
- Memory 第 50、56、60 行。
- sandbox 第 68 行。
- Skill 第 21、31 行。
- 同步第 60 行；权限第 67 行。
- 用量第 34、52 行。

其他 outline 文件仅进行文件枚举，没有逐份阅读；未独立阅读 `checks/links.json`、`checks/index.txt`。没有把已有检查标签视为已阅读全文的证据，也没有重新运行这些检查。

### 源码核对范围

源码范围以相关符号和处理路径为单位；下列大型文件没有进行全部功能审查。

| 范围 | 实际核对内容 |
| --- | --- |
| MCP | `MCPStore` 的配置读取保存、导入导出、启停、会话覆盖、工具刷新、同步及删除路径；`MCPOAuthController` 的 Keychain、token、bridge 和授权路径；CLI main 的相关命令；完整 `daemon.py` 和 `utils/config.py`；HTTP transport 的连接、请求、重试及关闭相关段落。 |
| Memory | 完整 `AIChatViewModel+MemoryTools.swift`、`MemoryWriteRevoker.swift`；工具定义、SlashCommands、设置编辑与会话展示；ViewModel 的开关和注入调用点；同步注册、GLOBAL builder、每日条目解析、builder 与 merge；备份导出及恢复相关段落。 |
| Skill | `SkillStore` 的安装更新、附件处理、启停覆盖、删除、提示选择及同步相关段落；`SessionSkillsView`；并行工具使用记录；Skill 备份恢复和 hydrator 相关段落；独立 description stale 测试源码。 |
| 用量与费用 | 完整 `DeepSeekRequestUsage.swift`、`DeepSeekBilling.swift`、`SessionCostLedger.swift`、`AIChatViewModel+Billing.swift`、`DeepSeekBalanceClient.swift`、`UsageStatsView.swift`；SSE 登记与结束计价、TokenUsage、上下文身份发布、费用界面、数据库持久化相关段落。 |
| 测试源码 | 检索相关测试入口和断言；直接阅读了 `SessionCostLedgerTests.swift:103–138`、启动超时测试第 88–104 行等必要范围。所有测试均未运行。 |

没有完整审查 SystemPromptBuilder 的身份正文实现；SOUL 独立注入相关判断限于已读调用点、注释和当前 Spec 的边界说明。没有将源码中的处理路径、测试名称或断言当作已运行行为证据。

## 资源审阅与未验证边界

本轮补丁属于文档变化，没有新增产品运行路径，因此不存在由这些文档改动直接产生的 CPU、GPU、内存或能耗实测结论。

现有新 Spec 已区分 Memory 输出软限制与整文件扫描成本、Skill 附件下载与安装状态、MCP daemon 生命周期与连接池容量、余额缓存与网络字节限制。R2 遗漏的每日同步出站窗口同时也是需要补充的资源范围条件。

本报告未验证构建、测试通过、模拟器或真机行为、真实 iCloud 同步、OAuth 登录与凭证传播、MCP 副作用重试、设备文件竞态、Provider 官方账单、当前官方价格或真实账户余额。也没有独立重算全部 manifest 哈希、范围外基线、Git 状态、链接和字符统计。

已明确披露的产品缺口，包括 Memory 删除传播、GLOBAL 授权措辞、MCP 非幂等重试、费用实例归因和旧会话费用覆盖，不因本次审阅自动成为产品修复任务。本报告仅建议修订上述五项文档问题，不据此确认相关功能已通过运行验收。