---
description: MinisX iOS Memory 的全局与每日作用域、会话开关、上下文注入、读写检索、编辑撤销及同步删除限制；用于记忆功能与恢复变更。
---

# MinisX iOS Memory 行为与生命周期

导航：[Spec 索引](index.md)；文件地址见[全局资源](minis-url-scheme.md#全局资源)，传输规则见[同步与冲突处理](ios-sync-and-conflict-resolution.md)，包格式与事务见[备份恢复](ios-backup-restore.md)。

## 范围、状态与来源

本文区分2026-09-30当前工作区的静态实现、延续已有安全/证据规范的维护要求，以及尚待决定的产品语义。没有新增运行、真机或历史通过证据。Memory 是 App 内持久背景知识，不是当前开发会话的宿主记忆，也不是聊天历史压缩摘要；旧任务内容不能自行恢复为新用户指令。

主要入口：[AIChatViewModel+MemoryTools.swift](../../src/ios/Agent/Chat/AIChatViewModel+MemoryTools.swift)、[AIChatViewModel.swift](../../src/ios/Agent/Chat/AIChatViewModel.swift)、[ToolDefinitions](../../src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift)、[ChatStore](../../src/ios/Agent/Chat/ChatStore.swift)、[MemoryManagementView](../../src/ios/Views/Settings/MemoryManagementView.swift)、[MemoryWriteRevoker](../../src/ios/Views/Chat/MemoryWriteRevoker.swift)及[V2 hydrators](../../src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift)。源码存在路径不证明模型使用正确或设备写入、同步成功。

## 文件作用域与权威

| 内容 | 当前用途与边界 |
| --- | --- |
| `GLOBAL.md` | 跨会话背景知识；自动注入完整文件。当前系统提示允许用户明确要求时由Agent使用文件工具维护，专用memory_write不会写入它。授权措辞冲突见[GLOBAL维护权限](#global维护权限)。 |
| `YYYY-MM-DD.md` | 跨会话每日记录；memory_write按本地日期和时间生成标记并前置条目，不按session id建立私有日志。 |
| `SOUL.md` | 身份/人格资料，同目录保存，但由SystemPromptBuilder独立构建身份部分；Memory开关不控制其注入。本文只界定这一例外，不定义人格编辑产品。 |
| 聊天中的memory工具block | 保存该次工具调用的输入/结果；它不是Memory文件的唯一副本，也不是全局记忆条目的所有权记录。 |

持久目录通过`/var/minis/memory`与`minis://memory/...`访问，可以跨会话读取。会话删除或清空聊天不应被解释为已删除全局Memory；全局文件、历史工具结果和已发送给Provider的内容必须分别判断。背景知识的提示包装要求以最新用户范围为准，不能证明模型一定正确遵守。

## 默认值、会话开关与生效时点

当前`memory.global.enabled`默认true，只决定新建会话的数据库`memory_enabled`初值。已有会话读取自身值，不随全局默认变化一起更新。草稿首次持久化时由ensureSessionReturningId读回该值；loadSession同样读回。`/memory`修改当前ViewModel并在已有session时持久化；草稿尚无session时的临时开关与首次创建值如何衔接仍需专门验收，不承诺覆盖全局默认。

关闭后，当前实现同时：

- 不在Agent loop起始和Provider fallback重建时注入GLOBAL及近期日志；
- 从makeAgentTools移除memory_get和memory_write；
- 在两个执行函数中再次拒绝调用，返回失败和重新启用入口。

它没有按Memory开关取消一般文件工具或移除全局挂载，也不会从已有聊天工具结果中追溯删除已读内容。它不是全面的记忆访问隔离或远端遗忘开关。正在运行的请求已组装的prompt何时变化，需要运行验证，不能承诺切换瞬间清除已发送内容。

### 开关反馈的已知冲突

[SlashCommands](../../src/ios/Agent/Chat/AIChatViewModel+SlashCommands.swift)仍显示“Memory writes disabled/enabled. Reads are unaffected.”，菜单副标题也只称Writes。该反馈与自动注入和专用读取的门禁不一致。本文披露现状，不把“读取不受影响”或“全面禁止访问”提升为产品保证。开关究竟控制写入、自动注入与专用工具，还是所有文件访问，见[待维护者决定](#待维护者决定)。

## 自动注入与可观察范围

loadGlobalMemoryFragment读取非空GLOBAL全文；loadRecentDailyMemoryFragment最多回溯30个24小时偏移，选3份非空日志，每份前200行。天数、行数不是字符/token硬上限；GLOBAL没有同等行数限制，长行和大文件仍可能增加上下文及主线程读取成本。

初始Agent loop和fallback重建都按memoryEnabled判断，最后附加Memory状态提示。写入或编辑之后，新组装prompt可读取新文件；不承诺每次工具写入都立即刷新当前请求的system prompt。

[SessionMemoryView](../../src/ios/Views/Chat/SessionMemoryView.swift)的“Auto-injected”列表根据当前磁盘内容重新计算，工具活动来自当前聊天block。它不是每次实际请求的注入收据；文件已变化、开关关闭或fallback发生时，不能仅凭列表存在证明该版本已发送或模型已读取。

## 专用写入与GLOBAL维护权限

memory_write只要求字符串content，构造`<!-- yyyy-MM-dd HH:mm:ss -->`标记，前置到当天文件；失败返回错误。成功后登记fakefs metadata、请求MemoryDailyV2 dirty入队并广播memoryFilesDidChange。成功文案只证明本地函数完成，不等于云端发送、其他设备可见或后续模型已采用；入队仍受[同步启停前提](ios-sync-and-conflict-resolution.md#启停离线与发送)控制。

当前系统提示鼓励主动记录偏好和可复用事实；GLOBAL更新则要求用户明确指示，先读取、去重再使用file_edit/file_write。记忆写入授权、覆盖和敏感内容处理沿用[权限与副作用规范](ios-tool-permissions-and-side-effects.md)，不得从“已启用Memory”推导任意删除或凭证保存授权。

### GLOBAL维护权限

ToolDefinitions和GLOBAL注入包装称GLOBAL为“read-only/user-maintained”，但baseSystemPrompt允许明确授权后的Agent文件编辑。这是提示语义冲突，不是操作系统只读保护。memory_write不更新GLOBAL，与一般文件工具能够修改GLOBAL应分别说明；是否限定为设置页维护或保留明确授权的Agent编辑，仍待维护者决定。

## 检索、排序与资源限制

memory_get的scope默认all，包含GLOBAL及目录中的其他非隐藏`.md`文件；daily仅排除GLOBAL。当前代码没有严格把daily限定为日期命名文件，因此其他Markdown（包括SOUL）也可能参与工具检索；关闭自动SOUL例外不能据此推导检索结果范围。

没有keywords时按文件顺序最多返回500行；有keywords时按时间标记拆分条目，以匹配词比例和时间新近程度各50%排序。当前允许部分关键词命中，不要求全部命中；ToolDefinitions的“all keywords/lines with context”表述与实际条目检索不一致。

有关键词结果最多60项，并在加入一整项后达到30,720 UTF-8字节阈值时停止。该阈值是软边界，一项很大时可以超过它；无关键词分支只有行数限制。输出限制不约束扫描、整文件读取与候选构造成本，不能宣称固定30 KB硬上限或有界全库内存。超限、无匹配、无文件和disabled需要分别显示。

## 用户编辑、撤销与跨设备删除

MemoryManagementView支持编辑GLOBAL和日志，保存后对相应类型请求dirty并通知界面。未保存编辑存在时不自动覆盖编辑器；保存仍可能覆盖期间变化，需要实际竞态验收。删除列表跳过GLOBAL，并对其他文件执行本地删除，没有在该入口排队Memory云端delete。

MemoryWriteRevoker只搜索今天/昨天，按去除首尾空白后的content匹配第一个条目，连时间标记删除；它不以request/session/唯一条目id匹配。相同内容多次写入可能匹配另一条，超过两日返回未找到。成功仅表示本地文件改写；该函数没有直接dirty入队或变更通知，不能保证设置页或云端立即更新。

### 同步合并与防复活缺口

GLOBAL以文件mtime做LWW；空或缺失文件builder返回nil，因此清空本地GLOBAL不等于上传一个空值。每日日志按时间标记做并集合并，同时间不同内容有保留双方的路径；删除某条不能通过“远端条目缺失”表达。

MemoryGlobalV2/MemoryDailyV2没有注册deletionApplier；当前通用fallback保持本地内容。撤销、删除整份日志、清空GLOBAL都不能承诺已传播或不会被旧副本重新带回。记录级删除、条目级删除、同步关闭与账号级遗忘是不同语义，需产品决定及代码支持，不能套用会话的tombstone保证。协议细节由[同步规范的Memory例外](ios-sync-and-conflict-resolution.md#memory合并与删除例外)维护。

备份复制Memory目录中的Markdown，恢复按包内文件处理，并不等同于日志并集合并。历史备份可能含已删除内容；恢复不是“删除要求已永久生效”的证据，格式与回滚见[备份规范](ios-backup-restore.md)。

## 场景与验收

以下是需要执行时的验收条件，本次仅核对源码，均未运行。

| 场景与前提 | 可观察验收 |
| --- | --- |
| 设置默认关闭；分别创建新会话与加载已有开启会话 | 新会话不注入GLOBAL/日志且无专用工具；已有会话保持其保存值；另检查草稿先切换再首次发送的值。 |
| 关闭当前会话Memory并触发fallback | 初始及fallback请求不新增GLOBAL/日志，专用调用返回disabled；普通文件路径和已有工具历史的例外可区分。 |
| 用户明确要求维护GLOBAL | 先读取并去重，只修改授权内容；保留提示措辞冲突，不能当作已实现只读文件。 |
| 正常写入后启动下一Agent turn | 本地标记和内容正确，下一请求按注入限制读取；本地成功、dirty与远端成功分别观察。 |
| 搜索包含部分关键词、长条目和SOUL | 验证实际scope、条目排序、60项与软字节边界；截断提示不冒称全文或全部关键词匹配。 |
| 两次相同内容写入，跨两日后撤销 | 确认当前按内容和近两日的匹配限制；不存在唯一调用绑定保证；错误可见。 |
| 设备A撤销条目、B保留旧日志再同步 | 检查并集能否重新引入旧项；未实现删除传播前明确保留已知缺口，不把本地删除当验收通过。 |
| 文件修改后查看“Auto-injected” | 将显示的当前文件与请求当时版本分别比较，不把界面列表当传输证据。 |

## 待维护者决定

- Memory关闭的最终范围，以及运行中切换的生效时点和已有上下文处理。
- GLOBAL仅用户界面维护，还是允许明确授权的Agent文件编辑；主动日志保存是否维持当前提示策略。
- 撤销的期限、唯一条目标识、跨设备传播和恢复旧备份后的删除语义。
- daily检索是否应排除SOUL/其他文件，以及可接受的文件、输出和扫描资源上限。

这些问题不因Spec新增自动成为已确认能力；当前没有真实iCloud、Provider或真机证据，也未运行记忆读写、关闭/fallback、竞态、撤销或性能测试。
