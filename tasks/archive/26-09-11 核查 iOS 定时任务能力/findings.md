# 当前 OpenMinis iOS 定时任务能力核查

核查日期：2026-09-11。代码版本：`ios-annotated`，HEAD `8399e1f9889f0d04629d560b5b0f881123524b78`。恢复时检查点匹配，无未完成 Git 操作；应用源码及 Spec 无工作区差异。已有 AGENTS.md 和未跟踪 Harness 文件保留。本次仅更新本任务文档和检查点，不修改应用代码，不提交或推送。

## 1. 结论

**能创建定时通知和闹钟；能由 Apple 快捷指令自动化触发 Agent；没有应用内可跨挂起、终止可靠执行的通用定时 Agent/脚本调度器。** “已创建”“到点触发”和“执行完成”必须分别判断。

| 类型 | 创建与保存 | 一次性 / 周期性 | 到点实际发生什么 |
| --- | --- | --- | --- |
| 当前 Agent 回合内延迟执行脚本 | `shell_execute` 的 `delay`；等待状态在当前异步任务中，没有独立定时任务登记和恢复机制 | 支持一次延迟；反复调用或脚本循环可形成进程内重复工作 | 应用仍有执行时间时，等待结束后调用 shell；不保证挂起期间到点执行 |
| iSH 内 cron / at / nohup 循环 | 可以尝试写脚本或配置文件；本次未确认设备上的命令安装及守护进程状态 | 取决于实际安装和启动的工具，不能据提示文字认定已经支持 | 依赖 Minis 进程运行；保存配置不等于有系统唤醒和重启恢复 |
| `apple-notification schedule` | 向系统 UserNotifications 提交通知请求 | **仅一次性**；`--after` 和 `--at` 均固定 `repeats:NO` | 系统显示通知，不运行 Agent 或脚本 |
| `apple-alarm set` / `timer` | 向系统 AlarmKit 注册闹钟或倒计时；需要 iOS 26+ 及闹钟权限 | 一次性、每天、工作日；倒计时为一次性 | 系统闹钟提醒，不运行 Agent 或脚本 |
| 快捷指令“时间”个人自动化 → Minis “Send Prompt” | 用户在快捷指令 App 配置时间规则；Minis 提供执行动作，没有创建该自动化的应用内工具 | Apple 的时间触发器支持每天、每周、每月；Minis 动作自身没有日期/周期参数，也无独立一次性时间调度入口 | 系统调用 App Intent，随后发送提示并运行 Agent；触发及最终完成仍受权限、设备状态和后台执行条件约束 |

因此，“每天 8 点自动生成日报”应理解为**快捷指令安排触发，Minis 尝试执行**，不能承诺应用被强制退出后仍准时完成。“5 分钟后提醒我”则有系统托管的通知/闹钟路径，不需要让 Agent 一直等待。

## 2. 代码调用链和实际边界

### 2.1 Agent 与 shell：只有进程内等待，没有独立时间调度

调用链：

`AIChatViewModel+ToolDefinitions.swift:19–28` 暴露 `shell_execute(command, timeout, delay)` → `AIChatViewModel+ConcurrentTools.swift:218–319` 解析参数、检查原生工具权限、执行 delay → `AIChatViewModel+ISHCommand.swift:19–56,128–143` → `Agent/ISH/ISHExecutionCoordinator.swift:93–133,265–314` → `iSH/ISHShellExecutor.m:425–436` 的 `do_execve` / `task_start`。

上述路径均在 `src/ios/` 下。delay 实际是每次 `Task.sleep(100ms)` 的计数循环，检查取消并更新倒计时；没有把“绝对执行日期 + 命令”交给系统。即使等待结束，命令也只是在应用获得执行机会后启动，无法证明精确的墙上时钟触发时间。取消、后台中断、shell 超时也会影响结果。

当前协调器以每条命令独立 `/bin/sh` 进程、管道和文件系统上下文执行，并支持并发；不是 Spec 所写的共享 PTY / 全局 FIFO。协调器要求 `ISHKernel.shared.isBooted`。`ISHKernel.m:374–448` 在宿主进程初始化 guest PID 1、挂载和原生工具注册；未启动通用 cron/at 服务。`RootfsManager.swift:58` 起负责安装 rootfs，`deps/prepare_alpine_rootfs.sh:25–37` 指定 Alpine minirootfs 来源，不足以证明目标设备的 cron/at 可用或开机自启。

`AIChatViewModel.swift:1867–1869` 的提示也明确警告 crontab / at / nohup 循环会受挂起影响。其“快捷指令是唯一可靠方式”属于给模型的指导文本，不能代替端到端可靠性证据。

### 2.2 一次性本地通知

从上述 shell 路径执行 `apple-notification` → `ISHKernel.m:431` 注册 → `NativeOffloads/NotificationOffload.m:365–369` 注册 handler 并建立 guest 命令入口 → `notification_handler` 的 schedule 分派（351–352）→ `cmd_schedule`（180–295）。

实现要求 title、body 及 after/at 参数。`--after` 使用 `UNTimeIntervalNotificationTrigger`（216）；`--at` 解析日期后取本地日历年月日时分秒，使用 `UNCalendarNotificationTrigger`（218–233）；两者均 `repeats:NO`。权限申请在 245–269，提交在 272–277；pending、delivered、cancel 可用于后续检查。系统通知权限与项目工具权限是两层独立条件。

仅供说明、未在设备执行的命令：

```sh
apple-notification schedule --title "提醒" --body "检查任务" --after 300
apple-notification schedule --title "提醒" --body "检查任务" --at 2026-09-12T09:00:00+08:00
apple-notification pending
```

**创建结果也有一个静态可见限制：** 277 行等待添加请求回调最多 5 秒，却没有检查 semaphore 是否超时；若回调仍未返回，`addError` 可能仍为 nil，代码会返回成功。因此成功 JSON 不是任何情况下都足以证明系统已经接收，应在到期前核对 pending 列表。此问题仅记录，未复现或修改。

`AppDelegate.swift:39` 注册通知代理。`Agent/Intents/SendPromptIntent.swift:367–397` 的代理在前台只请求 banner/sound，用户点击时仅根据 sessionId 导航。`apple-notification` 创建的内容没有 Agent 提示/命令或 sessionId。通知送达没有接到 `vm.send()`，点击也不是自动执行脚本。

Apple 明确区分请求登记、系统投递和用户交互：已安排的本地通知不依赖应用持续运行；前台交给代理决定展示，后台或应用未运行时由系统展示。见 [Apple：Scheduling and Handling Local Notifications](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/SchedulingandHandlingLocalNotifications.html)。文档是归档版，但对应当前代码使用的 UN API；当前 [Scheduling a notification locally from your app](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app) 搜索摘要也确认同一边界，动态正文未成功获取。

### 2.3 闹钟与其他提醒不能遗漏

`ISHKernel.m:425` → `NativeOffloads/AlarmOffload.m:509–513` → 481–487 的系统版本分派 → `cmd_set_alarmkit`（182–244）→ `AlarmOffloadBridge.swift:83–159` → `AlarmManager.shared.schedule`。

`repeatMode == daily` 转为一周七天，`weekdays` 转为周一至周五，其他值走 `.fixed(fireDate)`（108–134）；倒计时使用 `Alarm.CountdownDuration`（165–209）。配置没有运行 Agent 的 stopIntent/secondaryIntent，也没有到点执行 prompt/脚本的回调。

```sh
apple-alarm set --time 07:30 --label "起床" --repeat daily
apple-alarm set --time 09:00 --label "工作提醒" --repeat weekdays
```

这些也是说明示例，未实际创建。该工具需编译时 iOS 26 SDK 支持、运行时 iOS 26+、AlarmKit 授权；`Info.plist:193` 有权限说明。低于 iOS 26 返回不可用（`AlarmOffload.m:491–499`），没有回退到旧 EventKit 闹钟实现。主应用配置仍是 iOS 16.0 部署目标（`Minis.xcodeproj/project.pbxproj:3186,3240`），不能把测试 target 的 26.2 或单一 API 可用性当作所有安装的统一环境。实际构建未验证。

Apple 文档确认 AlarmKit 的一次性、每周重复和倒计时模型，且系统可在应用未运行时更新闹钟状态，见 [Scheduling an alarm with AlarmKit](https://developer.apple.com/documentation/AlarmKit/scheduling-an-alarm-with-alarmkit)。这支持“系统托管提醒”的判断，不支持“到点运行任意应用代码”；各种终止状态的本项目提醒表现仍待真机验证。

另外，`RemindersOffload.m:95–96` 将 `apple-reminders create` 转给 `CalendarOffload.m:838–922`，写入 EKReminder 的截止日期并保存，没有在该创建路径设置 EKAlarm 或 recurrenceRules。不能把“保存了到期日”直接视为“已验证到点响铃”。`CalendarOffload.m:533–595` 的日历事件创建支持提前提醒 EKAlarm；两者都没有 Agent 调度回调。本报告不将日历/待办管理扩大为代码执行能力。

### 2.4 快捷指令是真实执行入口，但时间规则在外部

`Agent/Intents/MinisShortcutsProvider.swift:13–53` 注册包括 Send Prompt 的动作（该 provider 标记 iOS 17+）。`SendPromptIntent.swift:8–30` 提供提示、会话、模型、附件和 Wait for Result 参数，`openAppWhenRun = false`；没有时间、日期或周期参数。

时间个人自动化 → `SendPromptIntent.perform()`（33）→ 获取/新建会话（86–116）→ 填写 inputText 并 `vm.send()`（136–138）→ `AIChatViewModel.swift:2050` 的 send → `beginBackgroundProcessing()`（2241）→ `runAgentLoop()`（2461）；Agent 如调用 shell，再走 2.1。`QuickTaskIntent.swift:53` 起提供固定提示任务并同样调用 `vm.send()`。

默认不等待结果：SendPrompt 在 219–228 返回 `Running`，完成观察器仍留在应用进程内；开启等待也只是等 `isProcessing` 变为 false（163–165），不会获得永久后台运行权，更不是脚本业务目标成功的独立校验。

`ShortcutRunTracker.swift:96–133` 保存的是已经发起的运行诊断记录；`checkPendingOnForeground()`（138–195）检查、提示并清除残留记录，没有重新提交未来时间任务或自动补跑遗漏周期。

Apple 的 [Event triggers](https://support.apple.com/en-ie/guide/shortcuts/apd932ff833f/ios) 列出时间、每天、每周、每月重复；[Enable or disable a personal automation](https://support.apple.com/guide/shortcuts/enable-or-disable-a-personal-automation-apd602971e63/ios) 说明时间自动化可不经确认运行，个别动作仍可能需要配置。用户需要在快捷指令中创建规则并设置自动运行，事先完成 Minis 模型/凭据、相关工具权限配置。这里没有验证锁屏、冷启动或长脚本的端到端表现，也没有部署外部服务。一次性日期任务不能直接从该时间触发器的周期选项推导为 Minis 已内置支持。

## 3. 生命周期矩阵

以下讨论的是已创建的等待/请求；应用挂起或已终止时，应用本身无法继续执行“创建”代码，须先获得系统允许的运行机会。

| 到期时 Minis 状态 | 进程内 Agent / shell 等待 | 已提交的本地通知 | 已提交的 AlarmKit 闹钟 | 快捷指令定时触发 Agent |
| --- | --- | --- | --- | --- |
| 前台运行 | 可继续等待与执行；仍受取消、工具/模型错误、超时影响 | 前台代理请求横幅和声音；不启动 Agent | 系统提醒；不启动 Agent | 有真实调用入口，是否完成取决于任务条件 |
| 后台仍在执行，尚未挂起 | 有剩余运行时间或保活生效时可继续；不保证长期驻留 | 系统投递 | 系统托管提醒 | 入口被系统调用后可发起任务；长任务完成无保证 |
| 已挂起 | 没有 CPU 执行；错过时间、延后或中断，不能当作到点执行 | 系统负责投递，不依赖 guest/shell | 依据系统托管模型可提醒；未实测 | 系统自动化具备触发机制，具体锁屏唤醒和后续执行需实测 |
| 被系统终止 | 当前 Swift Task / guest 进程消失；文件可能仍在，没有据此自动重建定时工作的实现 | 按“不运行仍可投递”机制处理；本项目未实测 | 系统保存的提醒与进程内任务不同；终止后表现未实测 | 可能由系统重新调用 App Intent；本项目冷启动成功及完成未验证 |
| 用户上划强制退出 | 当前执行消失，不能自行按计划恢复 | 不应与禁止后台代码启动混为一谈；已提交本地通知按系统托管模型应仍可投递，强退场景为文档推断、未实测 | 不能推断为 Agent 执行；强退后的闹钟投递未实测 | **不保证自动拉起或执行完成**；不能宣称快捷指令绕过强退限制 |

Apple DTS 的 [iOS Background Execution Limits](https://developer.apple.com/forums/thread/685525) 明确：普通后台应用会被挂起；没有通用的精确时间或保证周期执行机制。强制退出通常禁止后续后台启动，直到用户手动打开；例外没有稳定公开保证。该页面有 2026-01-09 更新，属于 Apple 工程师官方说明。此一般限制不能被过度外推为“所有 App Intent 在所有版本强退后绝不运行”，本报告保留这部分待测。

`AIChatViewModel+BackgroundTask.swift:12–82` 使用的是 `UIApplication.beginBackgroundTask`，到期且未启用有效增强后台时标记中断并 `stopCurrentCommand()`；有效增强后台分支尝试重新申请。`BackgroundKeepAliveManager.swift:99–101,690–738,1083,1291–1310` 的增强后台受开关、活跃会话和音频条件控制。开关为 true 或重新申请不证明系统实际授予无限运行时间。

`Info.plist:33–44` 声明 liveactivity-refresh 标识及 audio/fetch/location/remote-notification。全局搜索和启动代码核查没有发现 BGTaskScheduler 的注册、请求提交或该标识的处理器，也没有供定时 Agent 使用的远程推送回调。即使未来接入 BGTask，Apple 对 [earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate?changes=_3) 的定义也只是“不早于”，并不保证在所填时间启动。

## 4. 调查范围与证据限制

- 已直接阅读：`src/ios/Agent/Chat` 工具定义、并发分派、shell 桥接、send/Agent 入口及后台处理；`Agent/ISH` 协调器；`Agent/Intents` 的 SendPrompt、QuickTask、通知代理和诊断恢复；`Agent/Background` 保活核心条件；`iSH` 初始化/执行/rootfs；原生 notification、alarm、calendar、reminders；AppDelegate、MinisApp 相关入口、Info.plist、Xcode 配置及 rootfs 准备脚本。
- 对 `src/ios`、`src/shared` 搜索 cron/crond/crontab/atd、BGTaskScheduler/BGAppRefresh/BGProcessing/BGContinued、earliestBeginDate、ScheduledTask、推送注册/接收入口，并沿阳性结果核查实现。排除 Vendor、Resources、JS、JSON、xcstrings 等资源与同名噪音；没有混用 Android ScheduledNotification 实现。否定结论基于工具接口、调用链、初始化和生命周期的组合证据，不仅是关键词未命中。
- 未发现本地 iOS 的专用定时任务登记、系统触发到 Agent 的内部时间处理器及终止后定时任务恢复链。此结论不否认用户可自行安装 Linux 工具、在外部服务器执行工作或额外配置第三方系统；这些不是本次确认的现成应用内能力。没有把调试连接当作能够唤醒已终止 App 的远程调度服务，也未展开无关 Debug API Spec。
- `deps/ish` 子模块未初始化（`git submodule status` 显示 `-de124dd66124a15239cea1465164f74980ada245`），没有补拉依赖。无法验证 guest 内 cron/at 具体二进制、配置、后台子进程清理和补跑策略；也没有用宿主 Linux 的 cron 代替 iOS 测试。
- 本环境没有进行 iOS 构建、模拟器或真机测试。通知是否如期展示、实际权限状态、专注模式/通知设置、时区和夏令时变化、重启、低电量、锁屏、系统回收、强制退出、快捷指令冷启动和长任务完成率均未验证。通知和闹钟的系统托管结论来自代码与 Apple 文档，不是本项目实测保证。
- 后续若要验证实际设备行为，分别创建短延迟通知/闹钟和写入时间戳的 Agent 脚本，记录“请求登记、触发、开始、结束”四个时间点；逐一测试表中生命周期并分别测试一次性/周期性。系统终止需有系统回收证据，不能用手动强退冒充。此清单仅保留验证方向，本次没有创建任何任务或自动化。

## 5. Spec 与 Harness 记录

必读已完成：`docs/specs/ios-sandbox-ish-summary.md` 的完整 2.3、4（含全部子节）；参考已读：Overview、2.1、2.2、2.4、5。保留其 iOS 宿主进程及 native offload 背景，但按当前源码纠正以下调查假设：协调器实际路径为 `src/ios/Agent/ISH/ISHExecutionCoordinator.swift` 且已并发；AlarmOffload 已改用 AlarmKit，另有 RemindersOffload。未修改共享 Spec 或规则。

恢复负担：读取 resume-task 技能、指定任务、record-formats、spec-context；运行恢复 inspect 得到 match。内存索引快速搜索无相关命中，未使用历史结论。CodeGraph 未提供可用工具，直接读源码。调查中按实际需要扩展到 AlarmKit 和 Shortcuts，避免初始入口遗漏能力；部分宽搜索输出过长和 Spec 路径过时后改用精确路径读取。Apple 动态文档正文/Markdown 获取部分失败，用官方归档页、官方支持手册和有明确内容的官方 API 搜索结果补足，未以第三方讨论作为平台依据。

本任务是分析，无行为变更，未启动 Pi 或外部模型审查，未创建审查附件。已更新中间检查点；最终记录将绑定完成后的文档和 Git 状态。没有可靠的本次总耗时/token 计量，不填估算值。本次完成只证明此分析任务的恢复和记录流程可用，不表示父 Harness 的真实开发验收全部完成。
