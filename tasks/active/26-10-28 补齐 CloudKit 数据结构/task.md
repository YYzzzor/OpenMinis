# 26-10-28 补齐 CloudKit 数据结构

状态：active（用户确认于 2026-10-28）　｜　Spec：`docs/specs/ios-sync-and-conflict-resolution.md` 的“CloudKit 数据结构”一节（本任务新增 S1–S5，均为 `[拟议]`）　｜　验证：[verification.md](verification.md)（实施时创建）

## 目标

完成后：

- 旧 iPhone 上的 MinisX（TestFlight Build 14）能把数据上传到 iCloud，新 iPhone 上的 MinisX 能收到这些数据。范围见 A6 的表格。
- 仓库中有一份 CloudKit 数据结构文件 `src/ios/CloudKit/MinisX.ckdb`。它包含同步用到的全部记录类型、字段和索引。
- 以后新增或修改同步字段时，有一个测试会提醒更新这个文件。

不做：

- 不修改 App 的运行代码。数据结构部署到生产环境后，现有的 Build 14 就能同步，不需要新的 TestFlight 构建。
- 不处理旧版同步引擎（v1，`CloudSyncEngine`）用的记录类型，例如 `Session`、`Message`、`SyncDevice`。MinisX 的容器中从来没有 v1 数据，打开 v2 同步后 v1 暂停。
- 不实现“打开同步后自动上传历史数据”。这是 Spec 中的“待决定”项。本任务用现有的强制同步补传历史数据。
- 不为没有强制同步入口的类别（文件夹、MCP、环境变量）补传历史数据。见 A6 和“遗留”。

## 背景

- MinisX 使用自己的 iCloud 容器 `iCloud.com.yyzzzor.minisx`（`src/ios/Minis.entitlements:15`）。
- 用户在 2026-10-28 确认：这个容器的 Development 和 Production 环境中都没有任何记录类型。
- CloudKit 有两个环境：
  - Xcode 安装的 Debug 构建使用 Development 环境。Development 在第一次写入时自动创建记录类型和字段，但不自动创建索引。
  - TestFlight 和 App Store 构建使用 Production 环境。Production 不自动创建任何东西，只能从 Development 部署过来。
- 所以 TestFlight 构建上传的每一条记录都被服务器拒绝。App 把这种拒绝当作永久错误，从上传队列中丢弃（`src/ios/Agent/Sync/V2/ICloudSharedZoneTransport.swift:1794`、`SyncCore.swift:562-565`）。
- 原版 Minis 在同一个 iCloud 账号上能同步，所以账号和网络正常。

## 方案

### 路线：由测试从同步类型注册表生成数据结构

同步类型注册表（`SyncableTypeRegistry`）为每种记录类型保存全部字段的名字和类型（`AnySyncableTypeMetadata.fieldKinds`，`src/ios/Agent/Sync/V2/SyncableTypeRegistry.swift:27`）。`MinisTests` 中的一个测试做以下事情：

1. 调用 `SyncedTypesBootstrap.registerAll()`，读出全部 19 种记录类型和它们的字段。
2. 加上附件字段（Spec S2 中的 `SessionFileV2.asset` 和 `SkillV2.bundleAsset`）。附件字段不在注册表中，由 hydrator 另外加入。
3. 按 S2、S3 生成数据结构文本。类型和字段按名字排序，所以输出是确定的。
4. 与仓库中的 `MinisX.ckdb` 比较。不同时，把生成的文本写到临时文件，打印路径，测试失败。开发者把临时文件复制到仓库，就完成更新。

测试只在测试目标中，App 不包含它。

选择这条路线的理由：

- 数据结构与代码出自同一个来源，不会漏掉本地没有数据的记录类型。
- 文件存入仓库，可以审查，也可以重复导入。

未采用的方案：

- ✗ 用 Debug 构建上传数据，让 Development 自动创建记录类型，再在 Console 中手动加索引：本地没有数据的类别不会被创建；手动加索引容易遗漏。（用户 2026-10-28 选择了生成文件的方案）
- ✗ 只依据注册表的 `fieldKinds` 生成：会漏掉 `SessionFileV2` 和 `SkillV2` 的附件字段。部署后，带附件的会话文件和 Skill 在 Production 中全部保存失败。（方案审查 D1）

### 部署步骤

1. Agent 用 `xcrun cktool export-schema --environment development` 导出现在为空的 Development 数据结构，作为格式基线。生成的文本照这个格式写，包括文件开头、系统记录类型 `Users`、系统字段和权限语句。
2. Agent 写测试，生成 `MinisX.ckdb`，测试通过。
3. 用户在 CloudKit Console 中创建管理令牌（Management Token），在终端运行 `xcrun cktool save-token --type management` 保存一次。第 1 步也需要这个令牌，所以这一步排在最前面执行。
4. Agent 运行 `xcrun cktool import-schema`，把文件导入 Development。
5. Agent 再导出一次 Development 的数据结构，与 `MinisX.ckdb` 比较（A3）。
6. Agent 在两个模拟器上用团队签名的 Debug 构建验证同步（A4）。
7. Agent 第三次导出 Development 的数据结构，与 `MinisX.ckdb` 比较（A5）。Development 会自动补建缺失的字段，所以只有这一步能发现 A4 中“悄悄补上”的字段。
8. 用户在 CloudKit Console 中点“Deploy Schema Changes”，把 Development 的数据结构部署到 Production。
9. 用户把两部 iPhone 上的 MinisX 都彻底关闭再打开，然后在旧 iPhone 上做强制同步（A7）。

第 8 步不能撤销：部署到 Production 的记录类型和字段只能增加，不能删除，也不能改类型。所以第 5–7 步必须先通过。

第 9 步两部 iPhone 都要重启。原因：部署之前，App 每次查询都失败，并进入退避，最长 30 分钟才重试一次（`ICloudSharedZoneTransport.swift:898-906`、`SyncCore.swift:480-484`）。退避时间只保存在内存中，重启后清零。

本任务没有改变模块之间的协作或数据流，所以不画关系图和场景图。

## 验收（有证据才打勾，注明证据位置）

- [x] A1 满足 S1–S3：`MinisX.ckdb` 包含 19 种记录类型；抽查 `SessionV2`、`SessionFileV2`、`SkillV2`、`ProviderInstanceV3` 的字段类型和索引，符合 Spec S2、S3。（verification.md）
- [x] A2 满足 S4：测试通过；在本地临时把一个字段改为另一种 kind，测试失败并打印临时路径（反向测试，改动不提交）。（verification.md）
- [x] A3 `import-schema` 对 Development 成功；随后导出的 Development 数据结构与 `MinisX.ckdb` 相同，只有系统字段的格式差异。（命令输出，verification.md）
- [x] A4 在开发环境中验证同步。验证设备按用户决定改为新 iPhone 上 Xcode 安装的 Debug 构建，原因：模拟器的 iCloud 账号报 `Account Temporarily Unavailable`，不能使用 CloudKit。
  1. 打开同步后，3 个区域可用。
  2. 设备记录、对话、消息、Skill（带附件字段）和 Provider 记录上传成功，没有 `permanent push failure`。
  3. 17 种类型的查询每轮都成功。
  4. “另一台设备收到数据”改由 A7 验证。

  （verification.md 的“A4”）
- [x] A5 A4 之后，再导出 Development 的数据结构，与 `MinisX.ckdb` 相同，只有系统字段的格式差异。这证明 A4 期间没有自动补建任何字段。（verification.md）
- [ ] A6 用户在 Console 中部署到 Production 后，Production 中显示与 Development 相同的记录类型。（用户确认）
- [ ] A7 部署后，两部 iPhone 都重启 MinisX。旧 iPhone（Build 14）按下表做强制同步；新 iPhone 上出现对应数据：

  | 类别 | 旧 iPhone 上的操作 | 新 iPhone 上的预期 |
  | --- | --- | --- |
  | 对话（含消息、压缩标记、会话文件） | 首页选中全部对话，点工具栏的强制同步 | 出现全部对话 |
  | Skills、Provider、Memory、Soul | 在各自的管理页点强制同步 | 出现对应数据 |
  | 文件夹、MCP、环境变量 | 没有强制同步入口 | 历史数据不出现；之后的新修改会同步。记入“遗留” |

  （用户确认）
- [ ] A8 满足 S5：`docs/minisx-testflight-release-draft.md` 写入部署步骤；`git diff --check` 通过。（verification.md）
- [ ] A9 代码审查完成，意见逐条处置；资源结论由审查给出。（verification.md）

## 决定

- 用生成数据结构文件的方案。（用户，2026-10-28）
- 新建分支 `fix/cloudkit-schema` 并在分支上提交；模拟器的 iCloud 由用户登录。（用户，2026-10-28）
- A4 改用新 iPhone 上的 Debug 构建验证，“另一台设备收到数据”移到 A7。（用户，2026-10-28）
- 方案审查（reviewer 子代理，2026-10-28）的处置：全部采纳。

  | 意见 | 处置 |
  | --- | --- |
  | D1 附件字段不在注册表中，会被漏掉 | S2 增加附件字段表；删去不会生效的 `asset` kind 行 |
  | D2 Development 会自动补建字段，A4 掩盖遗漏 | 增加第 7 步和 A5：A4 之后再导出比较 |
  | D3 新 iPhone 退避最长 30 分钟 | 第 9 步和 A7 改为两部 iPhone 都重启 |
  | D4 对话的强制同步只补传对话 | A7 按类别列出操作；文件夹、MCP、环境变量写入“不做”和“遗留” |
  | D5 记录类型是 19 种；`zoneByRecordType` 是 private | 改为 19 种；S1 以 `registerAll()` 为准，不改 App 代码 |
  | Q1、Q2 `.ckdb` 的格式和记录名索引的写法未确认 | 增加第 1 步：先导出空的 Development 作为格式基线 |
  | Q3 模拟器的 ad-hoc 签名可能用不了 CloudKit | A4 改用团队签名，并先确认账号状态和区域创建 |
  | Q3 端口与等待时间 | A4 写明逐个读日志、至少等 3 分钟 |
  | Q4 只有部分类型的查询失败，整轮也会退避 | A4 第 7 步要求没有任何查询错误 |
  | Q5 没有记下 Build 14 的实际错误码 | 不采纳为验收项：Production 没有记录类型时写入必然失败，A6、A7 直接验证修复结果 |
  | Q6 测试的更新方式和输出顺序 | 写进“路线”第 3–4 步和 S4 |
  | 可简化：S2 只保留用到的 kind | 采纳 |
  | 可简化：生成器和测试合并 | 采纳 |
  | 可简化：省略 `validate-schema` | 采纳：`import-schema` 本身会校验 |
  | 可简化：记录名索引只加在 `SessionV2` | 不采纳：全部加上的代价很小，以后 Release 代码新增查询时不必再部署 |

## 执行边界

- 分支：从 `main` 新建 `fix/cloudkit-schema`（用户已同意，2026-10-28）。
- 提交：在本分支上按步骤提交（用户已同意，2026-10-28）。合入 `main` 和推送需要用户另行要求。
- 外部操作：
  - Agent 运行 `cktool export-schema` 和 `import-schema`。`import-schema` 修改 Development 环境的数据结构，只影响开发环境。
  - Production 部署由用户在 Console 中操作。Agent 不部署 Production。
- 设备：两个模拟器必须登录同一个 iCloud 账号（用户同意自己登录，2026-10-28）。A7 在用户的两部 iPhone 上完成。
- 不修改 `src/android` 及任何 Android 文件。

## 遗留（任务完成时核对）

- 文件夹、MCP、环境变量没有强制同步入口，历史数据不会补传。可以另建任务增加入口。
- 同步设置页的文案 “Toggle takes effect on next app launch.” 已经过时：开关现在立即生效（`SyncV2Bootstrap.setEnabled`）。

## 下一步

1. 用户在 CloudKit Console 中把 Development 部署到 Production（A6）。
2. Agent 导出 Production，与 `MinisX.ckdb` 比较。
3. 用户从 TestFlight 重新安装新 iPhone 上的 Build 14，两部 iPhone 都重启 MinisX，按 A7 的表做强制同步和检查。

已完成：A1–A5（见 verification.md）。
