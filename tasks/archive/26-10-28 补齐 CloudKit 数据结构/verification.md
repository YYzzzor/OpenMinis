# 验证记录：补齐 CloudKit 数据结构

## 部署步骤第 1 步：格式基线（2026-10-28）

- 管理令牌：用户在 CloudKit Console 的账号菜单 → Manage Tokens 中创建，用 `xcrun cktool save-token --type management` 保存。`xcrun cktool get-teams` 输出 `42486W5YRY: Yuanzhao Hu`。
- `xcrun cktool export-schema --environment development` 和 `--environment production` 的输出相同：只有 `DEFINE SCHEMA` 和系统记录类型 `Users`。这证实两个环境都没有自定义记录类型。
- 生成器按这个格式写：文件以 `DEFINE SCHEMA` 开头，包含 `Users`，每种类型带 6 个系统字段和权限语句；记录名的索引写作 `"___recordID" REFERENCE QUERYABLE`。

## A1 数据结构文件（2026-10-28）

- `src/ios/CloudKit/MinisX.ckdb` 有 20 个 `RECORD TYPE`：`Users` 和 `registerAll()` 注册的 19 种记录类型。
- 抽查：
  - `SessionFileV2`：有 `asset`（`ASSET`）、`asset_size`（`INT64`）、`asset_mime`（`STRING`）；`updatedAt` 为 `QUERYABLE SORTABLE`。
  - `SessionV2`：`createdAt` 为 `QUERYABLE SORTABLE`；`sessionId` 为 `QUERYABLE`；`memoryEnabled` 为 `INT64`（注册表用 `int` builder）。
  - 每种类型的 `___recordID` 为 `QUERYABLE`，并有 `syncSchemaVersion`、`syncMinimumCompatibleVersion`（`INT64`）。
- 注册表实际只用到 `string`、`int`、`date` 三种 kind。测试遇到其他 kind 时报错。

## A2 测试（2026-10-28）

- `MinisTests/CloudKitSchemaTests.testCommittedSchemaMatchesRegistry`：`Executed 1 test, with 0 failure`。
- 反向测试：把 `MinisX.ckdb` 中的一个 `"title" STRING` 改为 `INT64` 后运行，`Executed 1 test, with 1 failure`；文件已恢复（`cmp` 一致）。改的是文件而不是代码中的 kind：两者都走同一个比较，改文件不用重新编译 App。
- 仓库中没有文件时，测试失败并打印生成文件的路径（模拟器的 `tmp/MinisX.ckdb`）。

## A3 导入 Development（2026-10-28）

- `xcrun cktool import-schema --environment development --file src/ios/CloudKit/MinisX.ckdb` 成功。
- 导入后导出的 Development 数据结构，与仓库文件比较（去掉引号、合并空白后 `diff`）：相同。
- 第一次比较时，CloudKit 把 `Users` 按名字排序，而文件把它放在最前面。测试改为全部类型按名字排序后，重新生成文件，比较一致。

## A4 开发环境同步验证（2026-10-28）

验证方式按用户决定调整：模拟器的 iCloud 账号不能使用 CloudKit，改用新 iPhone（iPhone 18 Pro Max，UDID `00008160-0016290030434036`）上由 Xcode 安装的 Debug 构建。

模拟器失败的记录（iPhone 18 Pro，团队签名的 Debug 构建）：
- 创建区域时报 `Failed user key sync`；之后每次请求报 `Account Temporarily Unavailable`（代码 36），共 85 次；查询报 `Zone does not exist`。
- 这发生在数据结构之前，原因未确认（日志指向 iCloud 加密密钥同步）。

新 iPhone 的日志（`Library/Logs/minis-2026-10-28.log`，用 `xcrun devicectl device copy from` 复制）中有两次运行：

| 时间 | 构建 | 环境 | 结果 |
| --- | --- | --- | --- |
| 23:05 | TestFlight Build 14 | Production | `permanent push failure type=SyncDeviceV2 ... Cannot create new type SyncDeviceV2 in production schema`；`SkillV2` 同样失败。这直接证实了问题的原因 |
| 23:06:21 起 | Xcode 安装的 Debug 构建 | Development | 见下 |

Debug 构建的结果（23:06–23:23）：
- 上传：全部批次 `permanent=0`。

  | 批次 | 结果 |
  | --- | --- |
  | `SyncDeviceV2=1` | `ok=1` |
  | `SkillV2=1`（带附件字段 `bundleAsset`） | `ok=1` |
  | `MessageV2=2 ProviderConfigV2=1 SessionV2=1` | `ok=4` |
  | `ProviderConfigV2=1 ProviderInstanceV3=1 ProviderModelEntryV3=2` | `ok=4` |
  | `ProviderConfigV2=1 ProviderModelGroupV3=2` | `ok=3` |

- 查询：17 种类型的 `fetchRecentV2` 每轮都完成，输出 `fetchRecentV2 ok`，没有 `failed`。
- 两个 `crash-*.log` 都是 `SIGKILL`、前台、内存 20 MB，时间与 Xcode 安装重合，是安装时结束旧进程，与同步无关。

未验证：
- “另一台设备收到数据”：只有一台设备在开发环境中运行。改由 A7 在两部 iPhone 上验证。
- `SessionFileV2` 的附件上传：本次没有产生会话文件。它与 `SkillV2` 使用同样的 `ASSET` 字段类型，`SkillV2` 已上传成功。

## A5 验证后的数据结构比较（2026-10-28）

- A4 之后导出 Development 的数据结构，与 `MinisX.ckdb` 比较（去掉引号、合并空白后 `diff`）：相同。
- 所以 A4 期间 Development 没有自动补建任何字段，`MinisX.ckdb` 覆盖了实际写入的全部字段。

## A6 部署到 Production（2026-10-28）

- 用户在 CloudKit Console 中把 Development 的数据结构部署到 Production。
- Agent 用 `xcrun cktool export-schema --environment production` 导出：20 个 `RECORD TYPE`（`Users` 和 19 种记录类型）；与 `MinisX.ckdb` 比较（去掉引号、合并空白后 `diff`）：相同。

## A7 两部 iPhone 同步（2026-10-29）

- 用户在新 iPhone 上从 TestFlight 重新安装 Build 14，两部 iPhone 重启 MinisX，在旧 iPhone 上做强制同步。
- 用户确认：新 iPhone 上同步正常（“费了不少劲终于弄好了”）。
- 用户随后发现：同步过来的会话不显示“费用与余额”。核实结果：这是 Spec L1、D1 规定的行为（账本只在本机新建会话时登记，不随同步）。用户在新 iPhone 上新建对话后，这一部分正常显示。不是本任务的问题。

## A8 发布流程文档（2026-10-29）

- `docs/minisx-testflight-release-draft.md`：“发布前核对”表增加 “CloudKit 数据结构” 一行；增加 “CloudKit 数据结构部署” 一节，写明 7 个步骤和管理令牌的来源。
- `git diff --check` 通过。

## A9 代码审查（reviewer 子代理，2026-10-29）

范围：`git diff main..HEAD`。结论：现在的 `MinisX.ckdb` 与 App 的写入和查询一致；发布流程和测试有 3 个缺陷。

| 意见 | 处置 |
| --- | --- |
| D1 发布核对按“文件是否改动”判断，测试不一定被运行 | 采纳：核对改为每次发布都运行测试并导出 Production 比较；S5 的前提同步修改 |
| D2 测试中的 3 张表抄自 App 源码，脱节时测试发现不了 | 部分采纳：在 `ICloudSharedZoneTransport.swift` 的 `typesAndKeys`、`typesAndPredicate` 和 `ChatStoreSyncHydrators.swift` 的两处附件注入旁加中文提醒注释；S2 写明手工同步。不把常量移到 App 源码：超出“不改 App 代码”的范围，记入遗留 |
| D3 发布文档缺比较方法，`export-schema` 命令不完整 | 采纳：写出完整的导入、导出、测试命令和 `norm` 比较函数 |
| Q1 删除已部署字段后，S4 和 S5 不能同时成立 | 采纳为 Spec 的待决定项 |
| Q2 读不到文件时误报“不一致” | 采纳：改为 `try` 读取，读取失败单独报错 |
| 可简化：多余的排序；Spec 中会过时的注释 | 采纳 |

修改后重新运行 `CloudKitSchemaTests`：`Executed 1 test, with 0 failure`。`git diff --check` 通过。

资源结论（审查者给出）：不适用。App 运行代码没有改动（只加注释）；测试只在 `MinisTests` 中运行一次；`.ckdb` 不打包进 App。
