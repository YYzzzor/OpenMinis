# 26-09-21 MinisX TestFlight 身份与签名准备
状态：done
更新：2026-09-25

## 完成与归档

完成依据：2026-09-25，用户明确确认“还有三个 active 的任务，这些任务都完成了”。据此更新完成状态并归档。本轮仅整理任务记录，未重新执行功能测试、签名或上传。
下一步：无；任务已关闭。以下计划、待审批事项和验证限制保留为当时的历史记录，不作为当前待办或重新执行依据。

## 历史恢复信息
分支：feat/minisx-branding
最近核验 HEAD：92eb0d6a3a541549c9527f01227cc55f6870cfba
远程：规划时 git ls-remote 核验为 68d7c7a42f1fcbc7b2938bcae190c7b882f7f1a9；本次图标提交尚未推送。
工作区：六个图标 PNG 已提交，业务代码未修改；本任务计划记录保持未跟踪，本地检查点被忽略。
下一步：图标资源替换与编译核验已完成；其余签名改造待确认命名空间和计划，并等待付费会员激活与 Team 可用；桌面启动页地址待确定。
待审批：Logo 已获用户验收，且已按本轮授权创建独立本地提交；其余身份与签名实现计划尚未确认。未授权推送或部署外部启动页。

## 目标与验收
按用户列出的 15 项要求，为个人定制的 MinisX 建立独立的 iOS 分发身份，使用用户自己的 Team 完成 Release Archive 与签名核验，准备 TestFlight，与官方 Minis 共存。不改业务功能、不重做 UI branding，保留 OpenMinis、GPLv3 与第三方 attribution。

- [ ] 四个生产 Target 的 Debug/Release Bundle ID、Team、版本与 entitlements 一致且各自正确。
- [ ] 主 App 与扩展共享新的 App Group；iCloud 使用独立容器；所有相关代码引用同步。
- [ ] 不再向系统注册官方的 minis、minis-mcp 或 com.openminis.app URL scheme；新链接指向 MinisX。
- [ ] Share、Widget、后台任务、File Provider、聊天附件、浏览器预览与 OAuth 调用链均核对；不改变原有路径与会话隔离规则。
- [ ] 全仓扫描旧标识并分类报告；iOS 生产代码与其构建/打包资源不保留旧命名空间。Android、第三方依赖与历史材料单列，不机械重命名。
- [ ] About 明示个人修改版身份，保留上游与许可证入口；权限描述与隐私清单按实际代码检查。
- [ ] 从实际 Archive 和导出产物读取 Bundle ID、schemes、版本、签名 Team、entitlements 与 profiles，逐个核验嵌入扩展和 frameworks。
- [ ] 真实签名、导出验证、上传/Apple 处理、设备运行各自记录结果，不能以模拟器或无签名构建替代通过。

## 上下文与决定
### 已确认事实
- 本地及远程指定分支均为 68d7c7a，origin 为 YYzzzor/OpenMinis。
- src/ios 中有 54 个文件匹配 com.openminis.；包含日志、钥匙串、迁移键、File Provider domain、App Group 和 CloudKit，而非只有工程文件。
- Minis：com.openminis.app，1.11 / 1；MinisShare、MinisFileProvider、AgentWidgetExtension：分别为 .ShareExtension、.FileProvider、.AgentWidget，1.0 / 2。Team 全为空，Automatic signing 已设置，各自 entitlement 路径已设置。
- 主 App entitlements 包含 HealthKit、health-records、HomeKit、CloudKit、ubiquity 容器、NFC TAG/PACE、WeatherKit、App Groups。三个扩展只声明共享 App Group；“一致”不表示给每个扩展复制全部权限。
- HealthKitOffload.m 未发现 clinical/FHIR/HKClinical 类型的实现；先建议移除未使用的 health-records，实施时完成全 iOS 复核。普通 HealthKit 保留。
- NFCOffload.m 有 NDEF 与 TAG 实现；PACE 搜索命中注释，实际需要与 Apple entitlement 定义和签名 profile 继续核对，不能仅凭名称删除 NFC 能力。
- ICloudBackupManager 使用 url(forUbiquityContainerIdentifier:) 文件备份，但 icloud-services 目前只有 CloudKit；需核对并补齐 iCloud Documents 服务配置。
- Info.plist 注册 minis、minis-mcp、com.openminis.app 三个 scheme。Claude 和 MCP 的当前默认 OAuth 实现是 localhost 回调；旧 custom scheme 的名称/注释不能当作当前登录行为，不擅改第三方要求的 redirect URI。
- WebAppAddToHomeSheet 使用 https://openminis.app/launch.html。已通过 HTTPS 实际读取该页面，脚本第 524 行硬编码 minis://open；无法仅靠修改 iOS 链接彻底解决桌面快捷方式共存。
- AboutView 已显示 MinisX，但仓库/问题链接仍指向上游，页面没有 GPL 或第三方 license 入口。根目录 LICENSE 与 THIRD_PARTY_LICENSES.md 存在，必须保留。
- 7 个 InfoPlist.strings 文件的权限文字已使用 MinisX；后续逐键核查基础 plist、本地化和构建生成的值。
- 本机 /Applications/Xcode.app 为 Xcode 27.0 (27A266a)。系统 xcode-select 指向 CommandLineTools，可在本任务构建时设置 DEVELOPER_DIR，不必修改全局设置。
- security find-identity -v -p codesigning（含沙箱外只读复核）返回 0 valid identities；两个常见 provisioning profile 目录均不存在。用户尚未提供付费 Team。
- 用户已提供 Downloads 中的四张新 Logo，均为 1024×1024、不含 alpha 的 PNG；wLetter-Letter.png 经目视确认是浅色版本。原图白色外边和预绘制圆角原样保留，不裁剪或重新生成。
- 用户报告已付款，但 Apple Developer App 仍显示注册审核申请中，Xcode 只有 Personal Team；付费 Team 尚不可用。

### 建议方案（待确认，非实际生成结果）
| 用途 | 建议值 |
| --- | --- |
| Minis | com.yyzzzor.minisx |
| MinisShare | com.yyzzzor.minisx.ShareExtension |
| MinisFileProvider | com.yyzzzor.minisx.FileProvider |
| AgentWidgetExtension | com.yyzzzor.minisx.AgentWidget |
| App Group | group.com.yyzzzor.minisx |
| iCloud Container | iCloud.com.yyzzzor.minisx |
| App URL scheme | minisx |
| 旧 App 身份回调 scheme 的替代 | com.yyzzzor.minisx |
| MCP custom URL scheme | minisx-mcp |
| 后台任务 | com.yyzzzor.minisx.liveactivity-refresh |
| version / build | 1.0.0 / 1，所有 App 与 Extension 同步 |
| Team | 用户确认的付费 Apple Developer Team，待提供 |

这些标识的可注册性仍须在用户 Developer Portal 验证。新身份意味着新的本地共享容器、钥匙串身份和云容器，不自动迁移官方数据。

### 链接与既有数据策略
- 所有新生成的 iOS 深链接、工具资源链接、Widget/Share 链接和提示词统一输出 minisx://。
- 保持 /var/minis 等内部目录、工具名与协议字段 minis_url 不变，不把业务协议重命名扩大成项目重构。
- 如导入历史会话需要解析 minis:// 资源，兼容限制在 App 内部资源解析，不能重新向系统注册旧 scheme；新增针对会话隔离和编码路径的必要回归验证。
- 桌面启动页需由用户控制的 HTTPS 页面输出 minisx://。先准备可审查的静态页面与客户端配置，再按用户指定的托管地址集成；发布须另获授权，不能替用户修改官方站点。此项未解决时不能声称所有 deep links 均兼容。

## Spec 阅读清单
必读：docs/specs/minis-url-scheme.md 全文；核对 URL 生成/解析、会话隔离、路径编码和工具结果合同。该文标为 Draft，未落地提案不纳入本次功能。
按需参考：docs/specs/ios-device-data-capabilities.md 第 1–6 节；以原生实现验证能力与权限用途，不能只凭已有权限文字认定功能存在。
执行规范：AGENTS.md、.agents/skills/plan-task/SKILL.md、docs/harness/record-formats.md。

## 实现计划
1. 确认标识和 Team；复核证书/私钥可用性、分发 profile、真机依赖与 Archive scheme。私钥和账号口令不写入仓库。
2. 同步主 App、三个扩展和 Tests 的标识、App Group、iCloud、后台任务及代码常量，统一 1.0.0 / 1；梳理签名设置继承，保证 Debug/Release 不漂移。
3. 同步 minisx://、minisx-mcp:// 和 App 身份 scheme，覆盖 Swift/Objective-C、内嵌 JS、rootfs 打包源、测试、脚本。核对 OAuth 默认 loopback 与用户自定义 redirect，不能盲改第三方回调。
4. 解决受控桌面启动页依赖；对设置链接、终端/闹钟、Share、Widget、附件中文编码、HTML 子资源和历史资源兼容执行针对性检查。
5. 逐项 entitlement 与真实调用对应：保留普通 HealthKit、HomeKit、WeatherKit、App Groups、CloudKit 和文件备份所需 iCloud Documents；复核 Health Records 和 NFC PACE，删除仅在确认无实现且不改变功能的声明。核对 CloudKit production schema 和所需查询索引。
6. 核对 PrivacyInfo.xcprivacy、全部 Info.plist/InfoPlist.strings、构建生成权限文字。检查清单被正确打包，不把无名称的隐私清单当作需要 branding 替换。按代码实际使用判断 required-reason API 声明。
7. About 增加明确的 MinisX 修改版说明、fork/上游链接、GPLv3 与第三方许可入口；保留原始 license 文本。若获得现有 Logo，则只替换/接入图标资源并核对备用图标，不新增视觉设计。
8. 全仓残留扫描、plist 检查、git diff --check、相关深链接回归与 Release Archive。适用时按 review-task 进行固定快照独立审查，不以审查代替签名与运行验收。
9. 逐包 codesign 验证，读取实际 signed entitlements 和 embedded.mobileprovision；导出 App Store Connect 分发包并记录验证。具备账号授权后再完成上传并核对 Apple 处理结果；若缺失前置条件，明确标为未完成，不伪造实际产物报告。

## Apple 侧资源清单
- 付费 Apple Developer Program Team；可用的 Apple Distribution 证书及其私钥，或 Xcode 支持的云托管分发签名。
- 4 个 Explicit App ID，绑定相同 Team；每个 bundle 对应正确的分发 provisioning profile（可由 Xcode 管理）。
- 1 个新 App Group，关联全部 4 个 App ID。
- 1 个新 iCloud Container，关联主 App，并启用 CloudKit / iCloud Documents；新容器的 schema、索引与 production 部署必须与现有同步代码匹配。
- 主 App 按最终代码启用 HealthKit、HomeKit、NFC Tag Reading、WeatherKit；WeatherKit 的 capability 和 app service 都需核对。Health Records 仅在确有实现时启用。
- 扩展仅授予真实需要的能力，目前源码 entitlement 为 App Groups。Push Notifications 是否必需按 CloudKit 配置和实际运行路径复核，不仅凭 remote-notification 后台模式推断已配置。
- App Store Connect 创建独立 MinisX App 记录，选择主 Bundle ID、设置 SKU 与必要测试信息。
- 给朋友分发建议使用外部 TestFlight 测试组；首次外部构建需要 TestFlight App Review。单个构建最多可测试 90 天。

## 进展与验证
已完成只读基线检查、远程 HEAD 核验、初步 entitlement/权限/调用链调查、Xcode 和签名身份检查，以及官方启动页 live 核验。
已按用户映射替换六个实际引用的 iOS 图标文件，逐文件比对与 Downloads 原图字节一致。未修改业务源码、执行 Archive、生成签名分发包、上传或触及 Apple Portal。以上建议表不能作为“最终实际生成”报告。

图标映射：
- woLetter-Light → AppIcon.appiconset/Icon-1024.png、AlternateIcons/AppIcon-Light.png。
- woLetter-Dark → AppIcon.appiconset/Icon-1024-Dark.png、AlternateIcons/AppIcon-Dark.png。
- wLetter-Letter → AlternateIcons/AppIcon-LegacyLight.png。
- wLetter-Dark → AlternateIcons/AppIcon-LegacyDark.png。

保留既有资源名和选择逻辑，主图标 Automatic 继续使用非 Legacy。未引用的 Icon-full* 设计源图不属于本次生效资源替换，不删除或修改。
图标验证结果：
- 六个目标文件与四张原图逐字节一致；输入均为 1024×1024 PNG，不含 alpha。
- 主图标资源目录与 iPhone/iPad 四种备用图标路径检查通过；Info.plist 和 project.pbxproj 的 plutil 检查通过；git diff --check 通过。
- Xcode 27 actool 使用 iphoneos / minimum deployment target 26.0 编译资产成功，退出码 0，生成 Assets.car、主图标 PNG 与 asset-info.plist；产物位于 /private/tmp/minisx-icon-validation-20260921。已目视核对编译后的 AppIcon60x60@2x.png 为新的无字浅色图标。
- 编译器仍报告 AppIcon 目录中六个原有 Icon-full* 文件未被 Contents.json 分配；这些文件本轮未修改，也未成为有效图标槽位。沙箱内出现 CoreSimulator 服务连接日志，但 iphoneos 资产编译成功并产生输出。
- 本次仅修改静态图片，不运行业务单元测试或完整 App 构建；尚未验证安装后桌面显示、深色切换与备用图标切换。

官方资料：
- https://developer.apple.com/help/account/identifiers/enable-app-capabilities/
- https://developer.apple.com/documentation/xcode/configuring-icloud-services
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.nfc.readersession.formats
- https://developer.apple.com/tutorials/develop-in-swift/test-your-beta-app
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/

## 阻塞与纠偏
- 计划和身份待用户确认；Team/账号能力不能从空签名配置推断。
- 无有效签名证书/profile，真实签名与 TestFlight 上传待前置条件满足。
- 官方桌面启动页硬编码旧 scheme；需要用户控制的托管地址才能在保留功能的同时完成该入口共存。
- Logo 替换与资源编译验证已完成；桌面显示与图标切换尚未做设备验证。

## 审查
本轮仅按明确映射替换六个静态 PNG，未改变代码或运行逻辑，不请求 Pi 行为变更审查。后续签名与深链接改造按实际改动适用条件安排。

## 模拟器展示验证（2026-09-21）
用户要求调出模拟器查看 Logo。已使用 scripts/build_ios_simulator.sh --skip-deps 完成 Debug 模拟器构建，日志 /private/tmp/minisx-icon-simulator-build.log 包含 BUILD SUCCEEDED。
- 设备：iPhone 18 Pro / iOS 27.0，UDID 479131C9-8187-44E7-8510-A499D7AC3034。
- 已安装 build/ios-simulator/Build/Products/Debug-iphonesimulator/Minis.app，并成功启动 com.openminis.app（本轮没有迁移 Bundle ID）。
- 安装包内四张 AlternateIcons 与已替换源文件逐字节一致。
- 启动截图已核验 MinisX 启动画面，随后截图显示聊天界面，表明已进入 App。
- 已发送 minis://settings/appearance；当前系统出现“在 MinisX 中打开？”确认，外观页面及手动图标切换仍待用户查看。
- 当前 Xcode 27 安装中没有旧位置 Simulator.app；已成功打开 /Applications/Xcode.app/Contents/Applications/DeviceHub.app。未修改全局 xcode-select。
- 未进行 TestFlight 签名或上传；此次为模拟器展示，不代表签名验收完成。

## 无字图标去白边版本（2026-09-21）
用户提供 /Users/huyuanzhao/Downloads/Icon-woLetter-Light.png 与 Icon-woLetter-Dark.png，并明确要求先替换 woLetter 两种版本。
- 原图为 1254×1254、不含透明通道的 PNG；已目视确认背景铺满画布，无上一版白色外边或预绘制圆角。
- 使用 sips 等比例缩小为 1024×1024，输出到 /private/tmp/minisx-icon-v2；Downloads 原文件未修改。
- 替换 AppIcon.appiconset/Icon-1024.png、Icon-1024-Dark.png 及 AlternateIcons/AppIcon-Light.png、AppIcon-Dark.png，共四个文件。Legacy 两张图哈希在操作前后保持一致。
- scripts/build_ios_simulator.sh --skip-deps 构建成功；日志 /private/tmp/minisx-icon-v2/simulator-build.log。新安装包中两张非 Legacy 备用图标与缩放后的输入逐字节一致。
- 已更新安装到 iPhone 18 Pro / iOS 27 模拟器，并重新启动 MinisX；本轮未调整签名身份、业务代码或 Legacy 图标。
- 上一节模拟器展示对应旧版图标，不能视作本次新版的桌面视觉验证；新版桌面效果由用户继续查看。

## 带字图标去白边版本（2026-09-21）
用户明确要求使用 /Users/huyuanzhao/Downloads/Icon-wLetter-Light.png 与 Icon-wLetter-Dark.png 替换之前的带字版本。
- 两张原图均为 1254×1254、不含透明通道的 PNG；目视确认背景铺满画布，无上一版白边和预绘制圆角。
- 使用 sips 等比例缩小至 1024×1024，临时结果位于 /private/tmp/minisx-letter-icon-v2；Downloads 原图未修改。
- 仅替换 src/ios/Resources/AlternateIcons/AppIcon-LegacyLight.png 和 AppIcon-LegacyDark.png。已比对哈希，四个非 Legacy 生效资源均保持不变。
- 模拟器增量构建成功，日志 /private/tmp/minisx-letter-icon-v2/simulator-build.log 包含 BUILD SUCCEEDED；两张 Legacy 图在产物中与缩放后的输入逐字节一致；git diff --check 通过。
- 已更新安装到 iPhone 18 Pro / iOS 27，并重新启动 MinisX。四种图标的新版资源均已装入模拟器，具体切换与桌面效果待用户查看。
- 未改变图标选择逻辑、业务功能或签名身份，未提交或推送。

## 用户验收与图标提交（2026-09-21）
用户明确表示“这几个 logo 都没问题，可以先提交一版”，据此记录图标子任务验收通过。
- 本地提交：92eb0d6a3a541549c9527f01227cc55f6870cfba。
- 提交标题：feat(ios): replace app icons with MinisX artwork。
- 提交仅含六个生效 PNG；不含本计划记录、签名改造或业务代码。
- 提交前确认暂存区为空，精确暂存六个路径，git diff --cached --check 通过；提交后核验实际变更文件清单。
- 用户视觉验收与此前模拟器构建/安装证据共同完成图标子任务。TestFlight 总任务仍待会员激活及后续计划确认，不归档。
- 未执行 push。
