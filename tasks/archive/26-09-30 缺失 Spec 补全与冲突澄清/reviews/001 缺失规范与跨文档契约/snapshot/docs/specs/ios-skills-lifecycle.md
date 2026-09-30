---
description: MinisX iOS App 内 Skill 的导入更新、元数据发现、会话启停覆盖、正文读取、文件变更与删除边界；用于技能功能和跨会话维护。
---

# MinisX iOS Skill 生命周期

导航：[Spec 索引](index.md)；全局文件地址见[URL作用域](minis-url-scheme.md#全局资源)，副作用见[工具权限](ios-tool-permissions-and-side-effects.md)，同步与备份分别见[同步](ios-sync-and-conflict-resolution.md)和[备份恢复](ios-backup-restore.md)。

## 范围、状态与来源

Skill是App内可安装的`SKILL.md`及附件包，不是仓库`.agents/skills`开发协作技能，也不是已注册的原生工具。本文记录2026-09-30当前工作区静态状态、延续已有权限/证据规范的维护要求及未决语义，没有运行或真机验收。不能把“文件存在、已启用、描述已注入、正文已读取、模型执行正确”当成同一状态。

主要入口：[SkillStore](../../src/ios/Agent/Session/SkillStore.swift)、[SkillsManagementView](../../src/ios/Views/Skills/SkillsManagementView.swift)、[SessionSkillsView](../../src/ios/Views/Chat/SessionSkillsView.swift)、[SlashCommands](../../src/ios/Agent/Chat/AIChatViewModel+SlashCommands.swift)、[ConcurrentTools](../../src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift)和[V2 hydrators](../../src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift)。

## 身份、文件与作用域

SkillStore将id、名称、描述、版本、来源、全局启用状态与时间保存于skills.db，正文和附件保存于全局技能目录。常规importSkill将名称slugify得到id，同id重导入更新内容并保留原启用状态/安装时间；这是覆盖身份规则，不是每次导入创建全新版本。

shell新建目录通过reconcileOrphanSkill注册时保留目录名作为id，来源为session；这个来源标签不意味着会话私有技能。`/var/minis/skills/<id>/SKILL.md`与`minis://skills/...`为全局文件资源，可以被其他会话读取。rename更新名称不能据此推断目录id或既有链接同时改变。

## 导入、更新与失败完成条件

当前支持粘贴/文件、ZIP和GitHub URL。parse处理frontmatter及正文，缺失名称有fallback；不是完整Anthropic格式验证器，解析成功不保证脚本/依赖可运行。

GitHub preflight只下载解析SKILL.md，commit先安装正文，再由独立后台Task递归下载同目录附件。导入返回成功时附件可能尚未完成，部分失败目前记录日志；手动Update from URL等待附件下载并可返回partialSuccess。离开导入界面不意味着该后台Task取消。维护者必须分别观察正文安装和附件完整性，不能只检查Skill行出现。

ZIP入口需要根目录或单层父目录的SKILL.md，写入正文后再写入附件；错误可能发生在已部分写入之后，不能宣称所有导入原子回滚。GitHub覆盖确认在部分UI入口存在；importSkill自身同id覆盖，不是统一的每路径确认屏障。文件路径安全、外部依赖与凭证处理仍受[权限规范](ios-tool-permissions-and-side-effects.md)约束，不能因其来自Skill包而放宽。

源码：SkillStore.importSkill/preflightGitHubImport/commitGitHubImport/updateFromURL/importFromArchive。未调用网络、导入ZIP或执行附件。

## 全局启停与会话覆盖

isEnabledForSession先读session_skill_overrides，有覆盖则优先，否则使用全局isEnabled。会话可以启用全局关闭的Skill，也可以禁用全局开启的Skill；全局关闭不是强制所有会话关闭。

setSessionOverride在值等于当前全局默认时删除覆盖行，否则保存。它表达当前例外，不是永远固定一次选择；后续全局值变化时没有覆盖的会话会跟随。草稿第一次在SessionSkillsView切换时先创建真实session，再绑定覆盖，不能使用空session id。

全局setEnabled请求Skill dirty；session override只写本地skills.db并更新UI版本计数。当前Skill同步和新格式SkillRecord备份没有携带会话覆盖和使用频率，不能把“Skill已同步/恢复”解释为每个会话选择和排序历史已复制。删除Skill会清理对应覆盖；会话删除后的残留覆盖清理不在此静态核查中承诺。

### 关闭不等于禁止文件访问

当前启停控制发现片段及斜杠菜单，未把技能目录撤载或为一般文件读写增加Skill开关门禁。已读正文和既有工具结果也不会被追溯清除。需要阻止读取或执行某个Skill时，不能只依赖发现开关；是否提升为执行许可是[待决定事项](#待验证与待决定)。

## 发现、正文读取与斜杠入口

skillPromptFragment只提供名称、截断至200字符的description和SKILL.md路径，提示使用前读取正文；它没有在App中自动执行技能、自动注入全部正文或强制模型遵循内容。

启用数较少时按更新时间展示；较多时优先bundled、最近7天最多10项，再以use_count填充目标20项，并给出有限的未展示名称及目录搜索提示。该实现的bundled分支没有同等硬截断，因此20是当前选择目标，不能宣称对任意数据都严格20项。description限制也不是正文/附件读取预算。

初始Agent loop及Provider fallback重建时生成片段。启停或文件修改对已组装请求的生效时点需要验收；正文读取通常作为工具结果进入历史，不等同于下一次描述更新。

成功file_read且路径匹配SKILL.md时recordSkillUse记录使用次数；shell cat、其他资源读取或菜单展示不能据此推导同样计数。次数代表特定读取事件，不是技能任务成功率。

斜杠菜单按会话有效启用值列出Skill；选中后只在输入框插入`/<名称> `及保留原文本。发送后仍依赖模型理解与工具读取，不是确定性的技能执行路由，也不保证跳过描述筛选后自动加载正确文件。

## 文件变更、同步和删除

file_write/file_edit成功写入SKILL.md会触发reload；磁盘发现、rescanFromDisk和rescanAndMarkChangedSkillsDirty负责不同的元数据刷新/dirty入队路径。普通reload不等于所有附件修改均已进入同步队列；fakefs事件、quiet窗口与mtime扫描需分别核查。

当前rescanFromDisk对解析失败保留旧元数据，loadSkills对空/旧block标记description有专门刷新分支；不能由这些分支推出任何文件编辑都实时刷新全部元数据。新增或删除磁盘目录、Library/rootfs双副本、前台恢复分别需要验收。

同步SkillV2包含全局启用值、正文及可选ZIP附件，普通删除请求远端delete，入站删除调用applyRemoteDeletion并避免回声。quietSeconds默认60、排除缓存/包管理目录和ZIP构造是当前资源策略，不是iCloud必然及时成功的证据。同步初始化/类别前提及冲突规则见[同步规范](ios-sync-and-conflict-resolution.md#启停离线与发送)。

deleteSkill删除全局文件、数据库条目及覆盖，并请求云端删除；文件移除为best effort，故界面条目消失不证明每份文件副本已清理。另一设备的删除传播、后台下载尚未完成时的竞态和备份恢复后重建需要验证，不在本轮升级为保证。

## 资源与安全边界

Skill正文及附件可触发shell、网络和设备工具，但文字指令不授予新权限或操作确认。[资源规范](resource-efficiency.md)适用于导入递归、目录扫描、ZIP内存、主线程元数据加载、附件读取和取消。当前存在后台附件任务，不能声明页面关闭就释放全部资源，也没有从描述筛选推出完整包大小硬上限。

## 场景与验收

以下为待执行的可观察条件，本轮未运行。

| 场景与前提 | 可观察验收 |
| --- | --- |
| 全局关闭Skill，A会话显式启用，B无覆盖 | A的描述和菜单可见，B不可见；普通文件访问例外单独观察，不宣称全局封禁。 |
| 草稿尚未发送时改变Skill选择 | 创建真实会话并保存覆盖，首次发送/重载使用同一id，未写空id记录。 |
| 同id重复导入与GitHub附件失败 | 全局启用/安装时间按当前规则保留；正文成功、附件未完成及partialSuccess分别可见，不把成功返回当完整包。 |
| 输入框选择Skill后发送 | 原文本保留；实际请求只有发现信息，后续file_read读取正确正文；模型行为另行验证。 |
| shell创建/编辑SKILL.md及附件 | id和链接稳定，元数据刷新与dirty入队分别观察；malformed正文不静默抹掉已知描述。 |
| 删除Skill并让旧云记录回流 | 检查双目录、覆盖、delete和防复活；后台下载重建风险单独观察。 |
| 备份恢复或另一设备同步 | 正文/附件和全局启用状态符合格式；会话覆盖与use_count不得伪报已迁移。 |

## 待验证与待决定

[SkillDescriptionStaleTests.swift](../../src/ios/MinisTests/Standalone/SkillDescriptionStaleTests.swift)只包含独立复制谓词的回归入口，不证明生产导入、数据库、iSH、同步或模型使用成功；本轮未执行它。

待验证：多会话覆盖、草稿首次发送、GitHub/ZIP部分写入与取消、正文更新的prompt时点、磁盘双副本和iCloud删除竞态、资源峰值。待决定：禁用是否必须成为读取/执行禁止；同名冲突的各入口确认形式；是否同步/备份会话覆盖；技能更新是否保留可回滚版本。未决事项不自动变成现行产品保证。
