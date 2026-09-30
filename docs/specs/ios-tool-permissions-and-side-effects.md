---
description: iOS Agent 工具的系统授权、App 许可、操作确认、副作用分级、拒绝语义及已知间接调用缺口。
---

# iOS Tool Permissions and Side Effects

导航：[Spec 索引](index.md)。

范围：shell / offload、文件、设备数据、系统动作、配置和外部服务工具的授权与副作用规则。具体数据类型能力见 [iOS 设备数据能力](ios-device-data-capabilities.md)。

## 三层授权

| 层级 | 决定什么 | 取值 |
| --- | --- | --- |
| iOS 系统授权 | App 能否访问系统保护的数据或能力 | 未决定、允许、拒绝、受限 |
| App 工具许可 | Agent 能否调用某个原生 offload 命令 | Bypass、Ask Once、Not Allowed |
| 操作级确认 | 某次高影响动作是否得到明确确认 | `--confirm`、专用确认界面或命令约定 |

- **A1** 三层相互独立，任何一层都不能代替另一层：App 许可为 Bypass 时，iOS 仍可拒绝；iOS 已授权时，Not Allowed 仍在执行前拒绝；Ask Once 已允许某命令时，自身要求确认的删除、发送、控制设备等动作仍需确认。

## App 工具许可

- **P1** 三个级别（[OffloadPermissionManager](../../src/ios/Agent/Offload/OffloadPermissionManager.swift)）：
  - `Bypass`：App 层不提示，直接执行；
  - `Ask Once`：每个会话首次调用时提示，允许后在内存中记住到该会话结束；
  - `Not Allowed`：执行前拒绝，并返回权限设置入口 `minis://settings/permissions`。
- **P2** 未设置过的命令为 Bypass（UserDefaults 未写值时 raw value 0）。改变默认值时必须迁移已有用户设置，并写明新旧用户的策略。
- **P3** 没有有效 session id 的调用使用 `offload-global` 会话桶。
- **P4** Ask Once 的提示 30 秒无响应视为拒绝；拒绝或超时不产生会话授权。会话授权只存在内存中，可以显式清除，App 重启后不保留。
- **P5** 设置页列出的隐私命令：HealthKit、Calendar、Reminders、Photos、Location、HomeKit、Clipboard。其余登记的媒体与系统命令（speak、speech、player、media、device、notification、alarm、open、maps、weather、nlp、vision）不在设置中显示，按 P2 默认直通。
- **P6** 新增原生 offload 时必须逐项决定：是否登记、默认级别、是否显示在设置中、所需系统权限、是否需要操作级确认。未登记不等于安全。

## 命令匹配

- **M1** `shell_execute` 在执行前取 shell 字符串的第一个 token，按 basename 与登记命令匹配。因此 `apple-healthkit …`、`/usr/local/bin/apple-healthkit …`、`./apple-healthkit …` 都受同一许可约束。
- **M2** 许可判断应覆盖所有最终到达 native dispatch 的调用，包括 `sh -c '…'`、`env …`、脚本和子进程。见“待决定”中的缺口。
- **M3** 许可提示中的命令预览只展示第一条命令及其参数，不作为完整 shell 副作用的说明。

## Skill、Memory 与 MCP

- **X1** App 工具许可只针对可识别的原生 offload，不覆盖普通文件、Skill 脚本或远端 MCP 工具。
- **X2** Skill / MCP 的会话启停主要控制发现信息；Memory 开关控制自动背景注入与专用读写工具，不隔离一般文件访问。它们都不能代替操作级确认、目标检查和安全重试要求（F4）。
- **X3** MCP 的超时重试与启停门禁见 [MCP 集成](ios-mcp-integrations.md)；Memory 各开关的边界见 [Memory 生命周期](ios-memory-lifecycle.md)。

## 副作用分级

新工具按以下维度判断最低要求，而不是只看命令名称：

| 类别 | 示例 | 最低要求 |
| --- | --- | --- |
| 读取个人数据 | 健康、照片、日历、位置、剪贴板 | 系统授权；适用时 App 许可；结果最小化 |
| 创建或修改数据 | 日历、提醒、文件、Provider 配置 | 参数和目标明确；失败可观察；不隐式覆盖 |
| 删除或不可逆操作 | 删除记录、覆盖备份、清理文件 | 操作级确认或等价保护；说明不可恢复的范围 |
| 外部设备 / 系统动作 | HomeKit、蓝牙、NFC、通知、打开 URL | 目标与动作可见；不可用或被拒绝时不改做别的动作 |
| 网络或远端副作用 | 上传、发送消息、调用外部服务 | 明确目的地、凭证和重试语义；防止重复提交 |
| 安全 / 配置变更 | 权限、认证、Provider、环境变量 | 写明生效范围和恢复路径；敏感值不进日志 |

- **S1** 确认形式由各工具的契约定义，不要求统一弹窗，但必须与影响相称、可验证。

## 失败语义

- **F1** App 层拒绝发生在已识别命令产生原生副作用之前；结果标为失败，并附可执行的恢复入口。
- **F2** 用户拒绝、30 秒超时、系统权限拒绝、参数错误和系统 API 失败各自可区分，不统称“工具失败”。
- **F3** 失败后不自动改用权限更宽的命令，也不通过 shell 包装重试来绕过 Not Allowed。
- **F4** 只有对应工具定义为幂等或可安全重试的错误才自动重试。创建、发送、购买、控制设备等操作在响应不确定时不盲目重放，而是报告“结果未知”或用幂等键查询。
- **F5** 日志不包含完整健康数据、剪贴板内容、API key、环境变量值或安全令牌。

## 待决定

- [待决定] M2 的缺口：当前预检只看第一个 token，`sh -c`、`env`、脚本、子进程可以绕过 Ask Once / Not Allowed。修复需要把检查移到 native dispatch 处；修复前，任何依赖 App 许可保护敏感能力的设计都要写明此缺口。
- [待决定] F2 的缺口：Ask Once 超时与用户拒绝目前返回同一条 “declined” 提示，只有竞态时才返回 “timed out”。
- [待决定] F4 的缺口：MCP daemon 对 `TIMEOUT` / `STDIO_CRASH` 的 `tools/call` 自动重试一次，不判断幂等；已提交但丢失响应的外部副作用可能被重放。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| `apple-calendar` 为 Ask Once：会话 A 首次调用、再次调用；会话 B 首次调用；拒绝或超时；清除 A 的授权 | A 首次提示、之后不提示；B 首次提示；拒绝或超时不留授权；清除后再次提示（P1、P4） |
| iOS 已允许照片访问，`apple-photos` 为 Not Allowed | App 层拒绝，不触发照片查询；结果含设置入口；不改用脚本包装重试（A1、P1、F3） |
| App 许可为 Bypass，iOS 日历权限被拒绝 | 返回系统授权错误，不伪报空数据或成功；可以提供设置入口，但不自动打开设置，也不反复弹窗（A1、F2） |
| 敏感命令为 Not Allowed，分别用直接路径、绝对路径、`./`、`sh -c`、`env`、脚本调用 | 全部在 native dispatch 前被拒绝（M1、M2；后三种目前未满足） |
| 有副作用的命令提交后、收到响应前网络中断 | 报告“结果未知”或用幂等键查询，不无条件重复创建或发送（F4） |

## 代码入口

- 许可与匹配：[OffloadPermissionManager](../../src/ios/Agent/Offload/OffloadPermissionManager.swift)；测试 [OffloadPermissionBypassTests](../../src/ios/MinisTests/OffloadPermissionBypassTests.swift)
- MCP 重试：[daemon.py](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/daemon.py)
- 新增或修改工具时，Spec 或命令帮助至少说明：系统权限、App 许可、操作级确认、副作用、幂等与重试、可观察的失败。
