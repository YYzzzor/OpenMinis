---
description: iOS Agent 工具的系统授权、App 许可、操作确认、副作用分级、拒绝语义及已知间接调用缺口。
---

# iOS Tool Permissions and Side Effects

导航：[Spec 索引](index.md)。

状态：现行安全规范与当前实现并列记录。本文适用于 shell/offload、文件、设备数据、系统动作、配置和外部服务工具；具体数据类型能力另见 [iOS 设备数据能力](ios-device-data-capabilities.md)。

## 核心原则：三层授权不可互相替代

一次操作可能同时受三层控制：

| 层级 | 决定什么 | 典型结果 |
|---|---|---|
| iOS 系统授权 | App 能否访问系统保护的数据或能力 | 未决定、允许、拒绝、受限 |
| App 工具许可 | Agent 是否可以调用某类原生 offload | Bypass、Ask Once、Not Allowed |
| 操作级确认 | 某次高影响动作是否获得明确确认 | `--confirm`、专用确认界面或命令约定 |

通过其中一层不代表通过其他层：

- App 许可为 Bypass 时，HealthKit/Photos 等仍可能被 iOS 拒绝。
- iOS 已授权时，用户把某命令设为 Not Allowed，Agent 仍必须在执行前停止。
- Ask Once 已允许某命令时，删除、发送、控制设备等具体动作如果自身要求确认，仍必须确认。

## App 工具许可

### 当前级别

[OffloadPermissionManager.swift](../../src/ios/Agent/Offload/OffloadPermissionManager.swift) 定义：

- `Bypass`：App 层不弹许可提示，继续执行；
- `Ask Once`：本会话首次调用弹出许可，允许后只在内存中缓存到该会话；
- `Not Allowed`：执行前拒绝，并给出权限设置入口。

若调用没有有效 session id，当前实现使用 `offload-global` bucket。Ask Once 等待 30 秒后视为拒绝；会话 grant 可显式清除，App 重启也不应把内存 grant 当成持久授权。

当前 UserDefaults 未写值时，枚举 raw value `0` 解析为 Bypass。因此“默认 Bypass”是当前实现事实。若未来改变默认值，需要迁移既有用户设置，并明确新旧用户策略。

上述预检拒绝和会话 grant 只覆盖当前可识别命令；[命令匹配与已知缺口](#命令匹配与已知缺口)说明 shell 包装、脚本和子进程仍可能绕过 App 许可。独立读取级别说明不能据此判断所有间接调用已受 Not Allowed/Ask Once 保护。

### 当前可配置范围

设置中当前列出的隐私命令包括 HealthKit、Calendar、Reminders、Photos、Location、HomeKit 和 Clipboard。部分媒体/系统命令登记为不显示在设置中并默认直通。

这份登记表不是全部 native offload 能力清单，也不证明未登记命令没有副作用。新增 native offload 时必须决定：是否登记、默认级别、是否显示设置、系统权限和操作级确认；不得因漏登记而默认为安全。

## 命令匹配与已知缺口

当前 `shell_execute` 在执行前只检查 shell 字符串的第一个 token，并以 basename 匹配登记命令。因此以下直接写法可以匹配同一命令：

```text
apple-healthkit ...
/usr/local/bin/apple-healthkit ...
./apple-healthkit ...
```

已核实的 P0 限制：如果第一个 token 是其他程序，例如 `sh -c 'apple-healthkit ...'`、`env apple-healthkit ...`、脚本或子进程，App 层预检查看不到真正被 iSH kernel dispatch 的 offload 名称，可能绕过 Ask Once/Not Allowed。

因此：

- 不得宣称当前 App 工具许可覆盖所有 shell 间接调用；
- 在检查迁移到 native offload dispatch 点并验证前，任何依赖该许可保护敏感能力的设计都必须记录此缺口；
- 命令预览只展示第一条命令的参数，不能视为对完整 shell 副作用的可靠解释。

## Skill、Memory与MCP的开关例外

App工具许可针对当前可识别原生offload，不能自动推导为所有普通文件、Skill脚本或远端MCP工具逐项许可。Skill/MCP会话启停主要控制发现信息；Memory开关控制自动背景注入与专用读写工具，不构成一般文件访问隔离。它们均不能替代本规范的操作级确认、目标检查和安全重试要求。

已知MCP差异：[daemon](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/daemon.py)对TIMEOUT/STDIO_CRASH自动重试一次，作用于tools/call且不判断幂等；HTTP还有重连/401路径。外部工具若已提交副作用而响应丢失，可能被重放，不能声称当前所有工具都满足下文安全重试要求。会话关闭和全局关闭的warm连接检查同样存在缺口，详见[MCP执行门禁](ios-mcp-integrations.md#启停不是统一执行许可)和[超时重试](ios-mcp-integrations.md#超时重试与取消边界)。

Memory提示中GLOBAL“只读”与明确授权文件编辑、/memory“读取不受影响”与专用读取门禁的冲突，见[Memory规范](ios-memory-lifecycle.md#默认值会话开关与生效时点)。本轮修正文档不会授予额外访问、替代维护者决定或修复上述代码缺口。

## 副作用分级

开发和审查新工具时至少按以下维度判断，不能只看命令名称：

| 类别 | 示例 | 最低要求 |
|---|---|---|
| 读取个人数据 | 健康、照片、日历、位置、剪贴板 | 系统授权；适用时 App 许可；结果最小化 |
| 创建或修改数据 | 新增日历、提醒、文件、Provider 配置 | 参数和目标明确；失败可观察；避免隐式覆盖 |
| 删除或不可逆操作 | 删除记录、覆盖备份、清理文件 | 操作级确认或等价保护；说明不可恢复范围 |
| 外部设备/系统动作 | HomeKit、蓝牙、NFC、通知、打开 URL | 目标与动作可见；不可用/拒绝时不降级成别的动作 |
| 网络或远端副作用 | 上传、发送消息、调用外部服务 | 明确目的地、凭证和重试语义；防止重复提交 |
| 安全/配置变更 | 权限、认证、Provider、环境变量 | 记录生效范围和恢复路径；敏感值不入日志 |

规范不要求所有副作用都使用同一个弹窗。确认形式可以由对应工具契约定义，但必须与影响匹配并可验证。

## 拒绝、超时和错误语义

- App 层拒绝必须发生在已识别命令的原生副作用之前，工具结果标为失败并提供可执行的恢复入口。
- 用户拒绝、30 秒超时、系统权限拒绝、参数错误和系统 API 失败应可区分，不能统称“工具失败”。
- 失败不得自动改用权限更宽的替代命令，也不得通过 shell 包装重试以规避 Not Allowed。
- 自动重试只适用于被对应工具定义为幂等或可安全重试的错误。创建、发送、购买、控制设备等操作不得因为网络响应不确定而盲目重放。
- 日志不得包含完整健康数据、剪贴板内容、API key、环境变量值或安全令牌。

## 场景与验收

### 场景 A：Ask Once 的会话范围

前提：`apple-calendar` 为 Ask Once。

可观察验收：会话 A 首次直调出现提示，允许后 A 的后续直调不再提示；会话 B 首次仍提示；拒绝或超时不产生会话 grant；清除 A grant 后再次提示。

### 场景 B：Not Allowed 优先拒绝

前提：iOS 已允许照片访问，但 `apple-photos` 为 Not Allowed。

可观察验收：工具在 App 层返回拒绝，不触发照片查询；结果包含设置入口；Agent 不改用脚本包装重试。

### 场景 C：系统权限仍可拒绝

前提：App 工具许可为 Bypass，iOS 日历权限被拒绝。

可观察验收：调用返回系统授权相关错误，不伪报空数据或成功，不自动打开设置或反复弹窗。

### 场景 D：间接调用缺口

前提：敏感命令为 Not Allowed。

可观察验收目标：直接路径、绝对路径、`sh -c`、`env`、脚本和子进程最终都在 native dispatch 前执行同一许可判断。当前仅前三类中的直接/basename路径已由预检查覆盖，间接形式为已知未满足项，需代码修复后验证。

### 场景 E：有副作用命令的重复响应

前提：网络在提交后、收到响应前中断。

可观察验收：工具明确报告结果未知或使用幂等键查询，不无条件重复创建/发送；用户能区分“未执行”“执行失败”“可能已执行”。

## 维护要求与证据边界

新增或更改工具时，Spec/命令帮助至少说明系统权限、App 许可、操作级确认、副作用、幂等/重试和可观察失败。当前源码只证明预检查路径存在，未进行本轮设备授权和间接调用运行测试。
