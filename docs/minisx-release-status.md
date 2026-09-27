# MinisX 发布状态

更新日期：2026-09-27（Asia/Shanghai）。

## 最新提交：1.13（4）

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
| 已确认安装使用的版本 | 1.13（3）；Build 4 已收到手机推送 |
| 分发渠道 | TestFlight Internal（内部测试） |
| 使用范围 | 暂时仅项目维护者本人，1 人 |

来源：维护者于本次对话确认，已在昨晚通过 TestFlight 提交并安装使用包含“上下文窗口胶囊”的 Build 3；当前使用版本更新为1.13（3）。TestFlight Internal、仅本人使用的范围沿用此前确认。安装使用状态依据维护者反馈。Agent随后只读核对了本机1.13（3）归档：主应用和三个扩展编号一致、签名校验通过，归档元数据记录Build 3上传成功；未重新访问App Store Connect实时后台。当时源码的主应用与三个正式扩展均为1.13 / Build 3；本次发布后已同步为 Build 4。

下一次发布按[MinisX TestFlight 发布流程草案](minisx-testflight-release-draft.md)核对；Agent 已实测完成 Build 4 的签名归档与自动上传；维护者已反馈 Build 4 推送到手机；后台状态读取和组操作自动化仍未验证。

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
