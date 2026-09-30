---
description: MinisX iOS 同步的启停、记录与文件生命周期、冲突合并、删除防复活、离线恢复和当前限制。
---

# MinisX iOS 同步与冲突处理

导航：[Spec 索引](index.md)；Provider 配置的业务语义见 [iOS Provider 与模型路由](ios-provider-model-routing.md)；备份恢复不属于同步，见 [iOS 备份与恢复](ios-backup-restore.md)。

状态：现行数据安全约定与 2026-09-29 当前实现并列记录。源码核查覆盖 [SyncCore.swift](../../src/ios/Agent/Sync/V2/SyncCore.swift)、[PortableRecord.swift](../../src/ios/Agent/Sync/V2/PortableRecord.swift)、[UploadPolicy.swift](../../src/ios/Agent/Sync/V2/UploadPolicy.swift)、[ChatStoreSyncHydrators.swift](../../src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift)、[TombstoneManager.swift](../../src/ios/Agent/Sync/V2/TombstoneManager.swift) 和 [ChatStore.swift](../../src/ios/Agent/Chat/ChatStore.swift)。本轮没有连接 iCloud 或运行多设备验证。

## 范围和术语

同步把本地业务对象转换为 transport-neutral `PortableRecord`，通过已注册 transport 推送或接收入站批次。当前可用实现是 iCloud shared zone；`LANTransport` 仍是骨架，`SyncCore` 会拒绝注册，不能作为现行能力宣传。

- **dirty queue**：本地持久化的待推送 upsert/delete 队列；App 退出或暂缓发送不应丢失。
- **record identity**：`type:id`，同一逻辑记录跨 transport 保持一致。
- **tombstone**：本文主要指传播删除或近期删除防复活标记；当前远端 Session 删除是本地硬删除，不再保留可见的软删除会话。
- **LWW**：记录级 last-write-wins，以业务记录 `updatedAt` 比较；不意味着所有嵌套集合都只做整记录覆盖。

## 启停、离线与发送

本地业务写入与 dirty 入队是两步。当前 `ChatStore.markDirty` 只有在同步 zone 已初始化且 `UploadPolicy` 允许该记录类型时才入队；未初始化或类别关闭会直接返回，不能宣称每次本地写入都已留下待发送项。已入队的修改默认约 3 秒合并突发写入，再发送。

Agent 流式运行、用户暂停发送、后台、蜂窝网络或限流可以延迟发送，但不应清除已有 dirty；恢复发送后应继续排空遗留队列。暂停发送与关闭类别不同：前者保留既有待发送事实，后者还会阻止符合该类别的新修改经上述路径入队。

初始化前或类别关闭期间发生的修改，之后如何补扫、入队和传播必须另行核查；不能只用“队列排空”证明这些修改已经同步，也不能仅凭早退推断永久不补传。本轮未运行重开补齐场景，其覆盖范围保持待验证。

同一 transport 不允许重叠发送。若未来注册多个真实 transport，每个 transport 接收相同 `PortableRecord` 流；不能假设其中一个成功等于所有 transport 成功。

发送结果的处理规则：

| 结果 | 本地处理 |
|---|---|
| success | 清除该 transport/记录的待发送状态，并更新可观察统计。 |
| conflict，携带 server record | 进入统一入站合并，再由记录规则判断保留哪一侧。 |
| transient failure | 保留 dirty，遵守 retry-after/退避后重试。 |
| permanent failure | 当前发送管线会丢弃该次 dirty 项并记录失败；调用方不得继续显示为“等待重试”。 |

暂停同步不是撤销本地修改，也不是删除云端内容。关闭某一上传类别会同时阻止该类别后续出站和入站应用；已有云端记录不会因开关关闭而自动删除。

## 记录兼容与冲突规则

`PortableRecord` 必须携带 `schemaVersion`、可选 `minimumCompatibleVersion`、`updatedAt` 及未知字段。规则如下：

- 本地版本低于 `minimumCompatibleVersion` 时跳过应用，保留线上记录，不以部分字段强行降级。
- 本地不认识的字段写回时必须 round-trip，旧客户端不能因一次更新抹掉新客户端字段。
- 通用记录以 `updatedAt` 做 LWW；相同时间或具体业务类型的例外由 hydrator 明确处理，不能靠数组顺序或接收顺序猜测。
- Provider 模型组成员不是简单整数组 LWW：每个成员维护 add/remove 时间，合并两端意图后，以该成员最近一次添加或移除决定是否存在；标量字段仍按记录更新时间处理。

入站批次分块、主动 yield，并对刚推送后短时间回流的自身 echo 去重，以减少主线程和无意义 reload。它们是资源策略，不改变最终冲突语义。

## 上传类别与范围

当前策略类别包括会话、会话文件、Skills、Provider、环境变量和 Memory，默认开启。已知类型在 [UploadPolicy.swift](../../src/ios/Agent/Sync/V2/UploadPolicy.swift) 映射到类别；入站 merger 和 deletion applier 使用同一 gate。

当前实现对未知 record type 选择允许通过并记录警告。这是前向兼容取舍，不是已证明安全的默认：新增类型必须补充类别归属和测试，否则可能绕过用户预期的分类开关。单个同步文件当前默认上限为 1 MB；超过限制必须产生可观察跳过/错误，不能静默声称已同步。

Provider V3 同步记录包含实例、模型条目、模型组和 thinking rule。凭证可用性是设备侧运行前提；元数据同步成功不保证另一台设备已有可用 Keychain/OAuth 状态。

### Memory合并与删除例外

当前[V2 hydrators](../../src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift)对GLOBAL文件采用mtime LWW，对每日日志采用时间标记条目并集，同时间不同内容有保留双方的路径。日志不是通用整文件LWW；不能将远端缺少条目解释为删除。出站每日日志受30个日历日前cutoff过滤，并仅传输可解析的非空时间标记条目；无标记文本不会随整文件上传，入站重写也不保证保留。具体过滤与格式例外见[Memory同步范围](ios-memory-lifecycle.md#同步合并与防复活缺口)。

MemoryGlobalV2和MemoryDailyV2当前未注册deletionApplier，[SyncCoreHydrators](../../src/ios/Agent/Sync/V2/SyncCoreHydrators.swift)的无处理器fallback保持本地内容。GLOBAL为空或缺失时builder返回nil；设置页删日志和撤销写入也没有完整的Memory删除传播路径。因此下文会话/单记录防复活机制不得自动套用于Memory；本地清空、撤销或删除不保证其他设备删除或旧内容不再回流。作用域、编辑与验收见[Memory生命周期](ios-memory-lifecycle.md#同步合并与防复活缺口)，条目删除、整文件删除与恢复旧备份的产品语义仍待决定。

### Skill与MCP的配置范围

SkillV2传输全局启用状态、正文及可选附件；MCPServerItem按server保存配置JSON，包含其中原样内联的headers/env/url值。OAuth Keychain秘密不在该普通记录中，不意味着任意MCP配置都没有秘密。两者会话覆盖仍在本地各自SQLite，当前业务同步记录没有传输这些覆盖；本机已启用、元数据已同步、另一设备已有凭证和运行连接必须分别判断。详见[Skill生命周期](ios-skills-lifecycle.md#全局启停与会话覆盖)和[MCP凭证例外](ios-mcp-integrations.md#内联凭证与同步备份例外)。

## 删除与防复活

### 本地删除

本地删除会话时，当前实现先排队会话及子记录的云端 delete，再删除本地消息、compact marker、媒体等，并写入 30 天 recent-delete 标记。删除传播完成前若旧云记录回流，时间不新的记录应被拒绝，防止刚删除的内容复活。

部分单记录类型也有近期删除标记；其作用取决于该类型是否排队delete、执行防复活检查并注册删除处理器，不能由通用机制推导所有类别已覆盖。Memory例外见[上节](#memory合并与删除例外)。恢复导入若要有意重新创建同 id，必须走恢复专用清理路径；不能普遍关闭防复活保护。

### 远端删除

- `SessionV2` delete 在本机硬删除会话及其子数据，不再创建可见软 tombstone，也不把同一 delete 重新排队回云端。
- Message、CompactMarker 等记录的远端 delete 直接删除对应本地记录，不产生 delete 回声。
- Folder delete 解散文件夹关系，清除成员的 folder id；它不删除成员会话。

`TombstoneManager` 名称为历史延续，数据库仍可能有旧 `remote_tombstoned_at` 列。维护者不能由类型名推断当前仍采用软删除。

## 全量拉取和对账限制

当前 `fullFetchAndReconcile()` 会请求 full batch，但**不会**把“本批未出现的本地会话”判为云端已删除。原因是 CloudKit 返回批次可能并不完整；若把部分批次当全集，会误删本地数据。日志会明确标注 reconcile skipped。

因此当前可以确认的语义是：收到显式远端 delete 时应用删除；不能确认“云端缺失一定会清理本地幽灵记录”。这是已核实的实现限制，不应在文档中改写成最终一致性承诺。

## 用户可见状态与恢复

同步 UI 至少应区分：未启用、启动/拉取中、已暂停、dirty 待发送、限流/暂时失败、永久失败和最近成功时间。仅显示“同步开启”不能证明队列已排空。

“删除 iCloud 数据”与“关闭同步”不同。执行前必须说明本地副本是否保留、当前设备是否会重新上传、其他设备何时失去云端副本；这些产品文案与实际实现仍需单独运行核验，本文不把设置页描述当作已完成证据。

## 场景与验收

### 场景 A：离线修改后恢复网络

前提：同步 zone 已初始化，对应记录类别开启；否则先按[启停、离线与发送](#启停离线与发送)核查未入队期间的补齐。

本地记录和 dirty 项先持久化；重启或恢复网络后队列继续发送；成功前 UI 不显示为完全同步；同一记录不会因重复调度并发覆盖。

### 场景 B：两台设备修改同一记录

对普通记录按 `updatedAt` LWW；未知字段保留；版本低于 minimum compatible 的客户端跳过应用。模型组并发添加不同成员时两者都保留，较新的成员删除应胜过更早添加。

### 场景 C：设备 A 删除会话，设备 B 仍持有旧副本

A 排队显式删除并写 recent-delete；旧副本在删除窗口内回流不得复活；B 收到远端 delete 后本地会话和子数据消失且不向云端回写同一删除。

### 场景 D：用户关闭某同步类别

之后该类别既不上传也不应用入站变化；云端既有记录不被自动删除。记录关闭期间的本地修改，以及它们是否经 `markDirty` 入队；重新开启后分别核查补拉和本地补扫/上传，不能只观察已有队列。具体补齐范围应有可观察状态并用真实 iCloud 测试确认，当前仍待验证。

### 场景 E：full fetch 返回部分结果

本地未出现在本批中的会话不得仅因此被删除；明确的 delete 仍应应用。日志或诊断能说明对账被跳过，而不是伪报全量一致。

## 待验证与待确认

- 待验证：真实 iCloud 多设备冲突、断网重启、限流/永久失败、类别开关重开、文件超限、删除传播和 App 被回收后的 dirty 恢复。
- 待确认：未知 record type 默认允许是否符合长期隐私/分类策略；永久失败后是否需要可恢复的人工重试入口。
- 待实现或另案设计：可证明完整集合的安全 full-fetch reconciliation，以及 LAN transport。
