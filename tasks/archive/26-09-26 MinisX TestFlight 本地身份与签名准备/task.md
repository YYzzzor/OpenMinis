# 26-09-26 MinisX TestFlight 本地身份与签名准备
状态：done
更新：2026-09-26

## 恢复信息
分支：feat/minisx-testflight
最近核验 HEAD：7e3e879（配置提交 d937f60；本地化提交 7e3e879）
工作区：源代码已本地提交；本轮补齐完成依据并归档任务记录
下一步：无。本任务已验收完成；未来功能与 TestFlight 更新另开任务。
待审批：无。用户明确要求归档与本地提交；未请求推送或合并。

## 任务确认与执行边界
确认状态：已确认
确认稿版本：2026-09-26 当前对话「第 8 步需要修改本地项目」方案
用户依据：用户原话「按这个方案修改」；此前明确确认 Bundle ID、Team ID，报告所有后台标识和 App Store Connect 应用记录已创建。
真实使用目标：用户仅通过 TestFlight 内部测试自行使用 MinisX；本轮完成上传前的本地身份配置与编译准备。
初始本地准备阶段授权范围（后续修订见下文）：创建 feat/minisx-testflight 分支，绑定主应用和三个扩展标识、团队、App Group、iCloud 与必要运行身份引用；检查配置并本地编译。保留功能、名称、图标、1.13/build 1、iOS 26.0。无需提交、推送、安装、上传；这些动作本轮禁止。
执行位置：当前对话；/Users/huyuanzhao/Coding/Projects/OpenMinis 原工作目录；从 main/61e1f57 新建分支，无新 worktree。
设备与数据：仅源代码及本地构建产物；不部署到模拟器或真机，不启动应用，不读写既有 App/云端数据或凭据。
首轮验证与停止条件：先检查四个生产 target 的 Debug/Release 标识、团队、entitlements 与代码引用，再用现有脚本 --skip-deps 编译。仅本地编译，不能替代 Release 签名归档或实际行为证据。若需削减功能、改权限/路线或上传，停止受影响部分并说明。

修订：在明确询问「是否授权本次将代码差异、相关源码和任务说明发送给 DeepSeek（deepseek-v4-pro），完成 Pi 独立审查？不包含凭据和本地忽略文件」后，用户回复「可以继续」。该授权仅适用于此后本次 Pi / DeepSeek 审查；001 自动审批拒绝的事实保留，不追认执行。

## 目标与验收
- [x] 主应用 com.yyzzzor.minisx；扩展为 .ShareExtension、.FileProvider、.AgentWidget；团队 42486W5YRY
- [x] App Group group.com.yyzzzor.minisx；iCloud iCloud.com.yyzzzor.minisx；与用户已注册资源一致
- [x] 配置静态检查通过；功能 entitlement 集合未削减；版本和 UI 保持原样
- [x] 本地模拟器编译通过；检查主应用与三个扩展的实际构建产物
- [x] 按 Harness 完成初始身份配置的独立审查与结论核实；后续 Xcode 元数据变化由主 Agent 在收尾时另行核对，未声称旧 Pi 快照覆盖这些变化。
- [x] 用户完成真机签名归档、上传 Apple，并通过 TestFlight 安装；用户确认已配置服务商并开始使用。

## 上下文与决定
- 用户确认后台主 App 已启用 App Groups、iCloud/CloudKit、HealthKit、HomeKit、NFC Tag Reading、WeatherKit capability/service；三个扩展关联同一个 App Group。App Store Connect 应用记录已创建。
- 所有生产 Debug/Release 配置绑定团队；测试 target 的现有 Bundle ID/空 Team 保留，测试包不随产品发布。
- 修改所有源码/entitlements 中硬编码 App Group、iCloud，File Provider domain、跨进程音频 Darwin 通知和后台任务标识；调试主 Bundle ID fallback 同步。
- 保留 minis://、minis-mcp://、旧 Claude callback scheme、minisbak UTI 和格式，以维持既有集成/备份兼容。本轮不解决与官方版 URL scheme 共存的既有歧义。
- 保留 Keychain service/legacy 迁移键、缓存文件名、日志 subsystem 等内部名称；它们不是 Apple 签名资源，避免全局替换破坏迁移和兼容。
- 原有 health-records 和 NFC PACE entitlement 未削减；随后已完成归档、上传和安装，未据此宣称健康/NFC 全部运行功能均已验证。
- 新 App 身份不自动迁入既有 App 数据；本轮不执行数据迁移。

## Spec 阅读清单
按需参考：docs/specs/ios-device-data-capabilities.md :: MinisX 手机数据与设备能力清单 > 6. 授权、缺失能力与容易混淆的范围；保留现有权限/能力，不将编译视为设备功能验证。
身份配置以实际项目与本任务确认值为准，本轮不修改 URL scheme、原生工具或挂载算法。

## 实现计划
- [x] 创建已确认分支；建立本记录
- [x] 定点修改身份和共享资源引用
- [x] 静态检查与主 Agent 差异自查
- [x] 本地编译、产物核查、记录警告
- [x] 独立审查与处理记录，给出本轮验收结果及下一步

## 初始本地准备阶段的进展与验证（历史记录）
- 21 个源文件，48 行定点替换；主 Agent 逐项检查 diff，无业务逻辑、UI 或权限集合增删。
- 静态解析 project.pbxproj：4 个生产 target × Debug/Release 共 8 个配置，Bundle ID/Team/自动签名/版本/iOS 下限均通过断言。
- 所有 XML plist/entitlements 可解析；原健康、NFC、家庭、天气等 entitlement 值保持原样；Info.plist 除后台任务名称外全部键值相同。
- src/ios 的 Swift/Objective-C/plist/entitlements 中不再有旧 App Group、iCloud 或 File Provider domain 引用；备份 UTI、URL scheme、Keychain 迁移键保留。
- git diff --check 通过。
- bash scripts/build_ios_simulator.sh --skip-deps 已退出 0，BUILD SUCCEEDED；只编译，未安装/启动。构建日志位于 /Users/huyuanzhao/Documents/Codex/2026-09-26/dh-qm/work/minisx-testflight-build.log。
- 编译警告按位置和消息去重共 155 项，涉及 API 弃用、空值注解、Swift 6 模式并发预警、图标等。四个产物检查通过，详见 evidence/validation.md；未做旧分支对照编译。
- Pi 审查仅对固定源代码/本任务记录进行只读审查，由项目 Harness 默认 deepseek/deepseek-v4-pro 执行；不会发送凭据或忽略文件；模型报告不代替主 Agent 验收。

## 审查
见 reviews/001-blocked.md；001 模型请求未执行。用户明确授权后已完成 002 审查，no_findings；原始报告见 reviews/002/，主 Agent 核实和验收见 reviews/002-resolution.md。

## 后续发布与使用验收
- 用户在 Xcode 创建 Apple Development 和 Apple Distribution 证书，并注册自己的 iPhone，解决自动开发签名缺少设备描述文件的问题。
- 用户提供 Organizer 截图确认归档：iOS App Archive、arm64、团队 Yuanzhao Hu、com.yyzzzor.minisx、版本 1.13 (1)。
- 用户随后提供截图：状态 Uploaded to Apple，Build Number 1，上传时间为当日 2:17 PM。按当前对话指导使用 TestFlight Internal Only。
- 用户明确反馈：「已经安装到我的 iPhone 上并配好了服务商, 已经能够开始使用了」。此为用户报告的真机使用验收，Agent 未另行操控手机或读取服务商凭据。
- 已向用户说明后续可递增 Build 编号、Archive、上传并通过 TestFlight 无线更新；每个构建版本有效期 90 天。
- 验收范围为个人 TestFlight 分发、安装和基本使用；不等同于 iCloud、HealthKit、NFC、File Provider 等所有功能的全面回归测试。

## 收尾授权与差异核对（2026-09-26）
- 用户直接要求：「当前的任务可以归档, 并将未提交的工作提交」。此授权适用于本次本地提交和任务记录归档；不包含推送远端、合并 main 或删除构建数据。
- 恢复核验实际分支 feat/minisx-testflight、HEAD 61e1f57。原检查点报告 status/files 漂移；调查确认是后续 Xcode 项目保存及字符串提取变化，没有通过覆盖代码消除漂移。
- Info.plist 的 25 个键转移到主 target 的 Debug/Release INFOPLIST_KEY_* 设置。逐键比较与原值一致，并只读核对本机 2026-09-26 的 Minis 2:11 PM xcarchive：归档 App 中这 25 个键全部保留且值一致。
- 项目文件还包含 Xcode 的重排、日历测试 target dependency 的 proxy 记录，以及单元素 HEADER_SEARCH_PATHS 从数组转为同值字符串；未改变生产功能代码。
- Localizable.xcstrings 有重排、注释和 extractionState 更新，新增 7 个空提取条目，移除 1 个仅含 en/new 的格式串条目；所有保留键的 localizations 内容逐项相同。
- git diff --check 通过；plist/项目/字符串 JSON 可解析。此前模拟器构建通过、本次用户完成真实归档上传与安装；本轮收尾没有修改应用源码或重新执行安装、上传、全量构建。
- 初始 Pi 002 报告继续作为原固定快照的审查证据。它不覆盖后续 Xcode 元数据/字符串目录变化；上述变化由主 Agent 语义比对及真实归档信息核对，未新增业务逻辑，因此不重复外部 Pi 请求。

## 提交与归档
- d937f60 build(ios): configure MinisX identity and TestFlight signing
- 7e3e879 chore(ios): refresh Xcode string catalog extraction
- 本记录及原始 reviews/、本地 evidence/ 和历史检查点随任务整体迁至 tasks/archive/，保持创建日期名称。原始审查材料和旧检查点保持原字节；归档后另行刷新当前检查点。
- evidence/ 与检查点仍遵循仓库忽略规则，仅留存本地；任务正文和原始审查附件纳入任务归档提交。
- 状态 done；无待审批和未完成的本次验收项目。既有 URL scheme 共存歧义、编译警告及未经全面测试的设备能力不在本次修复范围内。
