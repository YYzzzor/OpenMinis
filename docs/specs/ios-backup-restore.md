---
description: iOS .minisbak 的格式兼容、备份范围、凭证加密、完整性、不完整结果、恢复事务与回滚契约。
---

# iOS Backup and Restore

导航：[Spec 索引](index.md)。

范围：创建、恢复、分享、迁移或诊断 `.minisbak` 备份包，包括格式兼容、类别、加密、完整性、不完整结果、恢复与中断恢复。[backup-streaming-package-design.md](../backup-streaming-package-design.md) 是分阶段的设计资料，其中只有源码已实现的部分属于现状。

## 包格式

- **P1** 扩展名 `.minisbak`，当前主版本 `minisbak/1`。
- **P2** 读取方遇到不认识的主版本时拒绝并提示更新，不尽力写入用户数据。
- **P3** 同一主版本内，忽略未知字段；非结构必需的缺失字段使用兼容的默认值。
- **P4** 每条记录用类型 `t` 和版本 `v` 支持分类解析与逐条迁移。
- **P5** JSONL 分片最大 64 MiB，超出后写入下一个分片，避免导入时一次加载巨型文件。
- **P6** `manifest.json` 始终是明文，用户输入密码前就能看到来源、时间、类别和数量。它至少包含：格式、创建与快照时间、App 信息、显示用的设备名、backup id、类别统计、限制、加密说明、内容完整性哈希；不写入内部 device id，避免两台设备争用同步身份。

## 备份范围

| 类别 | 普通界面新导出 | 恢复 |
| --- | --- | --- |
| chats | 是 | 是 |
| shared_files | 是 | 是 |
| skills | 是 | 是 |
| memory | 是 | 是 |
| providers | 是 | 是 |
| mcp_servers | 是 | 是 |
| environment_variables | 是，只含条目元数据；值走凭证路径 | 是；值依赖 providers 凭证的恢复或本地已有的 Keychain 值 |
| voice_corrections | 否；显式选择该类别的调用仍可导出 | 是，兼容旧包和显式导出的包 |

- **S1** 界面默认选中所有可导出的类别。
- **S2** 文件类类别可以设置单文件上限，默认不限。无法下载的 iCloud 占位文件、超限文件、快照期间消失的 blob，都写入 manifest / index 和最终报告，不把不完整的导出显示为完全成功。
- **S3** 导出续跑时保留原来的 `snapshotAt`，聊天按它筛选会话和消息。它不是所有类别的统一快照：Memory 复制当前文件，Provider 和环境变量读取执行时的数据；已完成的类别在续跑时跳过，未完成的继续执行。因此中断期间发生修改时，包中各类别可能来自不同时间（见“待决定”）。

## 凭证与加密

- **E1** 只有选择了 `providers` 类别、开启 `includeCredentials`、且提供了非空密码时，凭证才进入包；前两者满足而没有密码时，导出被拒绝。单独开启 `includeCredentials` 或只设密码，不保证包中有凭证。
- **E2** 不提供密码时，可以关闭凭证生成分享副本；环境变量类别仍可包含条目元数据，但不含值。
- **E3** 密码不持久化。续跑加密导出时必须再次提供，不能因为存在 staging 而降级为明文包。
- **E4** 内容加密后，完整性记录的是包内实际字节（密文）的 SHA-256，因此不知道密码也能发现截断或损坏。
- **E5** 加密包用 verifier 区分密码错误，用 manifest MAC（优先校验 `manifest.mac` 原始字节）认证 manifest。敏感内容只出现在加密成员中；manifest 是明文不代表凭证是明文。
- **E6** 凭证集合归在 `providers` 下，包含收集到的环境变量值和 MCP OAuth，即使对应的元数据类别没有选。

| 内容 | 导出前提 | 恢复前提 |
| --- | --- | --- |
| 环境变量的名称、备注等元数据 | 选择 `environment_variables`，写入 `env_vars.json`，不含值 | 选择 `environment_variables`：已有条目保留，新条目从 Keychain 取值，缺值时为空 |
| Provider 凭证、环境变量值、MCP OAuth | 选择 `providers`、包含凭证并提供密码，由 [BackupSecrets](../../src/ios/Agent/Backup/BackupSecrets.swift) 收集 | 包中含 `providers` 且被选中，密码验证和解密后由其 importer 应用；只选环境变量或 MCP 类别不会应用这些凭证 |

- **E7** 要迁移环境变量的条目和值，需同时选择 `environment_variables` 和含凭证的 `providers`。恢复时 importer 把选中的 providers 排在环境变量之前，以便新条目读到刚恢复的值；它不自动补选依赖的类别。

### 内联MCP凭证与分享副本限制

- **E8** 敏感凭证只出现在加密成员中（现状见“待决定”）。
- **E9** 分享副本只表示不含专用的凭证集合，不代表完全没有凭证或已自动脱敏；其他文件中的敏感内容也不会因类别开关而被清除。

### Skill、Memory 与费用的恢复范围

- **E10** Skill 恢复元数据和附件，不恢复 `session_skill_overrides` 和 `use_count`。Memory 恢复复制包中的 Markdown 文件，不做日志并集合并，也不保证之前撤销的条目仍然不存在。会话费用账本不在聊天记录中，恢复聊天不恢复费用历史。分别见 [Skill](ios-skills-lifecycle.md#全局启停与会话覆盖)、[Memory](ios-memory-lifecycle.md#用户编辑撤销与跨设备删除)、[费用](ios-usage-cost-and-balance.md#不在范围内)。

## 导出完成与中断

- **X1** 导出与恢复通过进程级 activity lock 互斥，不能同时修改共享数据或 staging。
- **X2** 干净完成后清理对应的 journal 和 staging。取消、进程退出或可恢复的中断时保留 staging，由之后的尝试以相同的范围、限制和加密策略认领。
- **X3** 续跑要求类别集合、单文件上限、是否包含凭证、加密意图都匹配，并沿用原 backup id 和 `snapshotAt`；不匹配的旧 staging 不拼入新包。选项匹配只决定能否认领 staging，不保证未完成类别的源内容没有变化（S3）。
- **X4** 最终结果报告包大小、已完成类别、续跑类别，以及跳过的文件数、字节数和路径。生成了归档文件不代表所有源数据都已包含。

## 恢复

- **R1** 恢复顺序：
  1. 安全解包到临时工作目录，拒绝 ZIP 路径逃逸和符号链接逃逸；
  2. 读取 manifest，检查主版本；
  3. 默认先按包内字节校验完整性；
  4. 若已加密，要求密码，校验 verifier 和 manifest MAC 后解密；
  5. 执行容量、运行中会话、类别等预检；
  6. 为每个类别建立持久的回滚快照，按依赖顺序导入；
  7. 刷新相关 store，返回分类报告和警告。
- **R2** 事务以类别为单位：某类别失败时回滚该类别，已成功的前序类别保留，然后继续其余类别并报告。界面不把部分成功显示成“全部成功”或“全部失败”。
- **R3** 回滚快照位于不会随临时目录删除的位置；App 在恢复中被终止时，下次启动根据 journal 处理遗留的 staging。完成标记在数据真正落盘之后才写入。
- **R7** 任何实际恢复的首轮验证，都先使用可丢弃的样本或备份副本，不用用户唯一的数据。回滚规则（R2、R3）不能代替这一前提，各类别的回滚能力不同（[BackupImporter+Categories](../../src/ios/Agent/Backup/BackupImporter+Categories.swift)）：
  - chats、skills、voice_corrections、environment_variables 以合并方式写入，没有建立能恢复原状态的快照（见“待决定”）；
  - providers 有配置文件级的快照：恢复前复制 Provider 配置文件并记录恢复目标，失败时写回该文件并重新加载配置，App 启动时由 [BackupRestoreJournal](../../src/ios/Agent/Backup/BackupRestoreJournal.swift) 处理遗留的文件快照。这只覆盖该配置文件，不代表所有 Provider 相关数据和凭证（如 Keychain 中的值）都能完整回滚，其他范围需按具体源码另行判断。
- **R4** 以合并为主；会话 id 冲突时可以选择合并或复制为新会话。本地已存在的凭证保留，旧备份不覆盖用户后来更换的 key。
- **R5** 聊天类别内部先建立会话，再导入引用它的消息和文件；消息顺序与压缩标记的引用保持一致。
- **R6** 未知类别或记录版本按 P2、P3 处理并写入警告，不产生看似成功的空恢复。

## 待决定

- [待决定] E8 的缺口：[BackupExporter](../../src/ios/Agent/Backup/BackupExporter.swift) 的 `exportMCPServers` 原样复制 `servers.json`，`headers` / `env` / `url` 中的内联 token 可能进入 `mcp_servers` 类别；即使没有选 `providers`、关闭了 `includeCredentials`、或没有密码，也不检查或移除这些值。内联凭证是拒绝、脱敏还是强制加密，待决定。
- [待决定] R2 的缺口：chats、skills、voice_corrections、environment_variables 以合并方式写入，没有能恢复原状态的快照，失败时无法回滚到恢复前；是否及如何补齐，待决定。
- [待决定] providers 的配置文件级快照之外（如凭证），失败时能回滚到什么程度，需按源码确认（R7）。
- [待决定] 是否需要跨类别统一的快照，以及一致性范围（S3）。
- [待决定] 是否保留环境变量值依赖 `providers` 凭证集合的耦合（E6、E7）。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 选择 providers、开启包含凭证，但没有设置密码 | 写出分享包之前拒绝；界面提示设置密码或关闭凭证；磁盘上不留下含明文凭证的包（E1） |
| 加密包被截断或篡改；完整包输入错误密码 | 前者在完整性阶段失败；后者提示密码错误而不是数据损坏；任何失败都没有部分写入业务数据（E4、E5） |
| 源文件超限、iCloud 未下载、或索引后 blob 消失 | 导出报告列出跳过和缺失的原因与数量；恢复报告不把缺失标记当作已恢复的文件；用户在删除旧设备数据前能看出备份不完整（S2、X4） |
| 恢复中途被终止 | 已开始的类别有持久的快照和 journal；下次启动时回滚或处理，不把写了一半的目录当成功；其他恢复不误删它的 staging（R3） |
| 格式兼容 | 未知主版本被拒绝；`minisbak/1` 的未知字段被忽略；缺少可选字段时按默认值读取；旧包或显式导出的 `voice_corrections` 可恢复（P2、P3） |
| 恢复后的顺序与覆盖 | 会话消息顺序与备份一致，压缩标记引用有效；已有本地凭证保持不变，报告中标为 kept（R4、R5） |
| 只迁移环境变量（目标设备没有同名条目和值） | 只导出或只恢复环境变量时能看到条目，但不报告值已迁移；同时导出并恢复环境变量与含凭证的 providers 才核查值是否完整（E6、E7） |
| 导出中断后修改未完成的 Memory、Provider 或环境变量，再续跑 | 保留原 backup id 和 `snapshotAt`；分别核查已完成与续跑类别的实际内容时间，不只凭 manifest 时间判定统一快照（S3、X3） |
| 配置含内联 token 的 MCP server 后导出 | 用占位测试值检查各成员是否包含该值，不输出真实秘密（E8、E9） |

## 代码入口

- 格式与类别：[BackupFormat](../../src/ios/Agent/Backup/BackupFormat.swift)
- 导出、加密、续跑、报告：[BackupExporter](../../src/ios/Agent/Backup/BackupExporter.swift)、[BackupSecrets](../../src/ios/Agent/Backup/BackupSecrets.swift)
- 检查、预检、分类恢复：[BackupImporter](../../src/ios/Agent/Backup/BackupImporter.swift)
- 回滚与启动协调：[BackupRestoreJournal](../../src/ios/Agent/Backup/BackupRestoreJournal.swift)
- 已有测试覆盖格式兼容、加密、不完整结果、打包、顺序、类别计数、thinking 规则往返、ZIP 与符号链接的路径约束。
