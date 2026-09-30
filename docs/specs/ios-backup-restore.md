---
description: iOS .minisbak 的格式兼容、备份范围、凭证加密、完整性、不完整结果、恢复事务与回滚契约。
---

# iOS Backup and Restore

导航：[Spec 索引](index.md)。

状态：现行格式和行为契约。本文补足源码曾引用但仓库缺失的 `backup-restore-design.md`；[backup-streaming-package-design.md](../backup-streaming-package-design.md) 是分阶段设计资料，只有已由当前源码确认的部分才构成现状。

## 范围与来源

本文适用于用户创建、恢复、分享、迁移或诊断 `.minisbak` 包的场景，覆盖格式兼容、类别、加密、完整性、不完整结果、恢复和中断恢复。

源码依据：

- [BackupFormat.swift](../../src/ios/Agent/Backup/BackupFormat.swift)：wire format 与类别。
- [BackupExporter.swift](../../src/ios/Agent/Backup/BackupExporter.swift)：快照、导出、加密、续传和结果报告。
- [BackupImporter.swift](../../src/ios/Agent/Backup/BackupImporter.swift)：检查、预检、分类恢复和报告。
- [BackupRestoreJournal.swift](../../src/ios/Agent/Backup/BackupRestoreJournal.swift)：持久 rollback staging 与启动协调。

本轮没有实际打包或恢复用户数据；运行正确性只能由定向测试和受控样本验证。

## 包格式与兼容

- 扩展名为 `.minisbak`，当前 major format 为 `minisbak/1`。
- 不认识 major version 的 reader 必须拒绝并提示更新，不能 best-effort 写入用户数据。
- 同一 major 内，未知字段应忽略；非结构必需的缺失字段使用兼容默认值。
- 记录以类型 `t` 和记录版本 `v` 支持分类解析和逐记录迁移。
- JSONL shard 最大 64 MiB，超出后滚动到下一 shard，避免 importer 一次加载巨型文件。
- `manifest.json` 始终明文，允许用户在输入密码前查看来源、时间、类别和计数。

manifest 至少承载 format、创建/快照时间、App 信息、显示用设备名、backup id、类别统计、限制、加密说明和内容完整性哈希。不得写入会导致两台设备争用同步身份的内部 device id。

## 备份范围

当前 wire format 类别：

| 类别 | 当前普通 UI 新导出 | 兼容恢复 |
|---|---|---|
| chats | 是 | 是 |
| shared_files | 是 | 是 |
| skills | 是 | 是 |
| memory | 是 | 是 |
| providers | 是 | 是 |
| mcp_servers | 是 | 是 |
| environment_variables | 是，仅条目元数据；值另走凭证路径 | 是；值依赖 providers 凭证恢复或本地已有 Keychain 值 |
| voice_corrections | 否；显式选择类别的调用仍可导出 | 是，兼容旧包及显式导出包 |

所有可导出类别的 UI 默认选中是当前实现。文件型类别可以应用单文件上限；默认是不限，而不是静默丢弃大文件。无法下载的 iCloud placeholder、超限文件或快照竞态造成的缺失 blob 必须进入 manifest/index 和最终报告，不得把不完整导出显示成完整成功。

类别选择不等于其中的凭证已包含。环境变量、Provider 和 MCP OAuth 的依赖见[凭证与加密](#凭证与加密)；普通 UI 未提供 `voice_corrections`，但 exporter 保留显式选择该类别的路径，不能假设所有新包均无此类别。

### 截止时间与快照范围

当前导出续跑保留原 `snapshotAt`，不把时间字段推进到重试时刻；聊天导出用它筛选会话和消息。它不是所有类别的历史版本快照：[BackupExporter.swift](../../src/ios/Agent/Backup/BackupExporter.swift) 的 Memory 复制当前文件，Provider 和环境变量读取执行当时的 store，已完成类别在续跑时跳过，尚未完成类别则继续执行。

因此，中断期间发生修改时，包中可能混合不同类别在不同时间取得的内容。调用方不得仅凭 manifest 的时间未变宣称跨类别一致快照，也不能把 activity lock 当作所有用户编辑均被冻结。是否需要统一的跨类别快照，以及其一致性范围，仍待维护者确认；本轮未做中断续跑运行验证。

## 凭证与加密

- 敏感凭证只能在用户选择包含凭证且提供非空 passphrase 时进入包。当前 exporter 的实际凭证条件是选择 `providers` 类别且 `includeCredentials = true`；这个组合没有密码时必须拒绝。单独设置 `includeCredentials` 或密码不保证包内有凭证。
- 用户不提供 passphrase 时，可以关闭凭证生成 share copy；环境变量类别仍可含条目元数据，但不因此包含值。
- passphrase 不持久化。加密导出恢复执行时必须再次提供，不能因为存在 staging 就降级生成明文包。
- 内容文件加密后，integrity 记录包内实际字节的 SHA-256，即密文哈希，因而可在知道密码前发现截断或损坏。
- 加密包使用 verifier 区分错误密码，并使用 manifest MAC（优先校验 `manifest.mac` 原始字节 sidecar）认证 manifest。
- `manifest.json` 保持明文不代表凭证明文；敏感 payload 必须只出现在加密成员中。

当前类别与凭证依赖：

| 内容 | 导出前提 | 恢复前提 |
|---|---|---|
| 环境变量名称、备注等条目元数据 | 选择 `environment_variables`；写入 `env_vars.json`，不包含值 | 选择 `environment_variables`；已有条目保留，新条目从 Keychain 取值，缺值时为空 |
| Provider 凭证、环境变量值、MCP OAuth | 选择 `providers`、包含凭证并提供密码；[BackupSecrets.swift](../../src/ios/Agent/Backup/BackupSecrets.swift) 收集当前可取得的值进入 secrets | 包含并选择 `providers`，完成密码验证和解密后由其 importer 应用 secrets；不是选择环境变量或 MCP 类别就会应用 |

凭证集合目前归在 `providers`，会包含收集到的环境变量值和 MCP OAuth，即使对应元数据类别未选。要迁移环境变量条目和值，应同时选择 `environment_variables` 和含凭证的 `providers`；仅环境变量的加密包仍可能只有元数据。恢复完整包时只选环境变量也不会应用包内 secrets；本地已有值可能使结果看似完整，验收应使用目标设备没有这些值的样本。

[BackupImporter.swift](../../src/ios/Agent/Backup/BackupImporter.swift) 把选中的 providers 排在环境变量前，避免创建新条目时读不到刚恢复的值；它不自动补选依赖类别。这是当前实现依赖，不是类别间可独立完整迁移的承诺；是否保留该耦合仍待维护者确认。

### 内联MCP凭证与分享副本限制

上述密码与includeCredentials前提覆盖专用secrets导出路径，不是对所有类别内容的自动秘密检测或脱敏保证。[BackupExporter.exportMCPServers](../../src/ios/Agent/Backup/BackupExporter.swift)直接复制servers.json；headers/env/url里的内联token可能进入mcp_servers类别，即使未选择providers或关闭includeCredentials。未提供密码时该复制路径也不检查或移除这些值，故当前实现不全面满足“敏感凭证只进入加密成员”的安全要求。

MCP JSON分享导出同样保留原值。share copy只能解释为未包含专用secrets，不能称为完全无凭证或自动安全脱敏；其他任意文件中的敏感内容也不能由类别开关推导已清除。可观察验收使用占位测试值检查各成员，不输出真实秘密；内联凭证拒绝/脱敏/强制加密方案待维护者决定，产品缺口未在本轮修复。凭证和设备授权边界见[MCP集成](ios-mcp-integrations.md#内联凭证与同步备份例外)。

### Skill、Memory与费用恢复范围

Skill元数据/附件恢复不代表session_skill_overrides或use_count已迁移；当前新格式SkillRecord没有这些字段。Memory恢复复制包中的Markdown文件，不采用日志同步的并集合并，也不能保证此前撤销的条目仍然缺失。会话费用专用账本未包含在当前新格式聊天记录中，恢复聊天不应显示为已恢复完整费用历史。分别见[Skill](ios-skills-lifecycle.md#全局启停与会话覆盖)、[Memory](ios-memory-lifecycle.md#用户编辑撤销与跨设备删除)与[费用](ios-usage-cost-and-balance.md#展示与持久化边界)。

## 导出完成与可恢复中断

- Export 与 restore 由进程级 activity lock 互斥；不能同时修改共享数据/staging。
- 新的无密码、非续跑导出当前可直接把 blob 流入包；加密或续跑仍可能使用 staging。这是实现策略，不是调用方可依赖的包格式差异。
- 干净完成后清理对应 journal/staging。取消、进程退出或可恢复中断应保留恢复所需的 staging，并由后续尝试按相同范围、限制和加密策略认领。
- 当前续跑匹配类别集合、单文件上限、包含凭证开关和加密意图，并沿用原 backup id 与 `snapshotAt`；不匹配的旧 staging 不得拼进新包。选项匹配只决定能否认领 staging，不保证尚未完成类别的源内容未变化，见[截止时间与快照范围](#截止时间与快照范围)。
- 最终结果必须报告包大小、完成类别、续跑类别以及 skipped file/byte/path；“归档文件已生成”不等于“所有源数据都已包含”。

## 恢复顺序与事务边界

规范顺序：

1. 安全解包到临时工作目录；拒绝 ZIP 路径逃逸和符号链接逃逸。
2. 读取 manifest 并检查 major format。
3. 默认先按包内字节校验 integrity。
4. 若加密，要求 passphrase，校验 verifier 和 manifest MAC，再解密。
5. 执行容量、运行会话和类别等 preflight。
6. 对每个类别建立持久 rollback snapshot，按依赖顺序导入。
7. 刷新相关 store，返回分类报告和 warning。

步骤 6 的类别选择必须同时核对[凭证与加密](#凭证与加密)中的依赖。选择环境变量元数据不等于选择包内 secrets；成功类别数不能代替值完整性的核查。

当前事务边界是“每个类别”：某类别失败时回滚该类别，已经成功的前序类别保留，然后继续/报告其他类别。UI 和调用方不得把部分成功显示成全有或全无。

rollback snapshot 必须位于非临时、不会随解包工作目录删除的位置；若 App 在恢复中被终止，下一次启动可根据 journal 调和孤儿 staging。结束标记不能先于数据真正稳定落盘。

## 合并与冲突

当前 importer 以 merge 为主；会话 id 冲突可选择合并或复制为新会话。恢复凭证时，本地已存在的凭证应保留，旧备份不得静默覆盖用户后来轮换的 key。

顺序、会话消息与 compact marker 必须保持引用一致；聊天类别内部要先建立会话，再导入引用它的消息/文件。未知类别或记录版本的行为必须遵守格式兼容策略并进入 warning，不能产生看似成功的空恢复。

## 场景与验收

### 场景 A：包含凭证但未设置密码

前提：选择 providers 且开启包含凭证。仅选择环境变量元数据不触发这一凭证组合，见[凭证与加密](#凭证与加密)。

可观察验收：导出在写出可分享包前拒绝；界面说明设置密码或关闭凭证；磁盘上没有含明文凭证的残留包。

### 场景 B：加密包损坏或密码错误

可观察验收：截断/篡改成员先在 integrity 阶段失败；完整包的错误密码得到密码错误而不是“数据损坏”；在任何失败下都没有部分应用业务数据。

### 场景 C：部分文件不可用

前提：源文件超限、iCloud 未下载或索引后 blob 消失。

可观察验收：导出报告列出 skipped/missing 原因和数量；恢复报告不会把 tombstone 当成已恢复文件；用户在删除旧设备数据前能识别备份不完整。

### 场景 D：恢复中途被终止

可观察验收：已开始类别存在持久 snapshot/journal；下次启动能够回滚或调和，不把半写目录当成成功；其他并发 restore 不会误删它的 staging。

### 场景 E：格式兼容

可观察验收：未知 major 被拒绝；`minisbak/1` 的未知字段被忽略；缺少可选字段仍按默认值读取；普通 UI 新备份不提供 `voice_corrections`，旧包或显式选择该类别导出的包仍可恢复。

### 场景 F：顺序和覆盖

可观察验收：恢复后会话消息顺序与备份一致，compact marker 引用有效；已存在本地凭证保持不变并在报告中标记 kept。

### 场景 G：只迁移环境变量

前提：源设备有带值的变量，目标样本没有同名条目或 Keychain 值。

可观察验收：仅导出/恢复环境变量时能看到条目，但不能报告值已迁移；同时导出环境变量与含凭证 providers 并在恢复时选择两者，才按实际恢复后的值核查完整性。给仅元数据包设置密码不会补出值；完整包仅选环境变量恢复也不会应用 secrets。既有目标条目和值仍保留，不用覆盖旧值来伪造成功。

### 场景 H：中断期间修改未完成类别

前提：使用可丢弃样本，导出中断后修改尚未完成的 Memory、Provider 或环境变量，再按兼容选项续跑。

可观察验收：原 backup id 和 `snapshotAt` 保留；分别核查已完成类别和续跑类别的实际内容时间。不能仅检查 manifest 时间就判定统一快照通过；当前未保证跨类别一致，相关产品决定和运行证据另行记录。

## 现有测试与待验证边界

仓库已有格式兼容、加密、不完整结果、打包、顺序、类别计数、thinking rules round-trip、ZIP containment 和 restore symlink containment 测试。本轮未运行它们，存在测试文件不等于当前工作区已通过。

还需在后续验证：大包内存/磁盘压力、真实 iCloud placeholder、App 被系统终止后的 journal 恢复、File Provider 输入包，以及跨版本真实样本。任何实际恢复都应先使用可丢弃样本或备份副本，不能以用户唯一数据作首轮验证。
