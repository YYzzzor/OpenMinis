---
description: MinisX iOS App Intents、Shortcuts、分享扩展、文件提供器、通知和 Live Activity 等系统入口的契约与降级边界。
---

# MinisX iOS 系统入口与扩展

导航：[Spec 索引](index.md)；`minis://` 路由和安全边界见 [Minis URL Scheme](minis-url-scheme.md)；Agent 内部运行状态见 [iOS Agent 运行生命周期](ios-agent-run-lifecycle.md)。

状态：2026-09-29 当前实现说明及跨入口一致性约定。本轮静态核查 [Agent/Intents](../../src/ios/Agent/Intents)、[ShareExtension](../../src/ios/ShareExtension)、[FileProvider](../../src/ios/FileProvider)、[AgentWidget](../../src/ios/AgentWidget) 和各 target entitlement；没有运行 Shortcuts、分享扩展、Files 或 Live Activity。

## 共同边界

主 App、ShareExtension、FileProvider 和 AgentWidget 是不同进程/target。它们只能通过明确的 App Group 文件、UserDefaults、ActivityKit/AppIntent 或深链协议交换状态，不能假设共享内存或主 App 一直运行。

所有正式 target 当前使用 App Group `group.com.yyzzzor.minisx`，bundle namespace 为 `com.yyzzzor.minisx`。改标识、Team、entitlement 或容器路径时必须一起核对主 App 和三个扩展；单 target 成功签名不证明跨进程数据可见。

系统入口发起动作不等于 Agent 最终完成。系统可能限制扩展寿命、暂停 AppIntent 唤醒的进程、拒绝通知或不打开主 App。入口需要返回可理解的已接收/运行中/已完成/失败状态，并提供会话 id 或恢复入口。

## App Intents 与 Shortcuts

当前公开入口包括 Ask MinisX、Send Prompt、Quick Task、Follow Up Session、Retry Run、Get Session Status、List Sessions 和 Open Session；短语由 `MinisShortcutsProvider` 及各 locale 的 `AppShortcuts.strings` 暴露。

### 前台与无界面运行

- `AskMinisIntent` 和 `OpenSessionIntent` 打开主 App，并把目标 session 交给导航层。
- Send Prompt、Quick Task、Follow Up 和 Retry 默认 `openAppWhenRun = false`，可以先返回结构化 session/result，再由 Agent 在进程允许的时间内继续。
- `waitForResult = false` 返回 Running/Retrying 只证明请求已发起，不证明 Agent 最终完成；调用方应使用通知或 Get Session Status 观察后续结果。
- `waitForResult = true` 等待当前 ViewModel 的 processing 结束并返回最后一个非内部 assistant 文本，但仍受系统执行时限约束，不是无限后台承诺。

无界面启动会尽早登记 session activity，并可在用户启用增强后台能力时尝试 keep-alive。placeholder session id 必须在真实 id 建立、失败或提前返回时清理，避免主界面、状态 Intent 和 Live Activity 出现幽灵运行任务。`ShortcutRunTracker` 的 pending 记录用于下次前台提示“可能未完成”，它不是后台成功证据。

### 会话、模型和附件

Send Prompt 的 session 为空时创建新会话，并标记来源为 shortcut；继续已有会话或 Retry 不应覆盖会话原来的来源属性。已有会话正在运行时，Follow Up/Retry 当前等待其结束再继续，不能与同一会话并发改写历史。

Shortcuts 可以选择 direct model 或 model group，转换为正常 `SessionModelBinding`；实际可用性和 fallback 遵守 [Provider 路由规范](ios-provider-model-routing.md)。图片、视频和文件通过 `IntentFile` 复制为会话附件，文件名缺扩展名时按 UTType 补全；入口不得把附件存在等同于上传已完成。

Retry 从选定 user message 截断后续分支；无 user message 时返回 Error 并清理 pending/activity。其数据语义与 App 内历史重跑一致，不能另建一套较弱的删除规则。

### 通知和状态查询

每次运行的通知开关与 App 全局任务通知开关共同生效。禁用通知不应阻止任务本身；通知投递失败也不能改变 session 的真实状态。点击任务通知通过 session id 路由到对应会话，冷启动时必须优先处理该明确目标，不能被默认 Launch Session 偏好覆盖。

Get Session Status 读取 activity tracker、持久化 session/message 和可用 ViewModel，返回的是当前可观察快照。进程被系统暂停时 tracker 可能过时，因此状态 Intent 不应把单一内存布尔值宣称为远端完成证明。

## Share Extension

分享扩展把 URL/短文本作为 inline text，把长文本、图片、视频和文件复制到 App Group 的共享目录，再保存 `PendingShare`。连续分享在主 App 消费前会在 300 秒窗口内合并，附件名加入 UUID 片段以避免覆盖；超过窗口的旧内容应由主 App 视为遗留并清理。

保存后扩展尝试打开 `minis://share` 并结束 extension request。`openURL` 尝试失败时，数据可能已经留在 App Group；不能向用户声称主 App 已展示。主 App 消费成功后应清理 pending 记录和已搬运文件，重复启动不得重复插入同一分享。

分享的 file URL 使用 security-scoped access；图片当前转为 JPEG。复制、编码或容器不可用时必须可观察失败，不能创建只有文件名而无文件的附件。

## File Provider

FileProvider 通过 replicated extension 把 App Group 下 `MinisFileProvider/` 暴露到 Files，顶层为 `memory`、`skills` 和 `shared`。这是可读写文件入口：在 Files 中创建、修改、移动或删除会影响主 App 可见内容，必须保持路径校验、防止逃逸根目录，并用系统 change signal 通知枚举刷新。

文件监听和 signal 是尽力而为；扩展被暂停后会在恢复时重新扫描并通知根目录/working set。看到 Files 中缓存条目不证明磁盘内容已最新。系统保留的 trash identifier 不能作为普通路径；当前实现会把历史假 trash 内容移到 `shared/_recovered_trash` 再清理冲突目录。

FileProvider 进程可能独立于主 App 启动。初始化、迁移和日志路径不能依赖主 App 已先运行；也不能把扩展崩溃或系统缓存状态解释为业务文件已丢失，需核对 App Group 实体文件和系统错误。

## Live Activity 与 Widget

AgentWidget 展示主 App 通过 ActivityKit 发布的 session 摘要、运行/完成数量、工具状态和可选朗读状态。Widget 不拥有 Agent loop，也不能直接读取主 App 内存；内容应来自 `AgentActivityAttributes.ContentState`。

Privacy Mode 下不得展示消息内容、工具细节或 loop 等敏感运行元数据。完成态停止递增计时，显示静态耗时；软完成与 Activity 真正 end 要区分。

当前正式 target 最低 iOS 26.0，朗读按钮通过 AppIntent/Darwin notification 请求主 App 切换 TTS。源码保留的 iOS 17 availability 检查及更早系统只读图标分支属于历史兼容代码，不代表当前产品支持或需要验收 iOS 16.x。点击按钮成功只表示请求已发送，主 App 未运行、无已加载音频或系统限制时可能不产生播放变化。

## 场景与验收

### 场景 A：Shortcuts 异步发送新 prompt

返回包含真实 session id、实际解析的模型显示和 Running；主 App 列表/状态 Intent/Live Activity 不出现 placeholder；最终完成或可能被系统中断均有可观察结果。关闭通知时不投递通知但任务语义不变。

### 场景 B：Shortcuts Retry 无可重试消息

返回 Error，不截断会话，不保留 pending marker 或 active session；状态查询和 Live Activity 不显示幽灵任务。

### 场景 C：快速连续分享两个附件

主 App 尚未消费时第二次保存合并第一份 pending items；打开主 App 后两者各出现一次，文件名不冲突；超过窗口的遗留内容不静默混入新分享。

### 场景 D：Files 修改 shared 文件

修改发生在 App Group 受控根目录，主 App 最终收到刷新；扩展暂停/恢复后能重枚举。路径逃逸、系统 trash 标识和权限失败均不导致根目录外写入。

### 场景 E：锁屏 Privacy Mode

前提：当前支持的 iOS 26+ 环境。Live Activity 仍能显示是否运行/完成，但不显示消息、工具/loop 敏感细节；完成后 timer 停止。朗读按钮的请求投递与实际播放变化分别核查，不以历史旧系统图标分支作为当前兼容验收。

## 待验证与待确认

- 待验证：iOS 26 真机的无界面 AppIntent 完成率、系统暂停与 pending 指引、通知冷启动路由、分享扩展打开主 App、Files 写入/删除和 Live Activity 交互。
- 待确认：`waitForResult` 是否需要产品级最大等待时间与明确 timeout 状态；当前实现等待 processing publisher，主要上限来自系统环境。
- 待确认：分享扩展打开主 App 失败时是否需要 extension 内显式成功/失败 UI；当前路径以日志和下次消费为主。
