# MinisX 发布状态

更新日期：2026-09-28（Asia/Shanghai）。

## 最新提交：1.13（6）

2026-09-28，维护者在 Xcode 手动完成 Archive 和 Distribute，并在本次对话确认“现在已经在手机上用上了”。本次记录为 **1.13（6）已上传、已在维护者手机安装使用**；分发范围沿用 TestFlight Internal、仅维护者本人。上传结果由本机归档元数据核对，手机安装使用依据维护者反馈；没有重新访问 App Store Connect 后台或重新上传。

### 本次内容

本轮合并记录以下三个未提交任务的交付内容；其中语音界面与实时转录已进入 Build 5，Build 6 包含后续调整和两行默认输入框。

| 任务 | Build 6 中的内容 |
| --- | --- |
| [语音输入 UI 正式接入](<../tasks/active/26-09-28 语音输入 UI 正式接入/task.md>) | 正式聊天接入同屏语音面板：一键开始、停止后保留草稿、切回键盘编辑、继续录音和独立发送；复用输入模型及语言等设置。调整文字与语音切换动画，修复控件重叠和残影；错误提示缩短为 1 秒。波形采用固定 20 条、40ms 平滑和 0.8 倍灵敏度，并限制刷新范围、减少音频统计中的复制与分配。 |
| [实时语音转录](<../tasks/active/26-09-28 实时语音转录/task.md>) | 系统在线和离线识别复用同一音频采集，边说边显示临时结果并替换修订，停止后等待终稿；保留原有草稿，处理编辑后续录和迟到回调。第三方继续原有批量识别路径；显式离线不可用时提示失败，不静默转在线。加入识别请求轮换、音频缓存上限和终稿等待超时。 |
| [输入框默认两行高度](<../tasks/active/26-09-28 输入框默认两行高度/task.md>) | 空白和单行草稿默认预留两行高度，文字保持顶部对齐，并随输入字号设置变化；多行继续自然增长，保留原有 120pt 上限及滚动行为，未调整 iPad 固定输入分支。 |

### 构建与交付证据

- 归档时间：2026-09-28 **18:26:54**（Asia/Shanghai）；上传成功时间：**18:31:41**。归档 `Info.plist` 中 preparation 和 upload 事件均为 `success`，`uploadedBuildNumber=6`。
- 归档位置：`/Users/huyuanzhao/Library/Developer/Xcode/Archives/2026-09-28/Minis 9-28-26, 6.26 PM.xcarchive`。
- 包内编号：主应用、ShareExtension、FileProvider、AgentWidget 均为 **1.13（6）**；最低 iOS 26.0，Xcode build `27A266a`，主应用架构 arm64。当前源码中四个正式产品的八个 Debug/Release 配置也均为 Build 6。
- 发布身份：Team `42486W5YRY`，主 Bundle ID `com.yyzzzor.minisx`，App Store Connect app ID `6816328476`；本地分发记录 ID `2e834ce3-a210-41a7-918b-f23b0d2bd386`。元数据中的 `uploadDestination=App Store` 表示上传渠道，不代表已公开上架 App Store。
- 上传元数据未列出错误或警告；本轮未独立检查完整分发日志、签名权限或 dSYM，不能据此断言 Build 5 的第三方符号警告已消失。
- 源码背景：记录时位于 `main`，HEAD `40ac6a55e1861827df68927dd78fc8cdf8f79d65`，以上三个任务及相关工程、测试、预览与本地化提取变更仍未提交。本次手动归档没有事前冻结的完整源码清单，因此任务范围按当前工作区与任务记录追溯，不宣称已经证明归档与当前全部文件逐字一致。Harness 规则和开发运行设置不作为产品功能列入更新内容。

### 验证范围与保留项

- 实时转录：已有 Debug 构建、17 项局部测试（10 项生命周期、7 项音频管道）及两轮非阻断审查记录。真机首字延迟、长停顿、长语音切换、离线语言支持和耗电表现仍需专项体验；阿里/讯飞原有 HTTP 接入与 WebSocket 协议不符的问题不在本次修复范围。
- 语音界面：已有界面切换、权限失败和键盘相关验证。波形 7 项测试通过时使用的是 0.6 倍灵敏度；随后改为 0.8 倍并同步测试预期，后续整体编译通过，但未重跑该组测试，最终波形专项审查也未闭环。
- 两行输入框：generic iOS Debug 和 iPhone 18 Pro / iOS 27 模拟器构建通过，已安装启动并截图确认空白输入框的两行留白与顶部对齐。不同字号、输入多行再清空等组合未全部做运行时复验。
- 维护者确认手机安装使用，足以更新交付状态，但不等同于上述专项验收全部完成。保留三个任务现有状态，本次不自动归档任务；**只补写发布记录，不创建 Git 提交、不推送**。

### Build 6 提交准备（2026-09-28）

维护者最新反馈：“当前有一些未提交的任务, 准备提交吧, 我在使用的时候暂时没遇到什么问题”。记录为 **Build 6 手机日常使用暂未发现问题**；这补充了前述安装使用证据，不替代尚未执行的专项测试或独立审查。

当前仍为 `main` / `40ac6a55e1861827df68927dd78fc8cdf8f79d65`，暂存区为空，无未完成的合并或变基。三个旧检查点均报告工作区已有变化，符合后续波形、两行输入框、Build 6 与发布文档增量；不回滚工作区以匹配旧快照。本轮更新恢复入口和检查点，保留历史报告原文。

建议按以下顺序组织本地提交，以下仅为范围与提交说明草稿，尚未执行：

| 分组 | 提交说明草稿 | 范围与拆分要求 |
| --- | --- | --- |
| 项目规范 | `docs(harness): require resource efficiency reviews` | `AGENTS.md`、`.agents/skills/review-task/SKILL.md`、`docs/specs/resource-efficiency.md`，与产品功能分开。 |
| 语音功能 | `feat(voice): integrate inline composer and live transcription` | 语音 UI、系统实时识别、波形与音量统计、模型选择器、相关测试和预览、本地化提取，以及两个语音任务记录。UI 与识别共用状态机和文件，按完整功能集提交；工程文件只纳入新增源文件引用，AIChatView 排除两行高度那一块。 |
| 两行输入框 | `fix(chat): reserve two lines in the idle composer` | ChatInputBar 的行高计算、AIChatView 中顶部对齐的最小高度改动及对应任务记录。不得把同文件其他语音增量重复混入。 |
| 发布记录 | `build(ios): record TestFlight build 6 delivery` | 主应用及三个扩展共八处 Build 4 → 6 编号差异、本发布记录和实际使用反馈；Build 5 为中间已发布版本，保留历史，不额外创建虚构的 Build 5 源码提交。 |

暂不纳入上述功能提交：`Minis.xcscheme` 中关闭 Metal API Validation 的三行改动。这是共享开发运行配置，来源意图尚未确认，保留原样、不回退；若需要保存，应单独说明原因后提交，不能当作语音功能必需改动。

正式完成语音任务收尾前，仍需处理最终 0.8 倍波形的专项测试复跑与有效独立审查。用户日常使用反馈未暴露新缺陷，但不能替代这两项证据。其他未量化的专项范围继续如实记录，不在提交准备阶段扩大设备测试或重新发布。

本次仅更新文档与本地检查点；没有改动产品代码、暂存文件、创建提交、推送、归档任务或重新上传。资源影响：纯文档更新，无新增运行时开销。

### 本地提交执行（2026-09-28）

上述准备完成后，维护者明确回复“提交就 ok 了”，授权执行这四组本地提交，不包含远端推送或重新发布。前三组已分别保存为：

- `746e121`：资源审查规范。
- `70e0255`：同屏语音输入、系统实时转录与相关测试、审查记录。
- `bd93bfb`：空白/单行输入框默认预留两行高度。

本段随第四组 Build 6 编号与发布记录一并保存。按改动块拆分共用文件，没有改变工作区产品源码；暂存差异格式检查通过，本轮未重复构建或测试。Metal API Validation 的共享运行设置改动留在工作区，未纳入提交。三个任务保留原有验证边界，不因创建 Git 提交而自动标记验收完成或归档。

## 历史提交：1.13（5）

2026-09-28 13:02:41（Asia/Shanghai），按维护者“先推送到 testflight internal 吧，记得更新 build 号，我自己测试下”的明确指令，完成签名归档并上传 **1.13（5）**。Apple已接收，上传结束时处于处理中；分发限定 **TestFlight Internal Only**，`manageAppVersionAndBuildNumber=false`。尚未独立确认处理完成、内部组可安装或维护者安装使用。

- 构建输入：当前 `main` / HEAD `40ac6a55e1861827df68927dd78fc8cdf8f79d65` 加本轮未提交语音UI、系统实时识别和相关工程/测试文件；主App、ShareExtension、FileProvider、AgentWidget共8个Debug/Release配置从Build 4递增到5。没有Git提交或推送。`source.diff`、`untracked-source/`和`release-input.json`固定差异、未跟踪源码与1887个输入文件摘要；构建及上传后核对无源码漂移。
- 内容与验证：继承已确认的同屏语音面板，新增系统连续音频识别、临时句替换、草稿保留和终稿收尾。Debug构建及17项局部测试通过，两轮Pi审查已逐项处置；本轮Release归档成功，四个正式产品均为1.13（5）/最低iOS26.0，签名、Team、App Group、主App iCloud/WeatherKit、图标与四个自有产品dSYM检查通过。真实声音体验待手机测试；阿里/讯飞原有HTTP接入与官方WebSocket协议不符，本版未修复。
- 环境：Xcode27.0（27A266a），iPhoneOS27.0 SDK，Team `42486W5YRY`，主Bundle ID `com.yyzzzor.minisx`；generic iOS归档未安装到任何新设备。
- 上传证据：`EXPORT SUCCEEDED`、退出码0、App Store Connect app ID `6816328476`、`uploadedBuildNumber=5`、回执 `6bc81c6d-48bc-4e00-8eb7-d4048e6ac18b`。首次上传成功，无重传或自动改号。
- 警告：仍有与Build 4相同的8项第三方框架dSYM缺失警告（FFmpeg、RealTimeCutVADCXXLibrary及6个libav/libsw库）；没有阻断上传，但相关第三方崩溃符号化可能不完整。未出现90890/90892备用图标警告。
- 产物目录：`/Users/huyuanzhao/Library/Developer/Xcode/MinisXReleases/2026-09-28-125416-build5/`；包括 `MinisX.xcarchive`、`archive.log`、`upload.log`、`archive-verification.json`、`release-result.json`、`distribution-logs/`。
- 处理状态边界：本机Xcode账户成功用于上传；随后一次只读`altool --build-status`返回需要独立JWT或用户名+应用专用密码，不能复用本次上传认证。本轮未创建新凭据或扩大账户权限；独立状态查询不可用，保留上传结束时的Processing证据，不宣称内部组可安装。维护者在手机TestFlight看到1.13（5）后自行更新并测试，任务保持active。

## 历史提交：1.13（4）

2026-09-27 23:10:13（Asia/Shanghai），Agent 按维护者明确指令完成签名归档并上传 **1.13（4）**；Apple 回执确认接收成功，上传结束时状态为处理中。分发配置为 **TestFlight Internal Only**，`manageAppVersionAndBuildNumber=false`。维护者随后反馈“已经推送到我的手机上了”，据此记录 Build 4 已到达维护者手机；此为用户反馈，未独立读取后台处理状态或组关联。尚未明确确认安装使用，当前已确认使用版本仍保留 1.13（3）。

- 授权：当前对话用户要求“按照之前写的规范，尝试为 TestFlight Internal 提交一个新的 Build 版本”。发布阶段没有新建任务或对话，也未提交或推送 Git；后续用户授权任务归档和提交准备。
- 构建输入：`/Users/huyuanzhao/Coding/Projects/OpenMinis`，`main`，HEAD `64a953277d32f48082b0f0c83009e36bc9d671e3`；仅将主 App、ShareExtension、FileProvider、AgentWidget 的 Debug/Release Build 3 改为 4。未跟踪的 WeatherKit 调查文档不参与打包。输入差异、索引和未跟踪清单均保存在产物目录，归档后核对 tracked diff 未改变。
- 改动背景：WeatherKit 的问题由维护者启用 App Services 解决，原模拟器已真实取数成功；该修复无需修改天气代码。本次按明确要求重新打包当前源码为新 Build。原因与验收见[已归档调查](<../tasks/archive/26-09-27 WeatherKit 认证失败调查.md>)。
- 环境：Xcode 27.0（27A266a），iPhoneOS 27.0 SDK，最低 iOS 26.0；Team `42486W5YRY`，Bundle ID `com.yyzzzor.minisx`。每条 Xcode 命令临时指定开发目录，没有切换全局 xcode-select。
- 验证：`ARCHIVE SUCCEEDED`；四个正式产品均为 1.13（4），签名验证通过，Team/Bundle ID/App Group 正确，主 App 的 iCloud 和 WeatherKit 权限及描述文件已核对；主图标、四套备用图标引用及文件存在，四个正式产品 dSYM 存在。未据此声称已完成真机运行验收。
- 上传：Xcode 已登录账户可用于命令行自动签名和上传；`EXPORT SUCCEEDED`，退出码 0，回执 `fdae7128-cfcb-40ff-9b0c-4bba4e4d4eb2`，App Store Connect app ID `6816328476`，`uploadedBuildNumber=4`。上传前未独立取得远端构建列表，最终 Apple 成功回执确认候选 4 已被接收。
- 警告：上传有 8 项第三方库 dSYM 缺失警告：FFmpeg、RealTimeCutVADCXXLibrary、libavcodec、libavfilter、libavformat、libavutil、libswresample、libswscale。未阻断上传，但这些库的崩溃符号化可能不完整。没有出现此前 90890/90892 备用图标上传警告。本地编译还有现有并发/旧接口等警告，已保存完整日志及摘要，未在发布中扩展修复。
- 产物根目录：`/Users/huyuanzhao/Library/Developer/Xcode/MinisXReleases/2026-09-27-2302-build4/`；归档 `MinisX.xcarchive`，上传日志 `upload.log`，完整分发日志 `distribution-logs/`，验包 `archive-verification.json`，回执和警告 `release-result.json`，构建输入 `release-input.json` 与 `source.diff`。
- 分发反馈：维护者确认 Build 4 已推送到手机，交付结果已收到用户反馈；未独立核实后台内部组配置。下一步只待安装使用确认，不再要求用户重复证明已收到推送，不重传或增加 Build。

## 当前使用版本

| 项目 | 当前状态 |
| --- | --- |
| 应用 | MinisX |
| 已确认安装使用的版本 | 1.13（6）；维护者已确认手机安装使用 |
| 分发渠道 | TestFlight Internal（内部测试） |
| 使用范围 | 暂时仅项目维护者本人，1 人 |

来源：维护者于 2026-09-28 在本次对话确认已完成 Distribute，并已在手机使用。Agent 随后只读核对本机最新归档：主应用和三个扩展均为 1.13（6），上传元数据记录 Build 6 成功；当前源码编号也为 Build 6。TestFlight Internal、仅本人使用的范围沿用此前确认；未重新访问 App Store Connect 实时后台。此前 Build 3 的安装使用、Build 4 的手机推送和 Build 5 的上传证据保留为历史记录，不再代表当前使用版本。

下一次发布按[MinisX TestFlight 发布流程草案](minisx-testflight-release-draft.md)核对，并重新确认可用 Build 号；不要直接复用草案中的历史候选编号。Agent 已完成过 Build 4、5 的签名归档与自动上传，本次 Build 6 由维护者手动完成并确认手机使用；后台状态读取和组操作自动化仍未验证。

此状态针对 MinisX；README 中保留的 OpenMinis 官方 App Store、TestFlight 链接属于上游项目。


## 备用图标警告修复已验收

2026-09-26：1.13（2）上传出现备用图标尺寸警告90890/90892。四种备用图标已接入Xcode资源目录，保留原图案及选项；本地未签名Release归档及包内资源核对通过。

2026-09-27：维护者确认提交后未再出现同类警告，服务端结果的待确认项已关闭，任务按明确要求归档。此结果来自维护者反馈，未独立读取Apple后台；未提供此次上传的具体构建号，因此不据此改写上方使用版本。具体证据见[备用图标修复记录](<../tasks/archive/26-09-26 修复 TestFlight 备用图标尺寸警告/task.md>)。

## 胶囊版本已发布与历史过程

维护者本次确认包含上下文胶囊的Build 3已通过TestFlight提交并安装使用，取代下列历史阶段“尚未上传”的状态。未据此推定该次归档对应的精确Git提交或全部参数；以下内容保留当时的开发与验证过程。


2026-09-26：依据真机反馈，待发布的上下文占比数字已调整为与输入框占位文字相同的16.5pt，圆环同步放大至19.25pt，并随输入字号设置缩放。构建和普通iPhone18 Pro模拟器默认/最大输入字号布局验证通过；尚未上传TestFlight。

2026-09-26：用户确认A方案后，上下文占比增加与输入工具按钮同色的34pt高胶囊，保留16.5pt字号，胶囊到麦克风为12pt。构建、普通iPhone18 Pro默认字号深浅色和详情入口验证通过；本轮最大输入字号因自动滑动无响应未复验。尚未上传TestFlight。

2026-09-26：上下文胶囊改为一位/两位/三位三档宽度，保留维护者调整的左右各1pt留白、7pt环字间距。新增42%与100%两个Xcode原生预览供微调；构建和一位数模拟器回归通过，两位/三位初值待维护者确认。尚未上传TestFlight。

2026-09-26：一位数留白继续微调，新增1%/9% Canvas，三档宽度改为随一位数基准联动。暂以内容宽64pt（总宽66pt）作为待确认起点，取代先前83.33pt的一位数初值；待维护者视觉确认，未上传TestFlight。


2026-09-27：维护者已在Canvas横向查看并确认一/二/三位胶囊，最终内容宽基准76pt，每多一位增加10.5pt；默认总宽78/88.5/99pt，左右padding各1pt、环字间隔7pt。正式聊天与预览共用组件，源码已采用此值；此确认取代此前64pt待确认起点。尚未上传TestFlight，当前手机版本仍以上方使用状态为准。


2026-09-27 本地提交核对：维护者工作区中的主应用及ShareExtension、FileProvider、AgentWidget的Debug/Release构建号均已设为3，本轮将该现有改动保存为本地提交。此为源码构建编号；未核对新的App Store Connect上传或手机安装状态，上方已确认的TestFlight 1.13（2）使用记录不据此改写。下一次上传仍需确认后台尚未使用的构建编号。


## 发布状态同步（2026-09-27）

本次仅更新已确认的Build 3使用状态。关于由Agent维护构建号、执行Archive、签名上传和内部测试分发的讨论尚未触发新发布；没有增加构建号、修改版本号、生成新归档或上传新构建。
