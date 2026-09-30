---
description: MinisX iOS 同步的启停、记录与文件生命周期、冲突合并、删除防复活、离线恢复和当前限制。
---

# MinisX iOS 同步与冲突处理

导航：[Spec 索引](index.md)；Provider 配置的业务语义见 [Provider 与模型路由](ios-provider-model-routing.md)；备份恢复不属于同步，见 [备份与恢复](ios-backup-restore.md)。

范围：本地业务对象如何转换为 `PortableRecord`，通过 transport 发送和接收，以及冲突、删除和离线恢复规则。

## 术语

| 术语 | 含义 |
| --- | --- |
| dirty 队列 | 本地持久化的待推送 upsert / delete 队列 |
| 记录身份 | `type:id`，同一逻辑记录在所有 transport 中一致 |
| 删除标记 | 用于传播删除和防止近期删除的内容复活；远端删除会话目前是本地硬删除，不再保留可见的软删除会话 |
| LWW | 记录级“后写者胜”，比较业务记录的 `updatedAt`；嵌套集合可以另有合并规则 |

## Transport

- **T1** 当前可用的 transport 是 iCloud shared zone。`LANTransport` 只是骨架，`SyncCore` 拒绝注册它。
- **T2** 同一 transport 不重叠发送。若将来注册多个 transport，每个都收到相同的记录流，一个成功不代表全部成功。

## 启停、离线与发送

- **Q1** 本地写入和加入 dirty 队列是两步。`ChatStore.markDirty` 只在同步 zone 已初始化、且 `UploadPolicy` 允许该记录类别时入队，否则直接返回。
- **Q2** 入队后默认等待约 3 秒合并突发写入，再发送。
- **Q3** Agent 流式运行、用户暂停发送、后台、蜂窝网络、限流都可以推迟发送，但不清除已有的 dirty 项；恢复后继续发送遗留的队列。
- **Q4** “暂停发送”保留已有的待发送项；“关闭类别”除此之外，还阻止该类别的新修改入队和入站变化的应用。关闭类别不删除云端已有的记录。
- **Q5** 发送结果的处理：

| 结果 | 本地处理 |
| --- | --- |
| success | 清除该记录的待发送状态，更新统计 |
| conflict（附带服务端记录） | 进入统一的入站合并，按记录规则决定保留哪一方 |
| 暂时性失败 | 保留 dirty 项，按 retry-after 或退避重试 |
| 永久失败 | 丢弃该 dirty 项并记录失败，不显示为“等待重试” |

## 记录兼容与冲突

- **R1** `PortableRecord` 携带 `schemaVersion`、可选的 `minimumCompatibleVersion`、`updatedAt` 和未知字段。
- **R2** 本地版本低于 `minimumCompatibleVersion` 时跳过应用，保留线上记录，不部分应用。
- **R3** 不认识的字段在写回时原样保留，旧客户端更新一次不会抹掉新客户端的字段。
- **R4** 一般记录按 `updatedAt` 后写者胜；时间相同或业务类型的例外由各自的 hydrator 明确处理，不依赖数组或接收顺序。
- **R5** Provider 模型组的成员为每个成员分别记录添加与移除时间，合并两端的意图，以该成员最近一次添加或移除为准；标量字段仍按记录更新时间处理。
- **R6** 入站批次分块处理、主动让出主线程，并对刚推送后回流的自身记录去重。这些是资源策略，不改变冲突结果。

## 上传类别

- **C1** 类别包括：会话、会话文件、Skills、Provider、环境变量、Memory，默认全部开启。已知类型在 [UploadPolicy](../../src/ios/Agent/Sync/V2/UploadPolicy.swift) 中映射到类别；入站合并和删除处理使用同一套开关。
- **C2** 未知的记录类型允许通过并记录警告，这是为了向前兼容（见“待决定”）。新增类型必须补充类别归属和测试。
- **C3** 单个同步文件默认上限 1 MB；超出时产生可观察的跳过或错误，不静默声称已同步。
- **C4** Provider V3 记录包含实例、模型条目、模型组和 thinking 规则。凭证是否在设备上可用要单独判断；元数据同步成功不代表另一台设备已有可用的 Keychain 或 OAuth 状态。

### Memory 合并与删除例外

- **M1** GLOBAL 按文件 mtime 后写者胜；每日日志按时间标记取条目并集。远端缺少某条目不代表删除。上传的过滤与格式限制见 [Memory 生命周期](ios-memory-lifecycle.md#同步合并与防复活缺口)。
- **M2** MemoryGlobalV2 和 MemoryDailyV2 没有注册删除处理，无处理器时保留本地内容。下文会话的防复活机制不适用于 Memory：本地清空、撤销或删除不保证其他设备也删除，旧内容也可能回流。

### Skill 与 MCP

- **K1** SkillV2 传输全局启用状态、正文和可选附件；MCPServerItem 按 server 保存配置 JSON，其中内联的 `headers` / `env` / `url` 原样保留。OAuth 的 Keychain 秘密不在普通记录中，但这不代表 MCP 配置中没有秘密。
- **K2** Skill 和 MCP 的会话覆盖保存在各自的本地 SQLite 中，不同步。本机已启用、元数据已同步、另一台设备有凭证、运行中的连接，四者分别判断。见 [Skill 生命周期](ios-skills-lifecycle.md#全局启停与会话覆盖) 和 [MCP 集成](ios-mcp-integrations.md#内联凭证与同步备份例外)。

## 删除与防复活

- **D1** 本地删除会话时，先把会话及其子记录的云端删除加入队列，再删除本地的消息、压缩标记、媒体等，并写入保留 30 天的近期删除标记。删除传播完成前，时间不比删除更新的旧云记录回流时被拒绝。
- **D2** 部分单记录类型也有近期删除标记；是否生效取决于该类型是否排队删除、检查防复活并注册了删除处理，不能推断所有类别都已覆盖。
- **D3** 恢复导入需要有意重建同一 id 时，走恢复专用的清理路径，不普遍关闭防复活保护。
- **D4** 远端删除 `SessionV2`：在本机硬删除会话及子数据，不创建软删除，也不把同一删除再排队回云端。
- **D5** 远端删除 Message、CompactMarker 等：直接删除对应的本地记录，不产生回声。
- **D6** 远端删除 Folder：解散文件夹，清除成员的 folder id，不删除成员会话。
- **D7** `TombstoneManager` 的名称和数据库中旧的 `remote_tombstoned_at` 列是历史遗留，不代表仍采用软删除。

## 全量拉取

- **F1** `fullFetchAndReconcile()` 请求全量批次，但**不会**把本批中没有出现的本地会话判定为云端已删除，因为 CloudKit 返回的批次可能不完整；日志注明 “reconcile skipped”。显式的远端删除照常应用。

## 用户可见状态

- **U1** 同步界面至少区分：未启用、启动或拉取中、已暂停、有待发送、限流或暂时失败、永久失败，以及最近一次成功的时间。“同步已开启”不代表队列已清空。
- **U2** “删除 iCloud 数据”与“关闭同步”不同。执行前说明：本地副本是否保留、本设备是否会重新上传、其他设备何时失去云端副本。

## 待决定

- [待决定] 同步 zone 初始化之前、或类别关闭期间的本地修改，之后如何补扫、入队和传播（Q1、Q4）。
- [待决定] 未知记录类型默认允许，是否符合长期的隐私和分类策略（C2）。
- [待决定] 永久失败后是否提供可恢复的手动重试入口（Q5）。
- [待决定] 能证明集合完整的安全全量对账，以及 LAN transport（F1、T1）。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 同步 zone 已初始化、类别开启时离线修改，之后恢复网络 | 本地记录和 dirty 项先持久化；重启或恢复网络后继续发送；成功前界面不显示为已完全同步；同一记录不会被重复调度并发覆盖（Q1–Q3、U1） |
| 两台设备修改同一记录 | 一般记录按 `updatedAt` 后写者胜；未知字段保留；版本过低的客户端跳过应用；并发添加不同的模型组成员时都保留，较新的移除胜过较早的添加（R2–R5） |
| 设备 A 删除会话，设备 B 仍有旧副本 | A 排队删除并写入近期删除标记；旧副本在窗口内回流不复活；B 收到远端删除后会话与子数据消失，且不回写同一删除（D1、D4） |
| 用户关闭某个同步类别 | 之后该类别既不上传也不应用入站变化；云端已有记录不被删除；重新开启后分别核查补拉和本地补传（Q4，待决定） |
| 全量拉取只返回了部分结果 | 本批没有出现的本地会话不被删除；显式删除仍然应用；日志说明跳过了对账（F1） |

## 代码入口

- 核心与 transport：[SyncCore](../../src/ios/Agent/Sync/V2/SyncCore.swift)、[PortableRecord](../../src/ios/Agent/Sync/V2/PortableRecord.swift)
- 类别与文件上限：[UploadPolicy](../../src/ios/Agent/Sync/V2/UploadPolicy.swift)
- 业务记录转换：[ChatStoreSyncHydrators](../../src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift)、[SyncCoreHydrators](../../src/ios/Agent/Sync/V2/SyncCoreHydrators.swift)
- 删除：[TombstoneManager](../../src/ios/Agent/Sync/V2/TombstoneManager.swift)、[ChatStore](../../src/ios/Agent/Chat/ChatStore.swift)（`markDirty`、删除标记）
