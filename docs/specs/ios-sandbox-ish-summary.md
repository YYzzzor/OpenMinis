---
description: iOS 内嵌 iSH shell 的运行、并发、文件作用域、超时取消、原生 offload 与安全边界。
---

# iOS iSH Runtime and Isolation Contract

导航：[Spec 索引](index.md)。

范围：Agent 的 shell 执行、会话文件作用域、原生 offload，以及取消与超时。不是 iSH 内部库的架构清单。

## 执行前提

- **E1** shell 执行要求 `ISHKernel` 已启动，否则返回 `kernelNotBooted`。
- **E2** 每次执行都带非空的 session id；文件作用域和停止范围以它为边界。
- **E3** 每次执行创建独立的 `/bin/sh` 进程及 stdin / stdout / stderr 管道，工作目录从 `/root` 开始。
- **E4** 用户环境变量由 `EnvVarStore` 注入。它们的值属于凭证或个人配置，不写入普通日志或错误回显。

## 并发

- **C1** 不同会话、同一会话内的多个 `shell_execute` 都可以并发执行，互不等待。
- **C2** 每次调用有独立的 shell、PID、管道和会话 `fs_context`，没有共享的交互式 shell 状态：一个命令里的 `cd`、局部环境变量或 shell 变量不影响下一个命令。
- **C3** 完成顺序不一定等于提交顺序。并发写同一文件、端口、数据库或外部资源时，由调用方避免竞态或显式串行化。
- **C4** 并发数、输出规模、图片数量和上下文 offload 遵守 [资源开销规范](resource-efficiency.md)，不因底层支持并发就无界展开。

## 文件作用域

- **F1** `MinisFsRouter` 为每个 session id 分配稳定的 `fs_context`，把四个目录路由到该会话自己的目录：

| Guest 路径 | Host 位置 |
| --- | --- |
| `/var/minis/attachments` | `<minis-base>/<session-id>/attachments` |
| `/var/minis/offloads` | `<minis-base>/<session-id>/offloads` |
| `/var/minis/workspace` | `<minis-base>/<session-id>/workspace` |
| `/var/minis/browser` | `<minis-base>/<session-id>/browser` |

- **F2** fork 出的子进程继承同一 context；并发会话之间不会因“最后挂载的会话”互相覆盖这四个目录。
- **F3** `/var/minis/memory`、`/var/minis/skills`、`/var/minis/shared` 是全局挂载，跨会话可见。全局可见不等于可以任意写入：文件工具和 offload 仍要做路径、只读、授权和操作级检查。
- **F4** 用户外部目录位于 `/var/minis/mounts`，依赖 security-scoped bookmark / File Provider 权限，可能只读或暂时不可达。不可达时不把路径解析到内部目录。

## 超时与停止

- **T1** 未指定时默认超时 300 秒。
- **T2** 超时终止整个进程组（不只是根 PID），并清理该次执行的 context；结果为退出码 `-1` 和明确的超时文本。超时后后续命令仍能正常执行。
- **T3** 用户停止某会话时，终止该会话记录的所有在运行 PID；紧急全局停止可以终止所有会话的命令。
- **T4** 存在不经过 actor 的 PID 快照停止路径，保证 actor 被阻塞时仍能发出 kill；它返回实际发出停止信号的 PID 数。
- **T5** 停止和超时只保证发出了终止与清理动作，不回滚外部副作用：已写的文件、已提交的系统事件、已发出的网络请求可能保留。
- **T6** 超长输出按资源开销规范截断或转存，保留对定位问题有用的 stdout / stderr 内容。
- **T7** MCP CLI 通过独立 daemon 复用连接，其生命周期与单次 shell 的 PID 无关；停止 shell 不代表 daemon、长期子进程和远端动作一并取消。见 [MCP 集成](ios-mcp-integrations.md)。

## 原生 offload

- **O1** iSH kernel 在 `execve` 阶段按注册名拦截部分命令，交给 iOS 原生 handler 执行，再通过进程 I/O 返回结果。注册清单以 [ISHKernel.m](../../src/ios/iSH/ISHKernel.m) 的启动代码为准；Spec 不维护固定的 handler 数量，增删注册项时更新对应能力 Spec 和命令帮助。
- **O2** offload 仍是 shell 命令的一部分，遵守 iOS 系统授权、App 工具许可和操作级确认，见 [工具权限与副作用](ios-tool-permissions-and-side-effects.md)。
- **O3** `minis-debug logs` 在所有构建中可用；依赖 RPC 的 `minis-debug` 子命令在 Release 中由 handler 拒绝。命令存在不代表所有子命令可用。
- **O4** offload 开始执行后，停止 shell 不回滚系统 API 已提交的副作用。

## 安全边界

- **S1** iSH 是 App 进程内的 Linux 兼容运行环境，不是独立设备或硬件虚拟机，不作为 App 数据的绝对安全边界。
- **S2** 会话隔离依赖 `fs_context` 的正确传播，以及所有旁路文件解析器遵守同一规则；Host 侧的直接文件访问需要单独审查。
- **S3** 网络命令使用 App 可用的网络能力；能否访问特定地址、局域网或远端服务，由 iOS 权限、网络环境和上层产品策略共同决定。

## 待决定

- [待决定] 产品层允许的最大 shell 并发数和网络边界；确定之前只适用资源开销规范，不设固定数值。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 会话 S 同时发起两个互不冲突的命令 | 两者 PID 和管道不同、可重叠运行，输出和退出码不串线；停止 S 时两者都被停止（C1、C2、T3） |
| 会话 A、B 同时写 `/var/minis/workspace/result.txt` | 分别落到 A、B 的目录，互不覆盖，之后各自读回自己的内容（F1、F2） |
| 命令派生子进程并超时 | 整个进程组被终止，调用以超时结束而不是挂起，后续命令可执行（T2）。有无残留线程需运行期验证 |
| 外部只读挂载 | 授权有效时读取成功，写入明确失败；不可达时不解析到内部目录（F4） |
| offload 已注册但系统权限被拒绝；App 许可为 Not Allowed；命令自身要求确认 | 分别返回系统授权错误、执行前拒绝、仍需确认（O2） |

## 代码入口

- 执行、并发、超时与停止：[ISHExecutionCoordinator](../../src/ios/Agent/ISH/ISHExecutionCoordinator.swift)
- 会话文件路由：[MinisFsRouter](../../src/ios/Agent/ISH/MinisFsRouter.swift)
- kernel 启动与 offload 注册：[ISHKernel.m](../../src/ios/iSH/ISHKernel.m)
- 调试 offload：[DebugOffload.m](../../src/ios/NativeOffloads/DebugOffload.m)
