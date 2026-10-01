---
description: MinisX iOS 原生设备数据、系统能力与命令入口的当前清单；用于判断能否读写、所需授权及验证边界。
---

# MinisX iOS 设备数据与原生能力

导航：[Spec 索引](index.md)；权限与副作用规则见 [iOS 工具权限与副作用](ios-tool-permissions-and-side-effects.md)；浏览器细节见 [iOS 浏览器自动化](ios-browser-automation.md)。

范围：Agent 可以通过原生命令访问的设备数据和系统能力清单，用于判断某项需求能否执行、需要什么授权。

## 使用规则

- **C1** Agent 通过 `shell_execute` 在 iSH 中执行项目提供的原生命令；offload 在 [ISHKernel.m](../../src/ios/iSH/ISHKernel.m) 中注册，由原生处理器调用苹果框架或 App 内服务。`apple-calendar` 等是项目自己的命令名，不是苹果 API 名称。
- **C2** 判断一项需求能否执行，分别确认五件事：注册入口和处理器存在；iOS 系统授权、硬件、账号或服务可用；App 工具许可和操作级确认通过；操作是只读、修改数据还是影响外部设备或服务；需要真机或外部服务验证的结果确实被观察到。
- **C3** 源码中存在处理路径，不代表系统已授权、外设兼容或真机执行成功。声称某项真机能力可用时，记录系统版本、授权状态、输入条件和观察到的结果。
- **C4** 新增或删除原生命令时，`ISHKernel.m` 注册、处理器、权限分类、本文清单和索引一起更新，不能只改命令帮助。
- **C5** 没有注册 `apple-contacts`。用途描述字符串或注释不能代替实现入口。

## 个人数据

| 类别与命令 | 读取 | 写入或动作 | 边界 |
| --- | --- | --- | --- |
| 日历 `apple-calendar` | 日历、事件、忙闲 | 创建、更新、删除，含重复事件 | 重复与系列修改规则见 [日历重复创建](ios-calendar-recurrence.md)；全天、提醒通知与名称匹配见 [日历全天与提醒通知](ios-calendar-all-day-and-reminders.md)。[CalendarOffload.m](../../src/ios/NativeOffloads/CalendarOffload.m) |
| 提醒事项 `apple-reminders` | 列表、提醒状态 | 创建、更新、删除、完成与撤销完成 | 支持基础重复和位置提醒；不能创建列表或子任务。[RemindersOffload.m](../../src/ios/NativeOffloads/RemindersOffload.m) |
| 照片与视频 `apple-photos` | 查询、相册、统计、导出 | 导入、建相册、加入相册、收藏、删除 | 可见范围取决于照片授权；删除需要资源 id 和命令级确认；不能删除或重命名相册，不能原位编辑照片。[PhotosOffload.m](../../src/ios/NativeOffloads/PhotosOffload.m) |
| 健康 `apple-healthkit` | 步数、心率、睡眠、运动、血氧、营养等已注册类型 | 写入支持的数量与分类样本、血压；删除本 App 写入的支持样本 | 见下方“健康数据” |
| 剪贴板 `apple-clipboard` | 文本、URL、图片导出、状态 | 写入文本；`set --image <path>` 写入可访问的图片文件（可同时带文本）；清空 | 没有剪贴板历史记录。[ClipboardOffload.m](../../src/ios/NativeOffloads/ClipboardOffload.m) |
| 位置 `apple-location` | 当前位置、正向与反向地理编码 | 无 | 没有历史轨迹和持续记录。[LocationOffload.m](../../src/ios/NativeOffloads/LocationOffload.m) |
| App 与挂载文件 | 工作区、附件、用户挂载的文件夹 | 新建、修改、移动、删除 | 不是整个手机的文件系统。写入外部挂载要求系统可写且用户开启了 App 内写权限；路径模型见 [iSH 运行契约](ios-sandbox-ish-summary.md)。 |

### 健康数据

- **H1** “类型已注册”不代表系统允许读写该类型。
- **H2** 血压由专用命令同时写入收缩压和舒张压，不拆成两个普通数量样本。
- **H3** 删除只作用于本 App 写入的样本，不能删除 Apple Watch 或其他 App 写入的记录。
- **H4** `cadence`、`elevation` 等名称不一定等同于医学或设备的原始指标，部分包含派生或估算逻辑；ECG 和视力处方的读取也不是完整的原始波形或验光数据导出。使用结果前先读对应处理器。代码见 [HealthKitOffload.m](../../src/ios/NativeOffloads/HealthKitOffload.m)。

## 系统功能与外设

| 能力与命令 | 操作 | 边界 |
| --- | --- | --- |
| 闹钟与计时器 `apple-alarm` | 创建、列出、取消 | 只管理本 App 通过 AlarmKit 创建的对象，不是“时钟”App 的全部数据。[AlarmOffloadBridge.swift](../../src/ios/NativeOffloads/AlarmOffloadBridge.swift) |
| 通知 `apple-notification` | 安排、查询待发送与已送达、取消、查看设置 | 只涉及本 App 的通知，不能读取其他 App 的通知。[NotificationOffload.m](../../src/ios/NativeOffloads/NotificationOffload.m) |
| HomeKit `apple-homekit` | 查询家庭对象和特征、修改可写特征、触发已有场景 | 不能创建或删除家庭、房间、配件、自动化。[HomeKitOffload.m](../../src/ios/NativeOffloads/HomeKitOffload.m) |
| 蓝牙 `apple-bluetooth` | 状态、扫描、连接、服务、读写、订阅 | 外设须提供相应的 GATT 能力；无响应写入返回成功不代表外设完成了动作。[BluetoothOffload.m](../../src/ios/NativeOffloads/BluetoothOffload.m) |
| NFC `apple-nfc` | NDEF、部分原始标签、ISO7816 / FeliCa、EMV 读取 | 依赖设备和标签协议；不读取本机 Wallet 或 Secure Element。EMV 输出可能含敏感卡数据，按高敏感读取处理。[NFCOffload.m](../../src/ios/NativeOffloads/NFCOffload.m) |
| 设备状态 `apple-device` | 设备、系统、电池、存储、App 内存信息 | 只读；不能修改系统设置、重启或清理存储。[DeviceOffload.m](../../src/ios/NativeOffloads/DeviceOffload.m) |
| 媒体 `apple-media` | 当前播放、媒体库搜索、播放控制、音量 | 不能控制任意第三方播放器，也不能编辑整个 Apple Music 曲库。[MediaOffload.m](../../src/ios/NativeOffloads/MediaOffload.m) |
| 打开 URL `apple-open` | 交给系统打开 URL、App 或设置入口 | 成功发起跳转不代表用户完成了电话、邮件、登录或目标 App 中的操作。[OpenOffload.m](../../src/ios/NativeOffloads/OpenOffload.m) |

## App 内数据处理与服务

| 命令 | 用途 | 边界 |
| --- | --- | --- |
| `apple-speech` | 识别给定音频或命令发起的录音 | 与聊天输入框的语音草稿不是同一接口，后者见 [语音输入生命周期](ios-voice-input-lifecycle.md) |
| `apple-speak`、`apple-player` | 系统朗读；播放可访问的本地媒体 | `apple-speak` 不生成音频文件；player 不检索整个手机的文件 |
| `ffmpeg` | 处理可访问的音视频文件 | 能力取决于编译选项、输入和运行资源 |
| `apple-vision`、`apple-nlp` | 图片 OCR、检测、分类；文本的语言识别、分词、实体、情感等 | 人脸位置检测不是身份识别；处理数据不产生新的系统数据权限 |
| `apple-maps`、`apple-weather` | 地点、路线、ETA、天气与预报 | 服务查询不读取“地图”App 的私人历史 |
| `browser_use` / `minis-browser-use` | 内置 WKWebView 自动化 | 不读取系统 Safari 的历史或 Cookie，见 [浏览器自动化](ios-browser-automation.md) |
| `minis-sessions-cli` | 查询、创建、继续、重试、打开 MinisX 会话 | 只限 MinisX 自己的会话，见 [Agent 运行生命周期](ios-agent-run-lifecycle.md) |
| `minis-model-use` | 用当前的 Provider 与模型配置发起辅助模型调用 | 路由和凭证见 [Provider 与模型路由](ios-provider-model-routing.md) |
| `minis-config` | 读取和修改公开的 App 配置，查询回退历史 | 不是任意系统设置；写入受 App 许可和确认控制 |
| `minis-debug` | `logs` 在所有构建中可读 App 自身日志；部分 RPC 诊断只在调试构建可用 | 见 [Debug Server API](debug-server-api.md) |

## 不能推导出的访问

- **X1** 通讯录、短信、通话记录、第三方聊天 App 的私有数据库都没有直接读取入口。
- **X2** NFC 不代表能访问本机 Wallet 卡片；内置浏览器不代表能访问 Safari 的历史和 Cookie；本地通知不代表能访问其他 App 的通知。
- **X3** 用户主动分享、选择或挂载的文件，可以在授权范围内处理；这不代表能直接访问来源 App 的数据库。
- **X4** 日历重复事件、重复闹钟、“Agent 未来定期醒来执行”是三种不同的能力：前两者有专用系统接口，第三者受 iOS 后台执行限制，不能由前两者推导出来。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 判断能否读取或写入某类数据 | 能在清单中找到命令、读写方向、权限与确认边界和源码；没有入口时明确回答“不支持直接访问”（C2、X1） |
| 新增或删除原生命令 | 注册、处理器、权限分类、本文清单与索引一致（C4） |
| 声称某项真机能力可用 | 记录系统版本、授权状态、输入条件和观察结果；外设或服务的成功不能用旧测试代替（C3） |
| 涉及删除、设备控制或敏感输出 | 同时检查系统授权、App 许可和操作级确认；结果写明实际修改的对象和失败边界（C2） |

## 代码入口

- offload 注册：[ISHKernel.m](../../src/ios/iSH/ISHKernel.m)（`*_offload_register`）
- 各命令处理器：[NativeOffloads](../../src/ios/NativeOffloads)
