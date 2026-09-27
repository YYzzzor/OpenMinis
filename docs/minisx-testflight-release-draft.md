# MinisX TestFlight 发布流程草案

状态：草案；Agent 已完成 Build 4 的签名归档与上传，维护者反馈已推送到手机；安装使用与后台状态读取自动化尚未验证。更新：2026-09-27。

本流程用于将 MinisX 的已确认改动交付到维护者自己的 TestFlight Internal。当前仅维护者本人使用。先按本草案完成一次发布，再考虑提炼为项目级 `release-testflight` skill；目前不创建 skill、自动发布脚本或独立任务。

[发布状态](minisx-release-status.md)记录当前实际使用版本，本文件说明如何执行下一次发布。保存或提交本草案不代表已获准上传新构建。

## 1. 发布入口与范围

维护者明确说“把当前版本发布到我的 TestFlight 内部测试”后，Agent 核对当前对话已经确定的代码范围和目标，简要说明本次版本、候选 Build 与改动摘要，然后执行已获授权的步骤。范围明确时不为改号、归档、上传逐步重复提问；若“当前版本”可能包含其它正在进行的改动，先解决发布内容的歧义。

默认只面向现有的个人内部测试范围，不加入外部测试者或提交 App Store 审核。发布指令不自动包含 Git 提交、推送、合并或删除旧归档；这些动作按会话中已有的明确授权执行。登录、双重认证、钥匙串确认及账户协议等需要维护者处理时，说明具体阻塞，完成后续接当前步骤。

## 2. 发布前核对

| 检查 | 通过条件 |
| --- | --- |
| 代码范围 | 记录仓库、分支、HEAD、准备发布的改动与验证结果；不默认当前分支就是 main |
| 工作区 | 明确哪些未提交内容属于此次发布，保留其它工作，不为发布自动清理或还原 |
| 发布内容固定 | 记录最终构建输入；若允许发布未提交代码，同时保存纳入发布的差异、未跟踪文件清单和摘要，不能只记录 HEAD |
| Xcode | 核对实际版本、iOS SDK及当时 Apple 的上传要求；每条命令指定已核实的开发目录 |
| 签名 | 开发/分发身份和自动签名配置可用；主应用及扩展 Team、Bundle ID、App Group、iCloud 权益匹配 |
| Apple 认证 | 优先使用 Xcode 已登录账户；需要 API 密钥时单独配置，不在文档、仓库或日志中保存秘密值 |
| 发布证据位置 | 选择仓库外的独立归档/分发目录，保留日志与 dSYM（崩溃定位符号），不覆盖已有产物 |

当前参考值：工程 `src/ios/Minis.xcodeproj`，共享 Scheme `Minis`，Team `42486W5YRY`，主 Bundle ID `com.yyzzzor.minisx`。这些是本项目的已核对配置，不是对任意检出目录的假设。

本机曾发现 `xcode-select` 指向 Command Line Tools。可对单条命令设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，无需切换全局设置。若沙箱中签名身份不可见或校验返回信任错误，应按工具权限流程复核，不能直接认定证书失效，也不能为此更改证书信任设置。

## 3. 分配版本号和 Build

- 版本号对应 `MARKETING_VERSION`，例如 `1.13`；Build 对应 `CURRENT_PROJECT_VERSION`，例如 `3`。常规内部迭代默认只增加 Build；`1.13 → 1.14` 等版本变更按维护者明确决定执行。
- 综合源码、发布记录和 App Store Connect 中已接收/正在处理的构建，选择尚未使用且高于已知构建的编号。当前最新已上传构建为 `1.13（4）`，`1.13（5）`只是下一候选，不能据本文件永久写死。
- 如果无法核实远端编号，保留候选状态并说明缺口；本地加一不等于编号已被远端接受。
- 同步主应用、ShareExtension、FileProvider、AgentWidget 的 Debug/Release 版本和 Build。不要批量修改无关测试目标。
- 用 Xcode 解析出的构建设置复核，再在实际 Archive 中检查四个产品的 `CFBundleShortVersionString` 和 `CFBundleVersion`。
- 上传配置明确设置 `manageAppVersionAndBuildNumber=false`，由项目源码管理编号，避免 Xcode 上传时另行加号而源码和记录仍停留旧值。

修改编号后重新固定本次构建输入。如果构建期间相关源码变化，不能把产物归到原先的代码状态；应重新核对并构建。

## 4. Archive 与包检查

使用 Release、`generic/platform=iOS` 创建有签名的真机归档，不使用模拟器产物，也不将 `CODE_SIGNING_ALLOWED=NO` 的验证包视为可上传包。下面是命令形状，路径必须替换为本次实际值；草案编写阶段不执行。

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project '<仓库>/src/ios/Minis.xcodeproj' \
  -scheme Minis -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath '<本次独立产物目录>/MinisX.xcarchive' \
  -allowProvisioningUpdates archive
```

`-allowProvisioningUpdates`会允许 Xcode 与 Apple 通信并按自动签名需要更新签名资源，应在实际获准发布时使用；只读能力核验不需要执行此命令。命令行签名可使用 Xcode 账户或 App Store Connect API 密钥，参考 [Apple 命令行签名说明](https://developer.apple.com/videos/play/wwdc2021/10204/)。

检查退出状态和 `ARCHIVE SUCCEEDED`，再核对实际产物：

1. 主应用与三个扩展均存在，版本、Build、Bundle ID 和 Team 正确。
2. 签名验证通过，所需权益及扩展关系正确；Archive 的开发签名与上传时重新分发签名是不同阶段，不能只凭证书名称判定上传已准备完成。
3. 主图标和备用图标打包完整，原有图标问题的检查范围未退化。
4. 保存构建日志、归档位置和构建输入标识；检查不通过就停在此阶段，不上传。

## 5. 上传到 TestFlight Internal

首次执行时根据本机 `xcodebuild -help` 与账户状况核实导出参数。当前 Xcode 27 支持以下方案：

| ExportOptions.plist 字段 | 拟用值 | 目的 |
| --- | --- | --- |
| `method` | `app-store-connect` | 使用 App Store Connect 上传通道 |
| `destination` | `upload` | 上传至 Apple |
| `teamID` | `42486W5YRY` | 使用 MinisX 的开发者 Team |
| `signingStyle` | `automatic` | 按自动签名配置进行分发签名 |
| `testFlightInternalTestingOnly` | `true` | 限制为内部 TestFlight，不能用于外部测试或 App Store 发布 |
| `manageAppVersionAndBuildNumber` | `false` | 保持上传编号与已核对源码一致 |

示意命令：

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -exportArchive -archivePath '<本次独立产物目录>/MinisX.xcarchive' \
  -exportPath '<本次独立产物目录>/distribution' \
  -exportOptionsPlist '<本次独立产物目录>/ExportOptions.plist' \
  -allowProvisioningUpdates
```

读取命令退出状态、分发日志和上传回执，确认实际接收的应用、版本和 Build。保留错误与警告，不因命令结束便记录为“可安装”。Apple 接收后还需处理构建，见 [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)。

## 6. Apple 处理与内部测试分发

先检查对应 Build 在 App Store Connect 的处理结果，再核对它是否已经可供维护者所属的内部测试组使用。`testFlightInternalTestingOnly=true`限定分发范围，但不能代替组关联、处理状态和必要声明的检查。

已有内部组若开启自动分发，核实它已收到该构建；否则将本次构建加入维护者已有的内部组。保留当前一人使用范围，不因为发布而新增测试者或扩大组成员。首次由 Agent 操作组关联的具体入口和权限仍待验证，见 [Apple 内部测试说明](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)。

若出现出口合规问题，核对已有应用声明和事实；需要维护者判断的声明不代答。等待处理时设定本次检查的截止时间，超时记录“处理中”及下一检查动作，不将超时当成上传失败而重新提交。没有持续监控请求时，不另设后台轮询任务。

## 7. 失败、中断和重试

| 情况 | 处理方式 |
| --- | --- |
| 本地构建失败 | 保留日志，定位原因；未上传前不因重试自动加号 |
| 登录失效、需要双重认证或钥匙串授权 | 停在认证环节，由维护者完成必要交互；不输出密码、令牌或私钥 |
| 编号重复 | 先核实远端已有构建及其状态；确需新构建时同步增加编号并重新归档，不只修改已签名包 |
| 上传中断、结果不明确 | 先查回执和远端同一 Build；已接收则进入处理检查，不盲目重传 |
| 明确未被接收且存在可恢复错误 | 根据具体原因修正，保留本次尝试记录，再决定是否重试同一产物 |
| Apple 拒绝或处理失败 | 保存具体报错，修复影响范围；需要新的上传编号时重新归档 |
| 处理中或暂未分发 | 继续核对原 Build，不为等待本身生成新 Build |

不循环自动重传、不连续试号，也不自动切换 Team、Bundle ID 或分发范围。已被 Apple 接收的 Build 按已使用处理；本地还原版本字段不会撤销远端上传。

## 8. 发布记录与完成判断

每次实际发布在 [发布状态](minisx-release-status.md) 中记录摘要。已有开发任务时引用它，不为例行发布强制新建任务；详细日志、归档和符号文件留在本次产物目录，仓库记录可定位的位置。

| 状态 | 所需证据 |
| --- | --- |
| 构建成功 | 实际归档成功、包检查通过，记录源码状态与产物位置 |
| 上传成功 | 对应应用及 Build 的上传回执或可靠分发记录 |
| 内部测试可安装 | Apple 处理完成，维护者所属内部组可获得该 Build |
| 维护者已安装 | 维护者确认手机通过 TestFlight 更新并实际使用 |

“当前使用版本”只在维护者安装确认后更新；构建号源码变化、上传成功或组内可用都不能代替手机安装确认。上传或处理失败时保留最后已用版本，另记本次候选构建的状态。

建议每次保留以下摘要，字段未知时写“未核实”，不补造：

```text
版本 / Build：
分支 / HEAD / 实际构建输入：
改动摘要与已有验证：
Xcode / SDK / Team：
Archive / 分发日志位置：
上传时间 / 回执 / 警告：
Apple 处理结果 / 内部组可用状态：
维护者安装确认：
失败尝试及下一步（若有）：
```

## 9. 当前验证边界与转为 skill 的条件

发布前基线（历史）：2026-09-27 的只读核验已确认：本机 Xcode 27.0（27A266a）可临时指定路径调用；开发和分发身份有效；真实 `1.13（3）` Archive 中主应用与三个扩展编号一致，签名校验通过；归档内保存了 Build 3 的上传成功元数据。维护者另确认已通过 TestFlight 使用胶囊版本。

上述发布前基线当时仅证明现有环境与既往发布记录。随后 Build 4 实测已验证 Xcode 账户复用、新 Archive、分发签名和自动上传，并收到用户确认推送到手机的反馈，见第 10 节；Apple 状态读取及内部组操作自动化仍未验证。

下一次有实际更新且维护者授权发布时，按此草案执行，记录真实命令、遇到的交互和恢复路径。走通后将稳定步骤提炼为项目级 skill，参数与配置留在项目文件，账户秘密保留在安全存储中。未走通前维持草案状态，不宣称已具备无人值守发布能力。


## 10. 首次 Agent 实际执行记录（2026-09-27）

本次按维护者明确授权，在原对话和原工作目录完成 1.13（4）签名归档与 TestFlight Internal Only 上传，未创建独立任务、skill 或自动发布脚本。详细回执、产物路径和警告见[发布状态](minisx-release-status.md)。

已实际验证：Xcode 27 的 `-allowProvisioningUpdates` 可复用本机已登录账户；四个正式产品编号同步、签名/权限/图标/主产品 dSYM 检查通过；`app-store-connect` + `destination=upload` + `testFlightInternalTestingOnly=true` + `manageAppVersionAndBuildNumber=false` 的上传完成，Apple 接收 Build 4 并开始处理，无需新增 API 密钥。本次没有账户交互或上传重试。

实际边界：上传产生 8 项第三方框架 dSYM 缺失警告，上传成功不等于无警告。维护者随后反馈“已经推送到我的手机上了”，记录为 Build 4 已到达手机；尚未明确确认安装使用，Agent 也未独立读取后台处理状态或操作内部组。因此继续保留草案状态，不把用户反馈扩展为无人值守分发或完整真机验收。
