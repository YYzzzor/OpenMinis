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
