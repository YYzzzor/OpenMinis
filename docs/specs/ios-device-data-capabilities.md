# MinisX 手机数据与设备能力清单

## 1. 文档定位与核查基线

本文面向项目使用者与开发 Agent，说明当前 iOS 实现提供哪些接口、可以读取或写入哪些数据，以及能力边界。它是现有实现的说明，不是待开发功能承诺，也不新增开发或审批规则。

- 核查日期：2026-09-18。
- 仓库分支：`feat/minisx-branding`。
- 源码基线：`3c0eb138c2b4e2de743ca8a4a36a3a5dc88b5472`；核查时工作区已有文档与技能变更，本文涉及的应用源码未修改。
- 项目最低系统版本：iOS 26.0。
- 验证程度：核对注册入口、命令分发及关键实现；没有访问真实手机数据，没有逐项实机测试。
- “已实现”表示代码中存在对应处理路径，不代表当前设备已授权、系统支持所有数据类型，或操作必然成功。后续源码变化可能使本清单过时。

### 与现有 Spec 的关系

| 现有文档 | 相关内容 | 与本文的区别 |
| --- | --- | --- |
| [iSH 与 iOS 沙盒概述](ios-sandbox-ish-summary.md) | 第 3 节介绍挂载，第 4 节介绍原生工具桥接 | 说明架构与执行机制；具体接口、能力及读写边界集中在本文 |
| [minis URL 规范](minis-url-scheme.md) | 文件路径、附件、工具结果的 URL 表示与显示 | 不是手机数据权限或原生能力清单，且包含规划中的增强 |
| [调试服务 API](debug-server-api.md) | 调试连接、视图、日志、文件和聊天调试等 | 属于调试接口，不能直接视为普通 Agent 在发布版本中可用的手机数据接口 |

## 2. Agent 接口与苹果系统 API 的关系

Agent 通常通过 `shell_execute` 执行项目封装的 `apple-*` 命令；iSH 将命令转交给原生处理器，再调用苹果系统框架，结果通常以 JSON 返回。`apple-calendar` 等名称是项目接口，不是苹果官方 API 名称。

```text
用户请求 → Agent 的 shell_execute → apple-calendar 等项目命令
        → iOS 原生处理器 → 苹果系统框架 → 返回执行结果
```

例如日历命令最终使用 EventKit 的 `EKEventStore`、`EKEvent` 等对象；照片使用 PhotoKit；健康数据使用 HealthKit。这里的“框架”是苹果提供的一组系统功能接口。

文件另有 `file_read`、`file_write`、`file_edit` 工具；网页另有 `browser_use` 工具。核心入口：

- [Agent 工具分发](../../src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift)：`shell_execute`、文件、网页、图片和记忆工具。
- [原生命令注册](../../src/ios/iSH/ISHKernel.m)：`*_offload_register` 调用。
- [原生工具公共函数](../../src/ios/NativeOffloads/NativeOffloadUtils.m)：参数、路径与结果处理。

下文列出常用子命令和能力，不替代完整参数文档；实际使用时可结合对应命令的 `--help` 与处理实现。

## 3. 个人数据读写

| 类别与项目接口 | 读取能力 | 写入或修改能力 | 当前边界与源码 |
| --- | --- | --- | --- |
| 日历 `apple-calendar` | 日历列表、事件、忙闲时间 | `create` / `update` / `delete`；标题、起止时间、地点、备注、提前提醒等 | 创建时没有重复规则参数；已有重复事件的修改、删除支持 `--occurrence-date`、`--span this\|future\|all`。[CalendarOffload](../../src/ios/NativeOffloads/CalendarOffload.m) |
| 提醒事项 `apple-reminders` | `list` 查询提醒事项及状态等 | `create` / `update` / `delete`；`complete` 标记完成、`complete --undo` 恢复未完成；截止时间、列表选择、优先级、备注等 | 没有创建提醒事项列表的独立命令；传入 `--parent-id` 会报不支持，不能创建子任务。[RemindersOffload](../../src/ios/NativeOffloads/RemindersOffload.m)，实际委托给 CalendarOffload |
| 照片与视频 `apple-photos` | `list` / `near` / `albums` / `album` / `stats` / `export`；查询时间、位置、收藏等信息，导出资源 | `import` / `save` 导入；`create-album`、`add-to-album`；`favorite`；`delete` | 受照片授权范围限制；删除需传资源 ID 和 `--confirm`。没有相册删除、重命名、移出相册或照片原位编辑命令。[PhotosOffload](../../src/ios/NativeOffloads/PhotosOffload.m) |
| 健康 `apple-healthkit` | 步数、心率、睡眠、运动、体重、血氧、血糖、营养等记录；多种类型和日期范围查询 | `log` 写入支持类型的数量或分类样本；`log-blood-pressure` 写血压；`delete` 删除受支持样本 | 部分类型只读或受系统写入限制；删除限定本 App 来源。详细边界见下文。[HealthKitOffload](../../src/ios/NativeOffloads/HealthKitOffload.m) |
| 剪贴板 `apple-clipboard` | `get` 读取当前文本/URL；`get --image` 导出图片；`status` 查看内容类型 | `set` 写入文本；`clear` 清空 | 没有剪贴板历史，没有写入图片命令。[ClipboardOffload](../../src/ios/NativeOffloads/ClipboardOffload.m) |
| 文件 `file_read` / `file_write` / `file_edit` 与 shell 文件命令 | App 可访问的工作文件、附件，以及用户选择并挂载的文件夹 | 新建、修改；通过文件命令移动、删除等 | 不代表可访问整个手机文件系统；外部文件夹写入同时受系统权限与用户允许写入设置限制。[MountedFoldersManager](../../src/ios/Views/Settings/MountedFoldersManager.swift)、[MountedFolderCoordinator](../../src/ios/Views/Settings/MountedFolderCoordinator.swift) |
| 位置 `apple-location` | `current` 获取当前位置；`geocode` 坐标转地址；`forward` 地址转坐标 | 无修改设备位置接口 | 没有历史轨迹查询、持续位置记录命令。[LocationOffload](../../src/ios/NativeOffloads/LocationOffload.m) |

### 健康数据的特殊边界

- `types` 可查看类型，`batch` 可批量查询受支持的类型。类型注册表涵盖数量型和分类型数据，但不能把“出现在类型表中”理解为“系统允许写入”。
- `log` 已实现数量样本、分类样本的构造和保存，例如体重、饮水、步数、心率、睡眠等；具体类型仍受系统授权和保存规则限制。
- 血压通过 `log-blood-pressure` 同时提供收缩压和舒张压，构造关联记录；不能用 `log` 分别写入这两个血压值。
- `delete` 接受数量型、分类型注册表中的类型，并通过 `HKSource.defaultSource` 限定为本 App 写入的样本；不能删除 Apple Watch 或其他 App 写入的记录。
- 没有修改生日、血型等个人特征，或创建完整运动记录、心电图、情绪记录的专门命令；这些对象也不属于通用 `delete` 的直接删除范围。
- `ecg` 返回心电记录的元数据、分类等，没有电压波形；`vision-rx` 返回视力处方的类型、日期、来源等，没有详细验光参数。
- 命令名称不总能完整表达算法：`cadence` 当前返回步行速度和步长，未计算步频；`elevation` 以爬楼层数乘以 3 米估算爬升高度。

### 文件夹挂载的含义

用户通过系统文件夹选择器选中一个文件夹后，项目保存访问凭据，并把它接入 `/var/minis/mounts/` 下的路径，使 Agent 可以通过文件工具或 shell 访问。写入有效条件为 `isWritable && userAllowWrite`：系统允许写入，并且用户允许修改。挂载不会赋予其他 App 私有目录的任意访问权。

## 4. 系统功能与外部设备

| 能力与项目接口 | 已实现操作 | 范围与限制 |
| --- | --- | --- |
| 闹钟/倒计时 `apple-alarm` | `set`、`timer`、`list`、`cancel`；闹钟支持不重复、每天、工作日重复 | 管理本 App 通过 AlarmKit 创建的闹钟和计时器，不能当作“时钟”App 全部闹钟的管理接口。[AlarmOffload](../../src/ios/NativeOffloads/AlarmOffload.m)、[Swift 实现](../../src/ios/NativeOffloads/AlarmOffloadBridge.swift) |
| 通知 `apple-notification` | `schedule`、`pending`、`delivered`、`cancel`、`settings` | 本 App 的通知；安排通知当前使用 `repeats:NO`，没有重复通知参数；取消针对待发送通知。不能读取其他 App 的通知。[NotificationOffload](../../src/ios/NativeOffloads/NotificationOffload.m) |
| 智能家居 `apple-homekit` | `list`、`search`、`get`；`set` 修改可写特征；`scenes`、`trigger` 查询和执行已有场景 | 例如设备开关、亮度、目标温度；没有新增或删除家庭、房间、配件、场景及修改自动化的命令。[HomeKitOffload](../../src/ios/NativeOffloads/HomeKitOffload.m) |
| 蓝牙 `apple-bluetooth` | `status`、`scan`、`connect`、`disconnect`、`services`、`read`、`write`、`notify` | 操作外部 BLE 低功耗蓝牙设备提供的服务和数据项；读写需要连接并发现相应数据项。不是读取手机内部数据或所有已配对设备内容的接口；无响应写入的返回不等于外设已执行。[BluetoothOffload](../../src/ios/NativeOffloads/BluetoothOffload.m) |
| NFC `apple-nfc` | 标签扫描、NDEF 标准格式读写、部分标签原始页/块读写、外部智能卡命令、FeliCa 读取、EMV 卡数据读取和内置词典查询 | 能力取决于外部标签/卡的类型、协议与权限；不读取本机 Apple Wallet 或安全芯片。`read-emv` 可能返回卡号、有效期等，并非只有掩码；没有账户余额或交易历史查询实现。[NFCOffload](../../src/ios/NativeOffloads/NFCOffload.m) |
| 设备状态 `apple-device` | `info`、`battery`、`storage` | 设备/系统信息、电池、总/剩余容量、本 App 内存等只读信息；没有文件遍历、清理存储、重启或任意修改系统设置命令。[DeviceOffload](../../src/ios/NativeOffloads/DeviceOffload.m) |
| 音乐 `apple-media` | `now-playing`、`search`、`play-search`、播放/暂停/切歌、音量查询和调整等 | 使用系统音乐播放器和媒体库查询；不是任意第三方播放器控制，也不是整个在线 Apple Music 曲库搜索；没有歌曲或播放列表增删编辑命令。[MediaOffload](../../src/ios/NativeOffloads/MediaOffload.m) |

## 5. 数据处理与应用内能力

| 接口 | 当前用途 | 关键限制与源码 |
| --- | --- | --- |
| `apple-speech` | 给定音频文件或麦克风实时收音转文字；查看语言、状态 | 麦克风默认 10 秒、上限 60 秒；无保存原始录音文件命令。`--on-device` 仅设备支持时启用，不能保证强制离线。[SpeechOffload](../../src/ios/NativeOffloads/SpeechOffload.m) |
| `apple-speak` | 文字朗读、列出语音、停止朗读 | 播放语音，不生成音频文件。[SpeakOffload](../../src/ios/NativeOffloads/SpeakOffload.m) |
| `apple-player` | 播放可访问的本地音视频；暂停、恢复、跳转、停止、查询播放会话 | 输入必须是可访问的本地文件；不是全手机文件检索。[PlayerOffload](../../src/ios/NativeOffloads/PlayerOffload.m)、[Swift 实现](../../src/ios/NativeOffloads/PlayerOffloadBridge.swift) |
| `ffmpeg` | 音视频处理、转码等 | 受可访问输入、所编译功能及运行条件限制。[FFmpegOffload](../../src/ios/NativeOffloads/FFmpegOffload.m) |
| `apple-vision` | 图片文字识别、条码、分类、矩形和人脸位置检测、多图相似度等 | 对给定图片文件分析，没有直接拍照命令；人脸检测不是身份识别。[VisionOffload](../../src/ios/NativeOffloads/VisionOffload.m) |
| `apple-nlp` | 语言识别、分词、词性、实体、情感、词向量等 | 处理给定文本，不自动读取手机数据库；向量是系统提供的词级向量。[NLPOffload](../../src/ios/NativeOffloads/NLPOffload.m) |
| `apple-maps` / `apple-weather` | 地点、路线、预计时间；当前天气、预报等 | 查询服务，不代表能读取地图 App 的私人历史。[MapsOffload](../../src/ios/NativeOffloads/MapsOffload.m)、[WeatherOffload](../../src/ios/NativeOffloads/WeatherOffload.m) |
| `apple-open` | 打开系统支持的 URL、跳转其他 App 或设置页面 | 跳转不授予目标 App 数据访问权，也不代表完成电话、邮件等后续操作。[OpenOffload](../../src/ios/NativeOffloads/OpenOffload.m) |
| `browser_use` / `minis-browser-use` | 操作应用内网页：导航、读取、截图、点击、输入、脚本等 | MinisX 内置浏览器范围；不是系统 Safari 全部历史或 Cookie 的读取接口。[BrowserUseOffload](../../src/ios/NativeOffloads/BrowserUseOffload.m) |
| `minis-sessions-cli` | 列出/搜索会话、读取消息、发起或继续会话、重试、查询状态、打开会话 | MinisX 自身会话，不是其他聊天 App 的记录。[SessionsOffload](../../src/ios/NativeOffloads/SessionsOffload.m) |
| `minis-config` | 读取、修改已开放的应用配置，查询和回退配置变更记录 | MinisX 应用配置；写操作有用户确认流程，不是任意系统设置修改。[ConfigOffload](../../src/ios/NativeOffloads/ConfigOffload.m) |
| `memory_get` / `memory_write`、`read_image` | Agent 记忆读写、读取可访问图片 | 不扩展系统数据权限。[Agent 工具分发](../../src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift) |

注册入口还包含模型调用辅助工具 `minis-model-use` 与诊断工具 `minis-debug`。它们不构成新的手机个人数据访问类别；`minis-debug` 的部分 RPC 子命令只在调试构建中可用，不能由“命令已注册”推断发布版本支持全部调试功能。

## 6. 授权、缺失能力与容易混淆的范围

### 授权与执行条件

- 苹果系统授权、数据类型规则、硬件及服务可用性共同限制实际执行范围，例如照片可能只授权部分资源，健康类型可能不能写入。
- 项目另有应用内工具权限设置，包括直接允许、会话询问、禁止；这与 iOS 系统授权是不同层次，不能相互替代。其命令识别和覆盖范围也不能理解为所有 shell 操作的完整安全隔离。[OffloadPermissionManager](../../src/ios/Agent/Offload/OffloadPermissionManager.swift)
- `--confirm` 等参数是命令层面的执行条件，不应仅凭参数存在就宣称已经获得用户意图确认。
- 数据处理工具的存在不保证离线执行，也不保证 Agent 后续不会把工具结果交给当前配置的模型；本文不作数据流向或隐私审计结论。

### 当前未发现对应直接接口

- 通讯录：没有找到 `apple-contacts` 注册、ContactsOffload 或 `CNContactStore` 读写实现；权限用途描述不构成功能实现。
- 短信、通话记录、微信等第三方聊天记录、其他 App 私有数据库：当前原生工具清单没有对应直接读取接口。
- Apple 钱包中的本机卡片、系统 Safari 的全部历史和 Cookie、其他 App 通知：不能从 NFC、内置浏览器或本地通知能力推导出这些权限。
- 用户主动导出、分享或选中某个文件后，项目可以在授权范围内处理该文件；这与直接读取来源 App 的数据库不同。

### 周期性任务的三种不同含义

| 用户目标 | 本次核查结论 |
| --- | --- |
| 在日历里创建每周/每两周重复的事件 | `apple-calendar create` 尚未接入重复规则 |
| 设置每天/工作日重复的闹钟 | `apple-alarm` 已有对应实现 |
| 让 Agent 在未来定期醒来，重新读取数据、推理并执行操作 | 不能由日历、闹钟或本地通知能力推断；还需单独核查任务调度和 iOS 运行条件，本文未验证该能力 |

判断后续需求是否可直接实现，可以依次检查：系统是否开放所需操作、项目是否已封装、所需授权和运行条件是否满足。源码变化时，可从第 2 节的注册和工具分发入口重新核查本文相关类别。
