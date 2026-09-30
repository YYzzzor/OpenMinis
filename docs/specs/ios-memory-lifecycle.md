---
description: MinisX iOS Memory 的全局与每日作用域、会话开关、上下文注入、读写检索、编辑撤销及同步删除限制；用于记忆功能与恢复变更。
---

# MinisX iOS Memory 行为与生命周期

导航：[Spec 索引](index.md)；文件地址见 [全局资源](minis-url-scheme.md#全局资源)，同步规则见 [同步与冲突处理](ios-sync-and-conflict-resolution.md)，包格式与事务见 [备份恢复](ios-backup-restore.md)。

范围：App 内作为持久背景知识的 Memory。它不是开发会话的记忆，也不是聊天历史的压缩摘要；旧内容不能当作新的用户指令。

## 文件与作用域

| 文件 | 用途 |
| --- | --- |
| `GLOBAL.md` | 跨会话的背景知识，自动注入完整内容。`memory_write` 不写它（维护权限见“待决定”）。 |
| `YYYY-MM-DD.md` | 跨会话的每日记录。`memory_write` 按本地日期写入，按时间标记把条目放在文件开头；不按会话建立私有日志。 |
| `SOUL.md` | 身份与人格资料，放在同一目录，但由 SystemPromptBuilder 单独构建，不受 Memory 开关控制。 |

- **F1** 目录通过 `/var/minis/memory` 和 `minis://memory/...` 访问，所有会话都能读取。
- **F2** 删除会话或清空聊天不删除全局 Memory。全局文件、历史工具结果、已发给 Provider 的内容，三者各自判断。
- **F3** 聊天中 memory 工具的记录只保存该次调用的输入和结果，不是 Memory 文件的唯一副本，也不代表条目归属。

## 默认值、会话开关与生效时点

- **S1** `memory.global.enabled` 默认 true，只决定新建会话的 `memory_enabled` 初始值；已有会话使用自己保存的值，不随全局默认变化。草稿首次保存、`loadSession` 都读回数据库中的值。
- **S2** `/memory` 修改当前会话的开关，已有会话时会持久化。
- **S3** 关闭后同时做到三点：Agent 循环开始和 fallback 重建时不注入 GLOBAL 与近期日志；不向模型提供 `memory_get` 和 `memory_write`；即使被调用，两个工具的执行函数也会拒绝，并返回失败和重新启用的入口。
- **S4** 关闭不影响一般文件工具，不卸载全局挂载，也不撤回聊天中已读取的内容；它不是全面的访问隔离或远端遗忘。
- **S5** Memory 开关的界面反馈准确描述 S3 的实际效果（现状见“待决定”）。

## 自动注入

- **I1** 只有 `memoryEnabled = true` 时才注入：GLOBAL 的全文（非空时）；近期日志最多回溯 30 天，选 3 份非空日志，每份取前 200 行，超出部分提示用 `memory_get` 搜索。天数和行数不是字符或 token 的硬上限；GLOBAL 没有行数限制。
- **I2** GLOBAL 注入时注明它是背景知识而不是长期指令；与用户最新消息冲突时，以最新消息为准。
- **I3** 写入或编辑后，下一次组装的 prompt 读取新内容；不保证写入后立即刷新当前请求的 system prompt。
- **I4** [SessionMemoryView](../../src/ios/Views/Chat/SessionMemoryView.swift) 的 “Auto-injected” 列表按当前磁盘内容重新计算，不是某次请求实际注入的记录。

## 写入

- **W1** `memory_write` 需要 `tool_title` 和 `content`，把 `<!-- yyyy-MM-dd HH:mm:ss -->` 时间标记加内容放到当天文件的开头。
- **W2** 成功后登记 fakefs 元数据、把 MemoryDailyV2 加入待同步队列（仍受 [同步启停](ios-sync-and-conflict-resolution.md) 前提控制），并广播 `memoryFilesDidChange`。成功只表示本地函数完成，不代表已上传、其他设备可见或模型已采用。
- **W3** 系统提示鼓励主动记录偏好和可复用的事实。修改 GLOBAL 需要用户明确要求，先读取、去重，再用 `file_edit` / `file_write`。
- **W4** 写入授权、覆盖、敏感内容处理遵守 [工具权限](ios-tool-permissions-and-side-effects.md)；“Memory 已启用”不代表授权删除或保存凭证。

## 检索

- **G1** `memory_get` 的 `scope` 默认 `all`：GLOBAL 加目录中其他非隐藏的 `.md` 文件；`daily` 只排除 GLOBAL，不限于日期命名的文件，所以 SOUL 等其他 Markdown 也可能被检索。
- **G2** 没有关键词时，按文件顺序最多返回 500 行。
- **G3** 有关键词时，按时间标记拆分条目，排序分数为“命中关键词的比例”与“时间新近程度”各占 50%。部分命中也会返回，不要求全部关键词都命中。
- **G4** 有关键词时最多返回 60 项；累计达到 30,720 字节（UTF-8）后，在加入完整一项后停止。这是软上限，一项很大时会超过它。
- **G5** 输出上限不约束扫描、整文件读取和候选构造的成本。超出上限、无匹配、无文件、已关闭四种情况分别提示。

## 用户编辑、撤销与跨设备删除

- **E1** MemoryManagementView 可以编辑 GLOBAL 和日志，保存后对相应类型加入待同步队列并通知界面。
- **E4** 有未保存的编辑时，文件变化不自动刷新编辑器，用户的输入不被覆盖。但保存时直接写回编辑稿，不比较版本也不合并：编辑期间文件若被 Agent 或同步修改，这些变化会被覆盖（见“待决定”）。
- **E2** 删除列表跳过 GLOBAL；删除其他文件只在本地删除，不发出 Memory 的云端删除。
- **E3** MemoryWriteRevoker 只搜索今天和昨天的日志，按去掉首尾空白后的内容匹配第一条，连同时间标记一起删除。它不按请求、会话或唯一条目 id 匹配：相同内容写过多次时可能删到另一条，超过两天返回“未找到”。成功只表示本地文件已改写，它不加入待同步队列，也不发变更通知。

### 同步合并与防复活缺口

- **Y1** GLOBAL 按文件 mtime 后写者胜；空或缺失的文件不产生同步记录，所以清空本地 GLOBAL 不会上传空值。
- **Y2** 每日日志按时间标记取并集合并。首次遇到同一时间、内容不同的远端条目时，以“时间#内容哈希”作为新键保留双方。删除某个条目无法通过“远端没有它”来表达。
- **Y6** 同一时间的冲突条目在重复合并时不应丢失（现状未满足，见“待决定”）。
- **Y3** 上传时跳过日期早于 30 天前的日志；这只是上传过滤，不删除本地或云端的旧日志，也不影响入站合并和备份。
- **Y4** 日志必须能解析出至少一条带时间标记的条目才会同步；第一个标记之前的文字和无标记的正文不上传。入站需要重写文件时，只写回解析出的条目，未标记的文字可能丢失。
- **Y5** 备份复制 Memory 目录中的 Markdown，恢复按包内文件处理，不做并集合并。历史备份可能包含已删除的内容。

## 待决定

- [待决定] S5 的缺口：[SlashCommands](../../src/ios/Agent/Chat/AIChatViewModel+SlashCommands.swift) 显示 “Memory writes disabled/enabled. Reads are unaffected.”，菜单副标题也只提写入，与 S3 中自动注入和专用读取也被关闭的实际效果不符。Memory 关闭的最终范围、运行中切换的生效时点，待决定。
- [待决定] GLOBAL 的维护权限：工具定义和注入文字称 GLOBAL 为 “read-only / user-maintained”，而基础系统提示允许经用户明确授权后由 Agent 编辑文件。这是提示措辞的冲突，不是系统层面的只读保护。只允许在设置页维护，还是保留授权后的 Agent 编辑，待决定。
- [待决定] 删除传播：MemoryGlobalV2 / MemoryDailyV2 没有注册删除处理，撤销、删除整份日志、清空 GLOBAL 都不会传播，旧副本可能把内容重新带回（Y1、Y2、E2、E3）。撤销的期限、唯一条目标识、跨设备传播、恢复旧备份后的删除语义，待决定。
- [待决定] 工具定义描述为 “all keywords / lines with context”，与 G3 的实际行为不一致。
- [待决定] `daily` 检索是否应排除 SOUL 和其他文件，以及文件、输出、扫描的资源上限（G1、G5）。
- [待决定] 草稿尚未保存时切换的临时开关，与首次创建会话时的值如何衔接（S1、S2）。
- [待决定] Y6 的缺口：[ChatStoreSyncHydrators](../../src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift) 合并时先把本地条目按时间标记放进字典，本地已有同一时间的两条（A、B）时只剩一条；远端再次合并 B 时条目数变少，文件被重写，A 丢失。这是数据丢失缺陷，不是允许的行为。
- [待决定] E4 的缺口：保存编辑稿时如何处理编辑期间文件的并发变化（版本比较、提示或合并）。
- [待决定] 主动记录日志是否维持当前的提示策略（W3 描述的是现状，不代表产品决定）。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 全局默认关闭，分别新建会话、加载已开启的旧会话 | 新会话不注入 GLOBAL 和日志，也没有专用工具；旧会话保持自己的值（S1、S3） |
| 关闭当前会话的 Memory 后触发 fallback | 初始请求和 fallback 请求都不注入，专用工具调用返回已关闭；普通文件路径和已有工具历史不受影响（S3、S4） |
| 用户明确要求维护 GLOBAL | 先读取并去重，只修改授权的内容（W3） |
| 正常写入后开始下一轮 | 时间标记和内容正确；下一次请求按注入规则读取；本地成功、加入队列、远端成功分别观察（W1、W2、I3） |
| 搜索部分命中的关键词、长条目，以及包含 SOUL 的范围 | 实际范围、条目排序、60 项与软字节上限都与规则一致；截断提示不冒称全文或全部关键词命中（G1–G4） |
| 相同内容写入两次，两天后撤销 | 表现符合“按内容匹配、只查近两天”的限制；错误可见（E3） |
| 编辑 30 天前的日志、无标记正文、首个标记之前的文字 | 本地保存和入队不代表已上传；按上传过滤和条目范围核对（Y3、Y4） |
| 在设置页编辑某日志时，Agent 写入同一文件，然后保存 | 编辑器未被自动覆盖；保存后核对 Agent 写入的内容是否丢失，按 E4 的缺口记录（E4） |
| 本地已有同一时间的两条冲突条目，远端再次同步其中一条 | 两条都保留（Y6；现状会丢失一条） |
| 设备 A 撤销某条，设备 B 保留旧日志后同步 | 检查并集是否把旧条目带回；删除传播实现之前，这是已知缺口（Y2，待决定） |
| 修改文件后查看 “Auto-injected” | 区分界面显示的当前文件与请求当时发送的版本（I4） |

## 代码入口

- 工具与注入：[MemoryTools](../../src/ios/Agent/Chat/AIChatViewModel+MemoryTools.swift)、[AIChatViewModel](../../src/ios/Agent/Chat/AIChatViewModel.swift)、[ToolDefinitions](../../src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift)
- 会话开关：[ChatStore](../../src/ios/Agent/Chat/ChatStore.swift)、[SlashCommands](../../src/ios/Agent/Chat/AIChatViewModel+SlashCommands.swift)
- 界面：[MemoryManagementView](../../src/ios/Views/Settings/MemoryManagementView.swift)、[SessionMemoryView](../../src/ios/Views/Chat/SessionMemoryView.swift)、[MemoryWriteRevoker](../../src/ios/Views/Chat/MemoryWriteRevoker.swift)
- 同步：[ChatStoreSyncHydrators](../../src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift)
