---
description: MinisX iOS 原生设备数据、系统能力与命令入口的当前清单；用于判断能否读写、所需授权及验证边界。
---

# MinisX iOS 设备数据与原生能力

导航：[Spec 索引](index.md)；权限与副作用规则见 [iOS 工具权限与副作用](ios-tool-permissions-and-side-effects.md)；浏览器细节见 [iOS 浏览器自动化](ios-browser-automation.md)。

状态：当前实现清单，核查于 2026-09-29，源码基线为工作区 `main` / `272da5d` 及其未提交修改。本文不是未来功能承诺；静态存在处理路径不等于系统已授权、外设兼容或真机执行成功。

## 如何使用本清单

Agent 通常通过 `shell_execute` 在 iSH 中执行项目提供的原生命令。iSH 在 [ISHKernel.m](../../src/ios/iSH/ISHKernel.m) 注册 offload，原生处理器再调用苹果框架或 App 内服务。`apple-calendar` 等是项目命令，不是苹果官方 API 名称。

判断一项需求可否执行时，至少分别确认：

1. 注册入口和处理器是否存在；
2. iOS 系统授权、硬件、账号或服务是否可用；
3. App 工具许可和操作级确认是否通过；
4. 该命令是否只读、会修改数据，或会影响外部设备/服务；
5. 需要真机或外部服务验证的结果是否真的观察到。

当前所有正式 target 的最低系统版本为 iOS 26.0。注册表中没有 `apple-contacts`；用途描述字符串或未来注释不能替代实现入口。

## 个人数据能力

| 类别与入口 | 读取 | 写入或动作 | 关键边界与证据 |
|---|---|---|---|
| 日历 `apple-calendar` | 日历、事件、忙闲 | 创建、更新、删除，含重复事件 | 高级重复和系列修改规则见[日历重复创建](ios-calendar-recurrence.md)；系统权限和 EventKit 约束仍适用。[CalendarOffload.m](../../src/ios/NativeOffloads/CalendarOffload.m) |
| 提醒事项 `apple-reminders` | 列表和提醒状态 | 创建、更新、删除、完成/撤销完成 | 支持基础重复和位置提醒；不提供创建提醒事项列表或子任务能力。[RemindersOffload.m](../../src/ios/NativeOffloads/RemindersOffload.m) |
| 照片/视频 `apple-photos` | 查询、相册、统计、导出 | 导入、建相册、加入相册、收藏、删除 | 可见范围取决于 Photos 授权；删除要求资源 id 与命令级确认。没有相册删除/重命名或照片原位编辑。[PhotosOffload.m](../../src/ios/NativeOffloads/PhotosOffload.m) |
| 健康 `apple-healthkit` | 步数、心率、睡眠、运动、血氧、营养等已注册类型 | 写入支持的数量/分类样本、血压；删除本 App 来源的支持样本 | “类型已注册”不代表系统允许读写；不能删除其他来源数据。ECG 与视力处方读取也不是完整原始波形/验光数据导出。[HealthKitOffload.m](../../src/ios/NativeOffloads/HealthKitOffload.m) |
| 剪贴板 `apple-clipboard` | 文本、URL、图片导出、状态 | 写文本、清空 | 无历史记录和写图片命令。[ClipboardOffload.m](../../src/ios/NativeOffloads/ClipboardOffload.m) |
| 位置 `apple-location` | 当前位置、正/反地理编码 | 无设备位置修改 | 无历史轨迹和持续记录接口。[LocationOffload.m](../../src/ios/NativeOffloads/LocationOffload.m) |
| App/挂载文件 | 工作区、附件、用户选择并挂载的文件夹 | 新建、修改、移动、删除 | 不是整个手机文件系统。外部挂载写入要求系统可写且用户开启 App 内写权限；路径模型见 [iSH 概述](ios-sandbox-ish-summary.md)。 |

### 健康数据的额外限制

- 血压由专用命令同时写入收缩压和舒张压，不能拆成两个普通数量样本来推断等价行为。
- 通用删除按本 App 来源过滤，不能用于 Apple Watch 或其他 App 写入的记录。
- `cadence`、`elevation` 等名称不保证等同于医学或设备原始指标；当前实现包含派生或估算逻辑，使用结果前应读对应处理器。

## 系统功能与外设

| 能力与入口 | 当前操作 | 关键边界与证据 |
|---|---|---|
| 闹钟/计时器 `apple-alarm` | 创建、列出、取消闹钟和计时器 | 只管理本 App 经 AlarmKit 创建的对象，不是“时钟”App 全部数据。[AlarmOffloadBridge.swift](../../src/ios/NativeOffloads/AlarmOffloadBridge.swift) |
| 通知 `apple-notification` | 安排、查询待发送/已送达、取消、查看设置 | 只涉及本 App 通知；不能读取其他 App 通知。[NotificationOffload.m](../../src/ios/NativeOffloads/NotificationOffload.m) |
| HomeKit `apple-homekit` | 查询家庭对象和特征、修改可写特征、触发现有场景 | 无创建/删除家庭、房间、配件或自动化命令。[HomeKitOffload.m](../../src/ios/NativeOffloads/HomeKitOffload.m) |
| BLE `apple-bluetooth` | 状态、扫描、连接、服务、读写、订阅 | 外设必须暴露对应 GATT 能力；无响应写入成功返回不证明外设完成动作。[BluetoothOffload.m](../../src/ios/NativeOffloads/BluetoothOffload.m) |
| NFC `apple-nfc` | NDEF、部分原始标签、ISO7816/FeliCa、EMV 读取 | 依赖设备和标签协议；不读取本机 Wallet 或 Secure Element。EMV 输出可能含敏感卡数据，应按高敏感读操作处理。[NFCOffload.m](../../src/ios/NativeOffloads/NFCOffload.m) |
| 设备状态 `apple-device` | 设备、系统、电池、存储、App 内存信息 | 只读；不提供任意系统设置、重启或存储清理。[DeviceOffload.m](../../src/ios/NativeOffloads/DeviceOffload.m) |
| 媒体 `apple-media` | 当前播放、媒体库搜索、播放控制、音量 | 不等同于控制任意第三方播放器或编辑完整 Apple Music 曲库。[MediaOffload.m](../../src/ios/NativeOffloads/MediaOffload.m) |
| URL 打开 `apple-open` | 交给系统打开 URL/App/设置入口 | 成功发起跳转不证明用户完成电话、邮件、登录或目标 App 操作。[OpenOffload.m](../../src/ios/NativeOffloads/OpenOffload.m) |

## App 内数据处理和服务入口

| 入口 | 用途 | 当前边界 |
|---|---|---|
| `apple-speech` | 对给定音频或命令发起的麦克风录音做语音识别 | 与聊天输入框的长生命周期语音草稿不是同一接口；后者见 [iOS 语音输入生命周期](ios-voice-input-lifecycle.md)。 |
| `apple-speak` / `apple-player` | 系统朗读；播放可访问的本地媒体 | `apple-speak` 不生成音频文件；player 不检索全手机文件。 |
| `ffmpeg` | 可访问文件的音视频处理 | 能力取决于编译功能、输入和运行资源。 |
| `apple-vision` / `apple-nlp` | 图片 OCR/检测/分类；文本语言、分词、实体、情感等 | 人脸位置检测不是身份识别；处理输入数据不产生新的系统数据权限。 |
| `apple-maps` / `apple-weather` | 地点、路线、ETA、天气和预报 | 服务查询不等于读取地图 App 私人历史。 |
| `browser_use` / `minis-browser-use` | MinisX 内置 WKWebView 自动化 | 不读取系统 Safari 的全部历史或 Cookie；会话、Cookie 和资源边界见 [iOS 浏览器自动化](ios-browser-automation.md)。 |
| `minis-sessions-cli` | 查询、创建、继续、重试和打开 MinisX 会话 | 仅限 MinisX 自身会话。会话生命周期见 [iOS Agent 运行生命周期](ios-agent-run-lifecycle.md)。 |
| `minis-model-use` | 通过当前 Provider/模型配置发起辅助模型调用 | 路由和凭证前提见 [iOS Provider 与模型路由](ios-provider-model-routing.md)。 |
| `minis-config` | 读取/修改公开的 App 配置并查询回退历史 | 不是任意系统设置；写入受 App 许可和确认控制。 |
| `minis-debug` | 发布构建可读 App 自身日志；部分 RPC 诊断只在调试构建可用 | 详细接口和构建差异见 [Debug Server API](debug-server-api.md)。 |

## 不应从现有能力推导出的访问

- 通讯录、短信、通话记录、第三方聊天 App 私有数据库没有已注册的直接读取入口。
- NFC 不能推导出本机 Wallet 卡片访问；内置浏览器不能推导出 Safari 全部历史/Cookie；本地通知不能推导出其他 App 通知访问。
- 用户主动分享、选择或挂载文件后可在授权范围内处理该文件，不等于直接访问来源 App 的数据库。
- 日历重复、重复闹钟和“Agent 未来定期醒来执行”是三种不同能力。前两者存在专用系统接口，第三者受 iOS 后台执行约束，不能由前两者推导。

## 验证边界与验收场景

本轮只核对注册入口和关键处理器，没有运行构建、模拟器、真机、系统授权、账号服务或外设测试。

| 场景 | 可观察验收 |
|---|---|
| 维护者判断能否读取/写入一类数据 | 能从矩阵找到入口、读写方向、权限/确认边界和源码；无入口时明确“不支持直接访问”。 |
| 新增或删除原生命令 | `ISHKernel.m` 注册、处理器、权限分类、本文矩阵与生成索引保持一致；不能只改命令帮助。 |
| 声称一项真机能力可用 | 除静态路径外，记录系统版本、授权状态、输入条件和可观察结果；外设/服务成功不能由旧测试替代。 |
| 涉及删除、控制或敏感输出 | 同时检查系统授权、App 许可和操作级确认；结果明确说明实际修改对象与失败边界。 |

待验证：本文每类命令在 iOS 26 真机上的授权提示、拒绝恢复、硬件/账号限制和真实结果。未经该证据，只能称“当前源码存在处理路径”。
