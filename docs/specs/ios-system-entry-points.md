---
description: MinisX iOS App Intents、Shortcuts、分享扩展、文件提供器、通知和 Live Activity 等系统入口的契约与降级边界。
---

# MinisX iOS 系统入口与扩展

导航：[Spec 索引](index.md)；`minis://` 路由和安全边界见 [Minis URL Scheme](minis-url-scheme.md)；Agent 内部运行状态见 [iOS Agent 运行生命周期](ios-agent-run-lifecycle.md)。

范围：App Intents 与 Shortcuts、分享扩展、File Provider、通知、Live Activity 与 Widget。

## 共同边界

- **B1** 主 App、ShareExtension、FileProvider、AgentWidget 是不同的进程和 target，只通过明确的 App Group 文件、UserDefaults、ActivityKit / AppIntent 或深链交换状态；不假设共享内存，也不假设主 App 一直在运行。
- **B2** 所有正式 target 使用 App Group `group.com.yyzzzor.minisx`，bundle 前缀为 `com.yyzzzor.minisx`。修改标识、Team、entitlement 或容器路径时，主 App 与三个扩展一起核对；单个 target 签名成功不代表跨进程数据可见。
- **B3** 系统入口发起动作不等于 Agent 已完成：系统可能限制扩展寿命、暂停被唤醒的进程、拒绝通知或不打开主 App。入口返回可理解的状态（已接收、运行中、已完成、失败），并提供会话 id 或恢复入口。

## App Intents 与 Shortcuts

- **A1** 公开入口：Ask MinisX、Send Prompt、Quick Task、Follow Up Session、Retry Run、Get Session Status、List Sessions、Open Session。短语由 `MinisShortcutsProvider` 和各语言的 `AppShortcuts.strings` 提供。
- **A2** Ask MinisX 和 Open Session 打开主 App 并把目标会话交给导航层；Send Prompt、Quick Task、Follow Up、Retry 默认不打开 App（`openAppWhenRun = false`），先返回结构化的会话或结果，再在系统允许的时间内继续执行。
- **A3** `waitForResult = false` 时返回 Running / Retrying，只表示请求已发起；调用方用通知或 Get Session Status 观察后续结果。
- **A4** `waitForResult = true` 时等待当前 ViewModel 处理结束，返回最后一条非内部的 assistant 文本；仍受系统执行时限约束，不是无限期后台运行。
- **A5** 无界面启动时尽早登记会话活动；用户开启增强后台能力时可以尝试保活。占位 session id 在真实 id 建立、失败或提前返回时清理，避免主界面、状态查询和 Live Activity 出现“幽灵任务”。
- **A6** `ShortcutRunTracker` 的待完成记录用于下次回到前台时提示“可能未完成”，不是后台已成功的证据。
- **A7** Send Prompt 未指定会话时创建新会话，来源标为 shortcut；继续已有会话或 Retry 不覆盖会话原来的来源。
- **A8** 目标会话正在运行时，Follow Up 和 Retry 等它结束后再继续，不与同一会话并发改写历史。
- **A9** Shortcuts 可以选择具体模型或模型组，转换为正常的 `SessionModelBinding`；可用性和 fallback 遵守 [Provider 路由](ios-provider-model-routing.md)。
- **A10** 图片、视频、文件通过 `IntentFile` 复制为会话附件，文件名缺扩展名时按 UTType 补全。附件存在不代表已上传给模型。
- **A11** Retry 从选定的用户消息处截断其后的内容，语义与 App 内重跑一致；没有可重试的用户消息时返回 Error，并清理待完成记录和会话活动。

## 通知与状态查询

- **N1** 单次运行的通知开关与 App 全局任务通知开关同时生效。关闭通知不阻止任务；通知投递失败不改变会话的真实状态。
- **N2** 点击任务通知按 session id 打开对应会话；冷启动时优先处理这个明确的目标，不被默认启动会话的偏好覆盖。
- **N3** Get Session Status 读取活动跟踪、已持久化的会话与消息，以及可用的 ViewModel，返回当前能观察到的快照。进程被系统暂停时跟踪信息可能过时，不把单个内存标志当作已完成的证明。

## 分享扩展

- **S1** URL 和短文本作为内联文本；长文本、图片、视频、文件复制到 App Group 共享目录，再保存 `PendingShare`。
- **S2** 主 App 消费前的连续分享在 300 秒窗口内合并；附件文件名带 UUID 片段，互不覆盖。超出窗口的旧内容由主 App 视为遗留并清理。
- **S3** 分享的文件 URL 使用 security-scoped 访问；图片转为 JPEG（质量 0.85）。复制、编码或容器不可用时明确失败，不创建只有文件名、没有文件的附件。
- **S4** 保存后扩展尝试打开 `minis://share` 并结束请求。打开失败时数据可能已留在 App Group，不向用户声称主 App 已展示。
- **S5** 主 App 消费成功后清理待处理记录和已搬运的文件；重复启动不会重复插入同一次分享。

## File Provider

- **F1** replicated extension 把 App Group 中的 `MinisFileProvider/` 暴露到“文件”App，顶层为 `memory`、`skills`、`shared`。
- **F2** `memory/` 与 `skills/` 在“文件”中只读；`shared/` 可以读写：其中的条目可新建、修改、改名、移动、删除，`shared` 目录本身不能改名或删除。修改会影响主 App 可见的内容，并通过系统 change signal 通知刷新。
- **F3** 写入前做路径校验，不能逃逸出根目录。
- **F4** 文件监听和 signal 是尽力而为；扩展被暂停后，恢复时重新扫描并通知根目录和 working set。“文件”中看到的缓存条目不代表磁盘内容已是最新。
- **F5** 系统保留的 trash 标识不作为普通路径；历史上出现的假 trash 内容被移到 `shared/_recovered_trash` 后再清理冲突目录。
- **F6** FileProvider 进程可能独立于主 App 启动：初始化、迁移和日志路径不依赖主 App 先运行。扩展崩溃或系统缓存状态不等于业务文件丢失，需核对 App Group 中的实际文件和系统错误。

## Live Activity 与 Widget

- **W1** AgentWidget 展示主 App 通过 ActivityKit 发布的会话摘要、运行与完成数量、工具状态和可选的朗读状态；内容来自 `AgentActivityAttributes.ContentState`，Widget 不拥有 Agent 循环，也不读取主 App 内存。
- **W2** Privacy Mode 下不显示消息内容、工具细节、循环次数等敏感运行信息。
- **W3** 完成后计时停止，显示静态耗时；“软完成”与 Activity 真正结束分开处理。
- **W4** 朗读按钮通过 AppIntent / Darwin notification 请求主 App 切换 TTS。按下成功只表示请求已发出；主 App 未运行、没有已加载的音频或受系统限制时，播放可能没有变化。
- **W5** 正式 target 最低 iOS 26.0。源码中 iOS 17 的 availability 检查和更早系统的只读图标分支是历史兼容代码，不代表当前支持或需要验收这些系统。

## 待决定

- [待决定] `waitForResult` 是否需要产品级的最长等待时间和明确的超时状态；目前主要受系统环境限制（A4）。
- [待决定] 分享扩展打开主 App 失败时，是否在扩展内显示明确的成功或失败界面；目前靠日志和下次消费（S4）。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 用 Shortcuts 异步发送一个新 prompt | 返回真实的 session id、实际解析的模型和 Running；主界面、状态查询、Live Activity 都不出现占位 id；最终完成或被系统中断都有可观察结果；关闭通知时不发通知，任务照常执行（A3、A5、N1） |
| Retry 时没有可重试的用户消息 | 返回 Error，不截断会话，不留下待完成记录或活动会话；状态查询和 Live Activity 中没有幽灵任务（A11、A5） |
| 快速连续分享两个附件 | 主 App 消费前第二次分享合并第一次的内容；打开主 App 后两者各出现一次，文件名不冲突；超出窗口的遗留内容不混入新分享（S2、S5） |
| 在“文件”中修改 `shared/` 下的文件；尝试修改 `memory/` 或 `skills/` 下的文件 | 前者写入受控根目录并最终在主 App 刷新，扩展暂停恢复后能重新枚举；后者被拒绝（F2、F3、F4） |
| 锁屏且开启 Privacy Mode | 仍显示是否运行或完成，不显示消息和工具、循环等细节；完成后计时停止；朗读按钮的请求发送与实际播放分别核查（W2–W4） |

## 代码入口

- Intents：[Agent/Intents](../../src/ios/Agent/Intents)（含 `MinisShortcutsProvider`、`ShortcutRunTracker`）
- 分享扩展：[ShareViewModel](../../src/ios/ShareExtension/ShareViewModel.swift)、[ShareViewController](../../src/ios/ShareExtension/ShareViewController.swift)
- File Provider：[FileProviderItem](../../src/ios/FileProvider/FileProviderItem.swift)、[FileProviderEnumerator](../../src/ios/FileProvider/FileProviderEnumerator.swift)、[AppGroupChangeWatcher](../../src/ios/FileProvider/AppGroupChangeWatcher.swift)
- Live Activity：[AgentLiveActivityWidget](../../src/ios/AgentWidget/AgentLiveActivityWidget.swift)
