# 26-09-27 WeatherKit 认证失败调查

状态：done（WeatherKit 原因已确认、修复复测通过；用户同意归档）
更新：2026-09-27，Asia/Shanghai

## 归档验收

- 用户明确要求：“任务可以归档了，准备提交吧”。本次归档的是仓库任务记录，当前对话保持打开。
- [x] 根因：Capabilities 已启用，但 App Services 中 WeatherKit 原未启用。
- [x] 修复与验收：用户授权并开启服务后，原 iPhone 18 Pro 模拟器、原 1.13（2）安装包单次查询返回 `ok=true` 和真实天气字段；未改产品代码、重装或使用备用天气源。
- [x] 发布交付：后续按用户要求完成 1.13（4）TestFlight Internal Only 上传，Apple 接收成功，用户确认已推送到手机；见[发布记录](<../../docs/minisx-release-status.md>)。
- 保留边界：Build 4 安装使用、真机 WeatherKit 行为及后台组操作自动化未独立验证；第三方库 8 项 dSYM 警告已记录。这些边界不改写为已验证。
- 纠偏记录：最初 Agent 把“创建任务”误解为新建 Codex 对话，未经明确要求另开了会话；用户纠正后已将误建对话归档，取回报告和证据并在原对话继续。本次归档不追认误建对话的授权。
- 验收已完成，无待执行修复；原始调查中的未知状态与授权限制作为历史证据保留。

## 恢复信息

- 分支：main；最近核验 HEAD：64a953277d32f48082b0f0c83009e36bc9d671e3。
- 开始时工作区干净，tasks/active/ 无任务。本轮只新增本记录，无产品代码或配置变更。
- 当前结果：用户确认 Capabilities 已启用、App Services 原未启用；用户明确授权修复并自行勾选服务后，原模拟器复测成功。
- 无待执行的修复。本次未修改产品代码、签名或安装包；真机未验证。用户要求留在原对话，不创建新的任务或对话。

## 后续确认与修复验收（2026-09-27 22:19）

- 用户在原对话提供截图确认 Capabilities 的 WeatherKit 已勾选，并反馈 App Services “这里没有勾选”。
- 解释两个开关及拟修复范围后，用户明确回复“可以开始修复”，随后回复“我已经勾选了”。此授权发生在最初只读调查之后，不追溯改写历史授权。
- 在同一 iPhone 18 Pro（479131C9-8187-44E7-8510-A499D7AC3034，iOS 27.0）、同一 MinisX 1.13 (2) 安装包、同一聊天 29CADA26-BA7F-49C5-98C9-678EF3E10C99 上复测。appInfo 的 bundlePath 与 buildDate 均与此前相同。
- DeepSeek-V4.1-Flash 只执行一次 `apple-weather current --lat 31.2304 --lng 121.4737 --compact`。禁止备用来源、管道、重试和写入记忆。
- 原始工具 JSON：`tool=apple-weather`、`action=current`、`ok=true`、`timestamp=2026-09-27T22:19:19+08:00`；上海天气“下雨”，temperature_c=25.100503921508789，apparent_temperature_c=27.271833419799805，humidity=0.9。确认真实天气数据返回，非仅模型声明成功。
- 结论：App Services 中 WeatherKit 未启用是本次认证失败的配置原因；启用后原环境立即恢复。无需代码变更、重装或重新签名。本次验证当前天气获取，未扩展到所有预报子命令或真机。
- 复测证据：`/Users/huyuanzhao/.codex/.chatgpt-projects/g-p-6aa8f27e863c8191be6cf501db847b1a/artifacts/weatherkit-validation-2026-09-27/retest-start.json` 与同目录 `retest-result.json`。
- 此记录只补充已有调查结果，没有新建任务或对话。以下原始调查章节保留当时的授权和未知状态，涉及“未授权/未确认”的表述为历史快照，以本节为最新结论。

## 任务确认与执行边界

- 确认状态：只读调查已明确授权；修复未授权。
- 确认稿版本：本会话创建输入，2026-09-27；来源会话 `01a0e24d-3ab2-7c70-b04c-f098d3b33e3f`。
- 用户依据：交接输入明确转述用户原话：“确认 weatherKit 的问题所在，向我汇报，等我搞清楚问题的具体原因后，再着手修复。”
- 真实使用目标：用户在普通对话问上海天气及是否带伞，希望理解内置 WeatherKit 为何失败，而不是仅看到备用来源完成了回答。
- 授权范围：现有源码、安装产物、现场日志、Apple 官方资料的只读调查及诊断记录。不修改产品代码、签名、Portal、系统/API 配置；不提交、推送或发布。
- 执行位置：本会话，现有 `/Users/huyuanzhao/Coding/Projects/OpenMinis`，不切分支、不建 worktree。
- 唯一设备：iPhone 18 Pro，`479131C9-8187-44E7-8510-A499D7AC3034`，iOS 27.0。已从该 UDID 下 device.plist 交叉核对名称、runtime；未使用同名 QA 设备。
- 首轮验证：复核既有真实会话及系统日志，再读取该设备安装文件。没有重新发送聊天、天气请求或使用临时配对凭据。
- 停止条件：本地证据无法区分 Portal 状态与服务端认证问题时停止；不靠重复调用、重装或扩大设备矩阵猜测原因。

## 目标与验收

- [x] 确认实际失败层次，并区分天气工具失败与模型备用回答。
- [x] 核实源码权限声明、安装包身份及模拟器权限载入证据。
- [x] 区分事实、假设及验证边界；提供最小后续检查和修复方向。
- [ ] 精确区分后台服务开通问题、模拟器认证问题或 Apple 服务端问题：缺少 Portal 双开关状态证据。
- 修复及修复验收不属于本轮目标。

## 诊断结论

**已定位到 WeatherKit 的 Apple 令牌认证环节被 HTTP 401 拒绝，尚不能把拒绝进一步归因于某一个配置项。**

现有链路：普通问题 → 模型执行 `apple-weather report/hourly` → 原生 WeatherKit → 本地权限检查通过 → Apple `/v3/token` 返回 401 → `invalidJWTResponse` → `WDSJWTAuthenticatorServiceListener.Errors Code=2` → 命令返回 `not_available`。最终回答使用 Open-Meteo，并尝试/使用 wttr.in 交叉核对，不能作为 WeatherKit 成功证据。

### 1. 真实场景及失败层次

- 2026-09-27 18:04，会话 `29CADA26-BA7F-49C5-98C9-678EF3E10C99`，问题“上海现在天气怎么样，今天出门需要带伞吗？”。
- `conversation.json` 的 `result.messages[3].toolCalls` 显示模型实际执行 `apple-weather report` 和 `apple-weather hourly`，均显式给出 `--lat 31.2304 --lng 121.4737`。
- `result.messages[4].toolCalls` 两次均返回 JSON `code=not_available`、WeatherDaemon 错误 2。外层 `success=true` 不是天气成功：命令尾部存在管道 `head`，应以工具内容及系统日志判断。
- 原始系统日志第 74 行确认调用者有正确 entitlement；第 77 行目标 bundleIdentifier 是 `com.yyzzzor.minisx`；第 81、83 行确认向 `https://weatherkit.apple.com/v3/token` 请求令牌后收到 HTTP 401；第 146、208 行记录 `invalidJWTResponse`；第 271–277 行传回 WeatherKit 错误。
- 系统日志服务器时间 `Sun, 27 Sep 2026 10:04:33 GMT` 与本地 18:04:33 对应，没有明显时钟错位证据。HTTP 响应说明请求已到达服务端，不能解释为单纯断网。
- 现有日志没有可把 401 唯一解释为 `NOT_ENABLED`、具体 Team 错误或某项服务未开通的明确原因字段；CDN 的 `40100` 也不是这种证明。

### 2. 源码和安装产物

- `src/ios/NativeOffloads/WeatherOffload.m` 的 `get_location_sync`：显式经纬度直接构造位置；本次未依赖定位权限弹窗。
- `src/ios/NativeOffloads/WeatherOffload.m:182` 附近：调用 Swift 桥接，并把 WeatherKit 错误转换为 `not_available`。
- `src/ios/NativeOffloads/WeatherOffloadBridge.swift:20–25`：调用 `WeatherService.shared.weather(for:)`；末尾 catch 原样把错误交回。此处使用 Apple 原生框架，不是项目自行生成 REST API JWT。
- `src/ios/Minis.entitlements` 包含 `com.apple.developer.weatherkit=true`。
- 当前主 App Debug/Release 配置均使用 `Minis.entitlements`，Team 为 `42486W5YRY`，Bundle ID 为 `com.yyzzzor.minisx`。
- 实际安装包：`/Users/huyuanzhao/Library/Developer/CoreSimulator/Devices/479131C9-8187-44E7-8510-A499D7AC3034/data/Containers/Bundle/Application/BC035067-48FB-4611-ADEC-18D0B2F96831/Minis.app`。
- Info.plist 核实版本 `1.13 (2)`、Bundle ID `com.yyzzzor.minisx`、SDK `iphonesimulator27.0`、Xcode build `27A266a`。交接现场 `debug.appInfo` buildDate 为 `2026-09-26T14:23:45Z`；本轮未重新调用 RPC 独立复核 buildDate。
- 主可执行文件 `Minis` 是 arm64 模拟器产物，ad-hoc 签名，codesign 的 TeamIdentifier 未设置、签名 entitlement 字典为空，无 embedded.mobileprovision。
- **直接解析该 Mach-O 文件的 `__TEXT,__entitlements` 段，发现 `application-identifier=42486W5YRY.com.yyzzzor.minisx` 和 `com.apple.developer.weatherkit=true`。** 这与运行日志认可 entitlement 相符，解释了为什么不能把 codesign 的空字典当作缺少权限的证据。
- 该段不包含 `com.apple.developer.team-identifier`；结合模拟器签名特点，单凭此缺失不能断言认证失败原因。也不能用这一段的声明代替 Apple 服务端对付费团队身份的认可。
- 主可执行文件 SHA256：`d2d638a6ec12dde745a4e462f210510152b40e88648493dc2a722b309cc0213a`。
- `Minis.debug.dylib` SHA256：`a9cd07dea075abf230c9e3550956562417dc341d76ad1c699a938c2c008cd06a`。
- 当前主 App 源码构建号已为 3，安装包仍为 2，因此不能声称运行的是当前 HEAD 的完整构建。已检查 Git 历史：从上述 buildDate 到当前 HEAD，两个 WeatherOffload 源文件和 Minis.entitlements 没有提交变更。标准 DerivedData 中所找到的 Debug 模拟器候选 dylib 与安装文件哈希不同，未建立安装产物到准确源码提交的完整可复现映射。

### 3. 假设与证据边界

| 假设 | 当前判断 |
| --- | --- |
| 模型没调用工具、参数错误、定位权限拒绝 | 本次证据不支持：明确执行工具、正确传入上海坐标，并到达令牌认证层 |
| 源码忘记声明 WeatherKit 权限 | 排除：源码及安装可执行文件均包含，运行日志也接受权限 |
| 安装包还在使用上游 Bundle ID | 排除：Info.plist、嵌入身份、令牌请求都指向 MinisX |
| Developer Portal 仅启用 Capabilities、漏开 App Services | 优先核查，但尚未观察 Portal，不能判定为事实 |
| 模拟器 ad-hoc 签名/认证环境异常 | 未排除；现有签名状态本身不是缺陷证明 |
| Apple 服务端授权同步或其他认证异常 | 未排除；401 没有给出足以细分的原因 |
| 旧安装产物与当前源码有差异 | 已确认构建号不同；天气代码近期未变，但没有完整构建溯源 |

**影响范围只在这一个 iOS 27.0 模拟器上有失败证据。没有进行真机 WeatherKit 验证，不能说 TestFlight 一定失败，也不能说问题仅限模拟器。**

## 官方依据及最小下一步

- [Apple：为 App ID 开启 WeatherKit](https://developer.apple.com/help/account/services/weatherkit/) 要求在 App Services 启用 WeatherKit，并提醒同时启用 App Capabilities。
- [Apple WWDC22：Meet WeatherKit](https://developer.apple.com/videos/play/wwdc2022/10003/) 区分原生 Swift 框架与 REST API：手动建立密钥、签发 JWT 是 REST 路线的额外步骤。本项目现有原生调用没有证据表明需要新增 `.p8` 密钥或自建令牌服务。
- [Apple DTS：模拟器与真机 entitlement 的差别](https://developer.apple.com/forums/thread/791736) 说明模拟器不执行与真机相同的 provisioning profile 授权校验，因此本地可声明权限不代表后台服务已获授权。

最先缺少的一项证据是：**Team `42486W5YRY` 下 `com.yyzzzor.minisx` 这个 App ID 的 WeatherKit 双开关实际状态。**

最小人工检查：登录 Apple Developer → Certificates, Identifiers & Profiles → Identifiers → 选择准确的 `com.yyzzzor.minisx` → 分别查看 Capabilities 和 App Services 中的 WeatherKit。只查看/反馈两个开关状态，先不要修改、保存或重新生成任何内容。无需提供密码、私钥或令牌。

供审阅的后续方案，未实施：

1. 若确有漏开项，用户另行授权后补开必要项；如签名权限需要更新，再由 Xcode 更新对应 profile 和构建。服务开关问题本身不要求先改天气查询代码。
2. 若两处均已开启，不能继续猜测开关问题。另行确认后，以一台指定真机的现有安装进行一次明确调用 WeatherKit 的代表场景，并检查工具实际 JSON 结果；若真机成功，则重点调查模拟器环境；若两端均失败，再检查实际真机签名/描述文件并携带脱敏日志向 Apple 查询服务端授权。
3. 验证成功必须看到 `apple-weather` 返回真实天气字段且没有认证错误，不能仅以模型最终有天气回答、shell 外层 success 或截图作为通过依据。

## Spec 阅读清单

- 必读：`docs/specs/ios-device-data-capabilities.md` 第 1、2、5、6 节（含范围与授权限制）；描述现有能力，不证明当前服务可用。
- Harness：`AGENTS.md`、`.agents/skills/plan-task/SKILL.md`、`docs/harness/record-formats.md`、`docs/harness/spec-context.md`。
- 未调用调试 RPC，所以未把已知过时的 debug-server 无认证 curl 示例用作执行依据。

## 证据与验证记录

- 会话原件：`/Users/huyuanzhao/.codex/.chatgpt-projects/g-p-6aa8f27e863c8191be6cf501db847b1a/artifacts/weatherkit-validation-2026-09-27/conversation.json`。
- 会话原件 SHA256：`6e555e69fcd3930cf693ffe5add28cda9e5046e27d17c863ec93e87306430b53`。
- 系统日志原件：`/tmp/minisx-weather-system.log`。包含认证签名，禁止原样粘贴或发送给外部审查；本记录只保存必要的脱敏事实。
- 系统日志原件 SHA256：`562eb6069dd43e1df19b9c9d8a06ec19fac2a972ce1a618a0c4912a1ee95aef5`。
- 本轮一次 simctl 只读查询因沙箱无法连接 CoreSimulatorService 而失败，随后直接读取精确 UDID 下的安装文件完成检查。没有重启或修改模拟器；该工具访问失败不是 WeatherKit 产品故障证据。
- 无新增天气/DeepSeek API 调用，无构建、安装、启动、重新签名、系统设置更改或 Portal 操作。
- 诊断没有产品修复，因此未发起 Pi 代码审查。
- 本记录新增后执行 `git diff --check` 及未跟踪文档的空白检查。
