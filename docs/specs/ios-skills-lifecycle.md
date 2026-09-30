---
description: MinisX iOS App 内 Skill 的导入更新、元数据发现、会话启停覆盖、正文读取、文件变更与删除边界；用于技能功能和跨会话维护。
---

# MinisX iOS Skill 生命周期

导航：[Spec 索引](index.md)；全局文件地址见 [URL 作用域](minis-url-scheme.md)，副作用见 [工具权限](ios-tool-permissions-and-side-effects.md)，同步与备份见 [同步](ios-sync-and-conflict-resolution.md) 和 [备份恢复](ios-backup-restore.md)。

范围：App 内可安装的 Skill（`SKILL.md` 及附件包）。它不是仓库 `.agents/skills` 下的开发协作技能，也不是注册的原生工具。“文件存在”“已启用”“描述已注入”“正文已读取”“模型执行正确”是五种不同状态，不能互相推断。

## 身份与文件

- **I1** SkillStore 在 `skills.db` 中保存 id、名称、描述、版本、来源、全局启用状态和时间；正文和附件存放在全局技能目录。
- **I2** 常规导入以名称 slugify 得到 id。同 id 重新导入会覆盖内容，并保留原有的启用状态和安装时间；它不是创建新版本。
- **I3** 在 shell 中新建的目录由 `reconcileOrphanSkill` 注册：id 取目录名，来源标为 `session`。这个来源标签不表示技能是会话私有的。
- **I4** `/var/minis/skills/<id>/SKILL.md` 与 `minis://skills/...` 是全局资源，其他会话可以读取。改名只更新名称，不改变目录 id 和既有链接。

## 导入与更新

- **M1** 支持的入口：粘贴或文件、ZIP、GitHub URL。解析处理 frontmatter 和正文，缺少名称时有兜底；它不是完整的格式校验器，解析成功不代表脚本和依赖可以运行。
- **M2** GitHub 导入：先只下载并解析 `SKILL.md`，提交时先安装正文，再由独立的后台 Task 递归下载同目录附件。导入返回成功时附件可能尚未下载完，部分失败目前只写日志；离开导入界面不取消这个 Task。
- **M3** 手动 “Update from URL” 会等待附件下载完成，部分失败时返回 `partialSuccess`。
- **M4** ZIP 要求 `SKILL.md` 位于根目录或单层父目录下，先写正文再写附件；中途出错时可能已部分写入，导入不是原子的。
- **M5** 部分界面入口在 GitHub 覆盖前要求确认；`importSkill` 本身对同 id 直接覆盖，没有统一的确认屏障。
- **M6** Skill 包中的路径、外部依赖和凭证处理遵守 [工具权限](ios-tool-permissions-and-side-effects.md)，不因来自 Skill 包而放宽。

## 全局启停与会话覆盖

- **O1** 会话中是否启用：先查 `session_skill_overrides`，有覆盖就用覆盖值，否则用全局值。会话可以启用全局关闭的 Skill，也可以禁用全局开启的 Skill。
- **O2** `setSessionOverride` 在设置值等于当前全局值时删除覆盖行，否则保存。覆盖表示“当前的例外”；没有覆盖的会话随全局值变化。
- **O3** 在尚未发送的草稿中切换 Skill 时，先创建真实会话再保存覆盖，不写入空 session id。
- **O4** 全局启停会把 Skill 标记为待同步；会话覆盖只写本地数据库。Skill 的同步和备份不包含会话覆盖与使用次数。
- **O5** 删除 Skill 时一并清理它的覆盖记录。
- **O6** 启停只控制发现片段和斜杠菜单，不卸载技能目录，也不给一般文件读写加门禁；已读取的正文和之前的工具结果不会被撤回。

## 发现、读取与斜杠入口

- **D1** 发现片段只包含名称、截断到 200 字符的描述，以及 `SKILL.md` 路径，并提示使用前先读取正文。App 不自动执行技能，不自动注入正文。
- **D2** 启用的 Skill 较多时，片段按以下顺序挑选，目标 20 项：内置技能；最近 7 天修改或创建的，最多 10 项；再按使用次数补足。并提示还有多少未展示、如何搜索。内置技能一项没有单独的上限，所以 20 是目标值，不是严格上限。
- **D3** 片段在 Agent 循环开始时生成，Provider fallback 重建请求时重新生成。
- **D4** 只有通过 `file_read` 成功读取 `SKILL.md` 才记一次使用；shell `cat`、其他读取方式或菜单展示不计。任一 Skill 的次数超过 1000 时，所有计数归一化到 0–100。使用次数不代表任务成功。
- **D5** 斜杠菜单按会话中的有效启用状态列出 Skill；选择后只在输入框插入 `/<名称> ` 并保留原文本。之后仍靠模型理解并读取正文，不是确定性的执行路由。

## 文件变更、同步与删除

- **F1** `file_write` / `file_edit` 成功写入 `SKILL.md` 会触发重新加载；磁盘扫描（`rescanFromDisk`、`rescanAndMarkChangedSkillsDirty`）负责其他刷新与待同步入队。重新加载不代表附件修改已进入同步队列。
- **F2** 重新扫描时解析失败的 `SKILL.md` 保留原有元数据，不抹掉已知描述。
- **F3** 同步的 Skill 记录包含全局启用值、正文和可选的 ZIP 附件。Skill 目录中所有文件 60 秒内无修改才视为稳定、可以打包；缓存和包管理目录不打包。
- **F4** 本地删除会请求远端删除；收到远端删除时调用 `applyRemoteDeletion`，并避免回声。同步规则见 [同步与冲突处理](ios-sync-and-conflict-resolution.md)。
- **F5** `deleteSkill` 删除全局文件、数据库条目和覆盖，并请求云端删除。文件删除是尽力而为，界面上条目消失不代表每份副本都已清理。

## 资源与安全

- **S1** Skill 正文和附件可以触发 shell、网络和设备工具，但文字指令不授予新的权限或操作确认。
- **S2** 导入递归、目录扫描、ZIP 内存、元数据加载、附件读取与取消遵守 [资源开销规范](resource-efficiency.md)。页面关闭不代表后台附件任务已释放资源；目前没有整个包大小的硬上限。

## 待决定

- [待决定] 禁用 Skill 是否应同时禁止读取和执行它（O6）。
- [待决定] 同名冲突在各导入入口的确认方式（M5）。
- [待决定] 是否同步或备份会话覆盖与使用次数（O4）。
- [待决定] 技能更新是否保留可回滚的旧版本（I2）。
- [待决定] 会话删除后残留覆盖记录的清理。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 全局关闭某 Skill，会话 A 显式启用，会话 B 无覆盖 | A 的发现片段和菜单中可见，B 不可见；普通文件访问不受影响（O1、O6） |
| 草稿未发送时切换 Skill | 创建真实会话并保存覆盖，首次发送和重新加载使用同一 id（O3） |
| 同 id 重新导入；GitHub 附件下载失败 | 启用状态和安装时间保留；正文成功、附件未完成和 `partialSuccess` 分别可见（I2、M2、M3） |
| 在输入框选择 Skill 后发送 | 原文本保留；请求中只有发现信息，模型随后通过 `file_read` 读取正确正文（D1、D5） |
| 在 shell 中创建或编辑 `SKILL.md` 与附件 | id 和链接稳定；格式错误的正文不抹掉已知描述（I3、F1、F2） |
| 删除 Skill 后旧的云记录回流 | 本地文件、覆盖记录已清理，已删除的 Skill 不复活（F4、F5） |
| 备份恢复或另一台设备同步 | 正文、附件和全局启用状态正确；不声称会话覆盖和使用次数已迁移（O4） |

## 代码入口

- [SkillStore](../../src/ios/Agent/Session/SkillStore.swift)：导入、更新、启停、覆盖、发现片段、使用次数、删除、稳定性判断
- [SkillsManagementView](../../src/ios/Views/Skills/SkillsManagementView.swift)、[SessionSkillsView](../../src/ios/Views/Chat/SessionSkillsView.swift)
- 斜杠菜单：[SlashCommands](../../src/ios/Agent/Chat/AIChatViewModel+SlashCommands.swift)；读取计数：[ConcurrentTools](../../src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift)
- 同步：[ChatStoreSyncHydrators](../../src/ios/Agent/Sync/V2/ChatStoreSyncHydrators.swift)
- 测试：[SkillDescriptionStaleTests](../../src/ios/MinisTests/Standalone/SkillDescriptionStaleTests.swift)（独立脚本，只覆盖复制出来的判断逻辑）
