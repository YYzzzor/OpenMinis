---
description: iOS 内嵌 iSH shell 的运行、并发、文件作用域、超时取消、原生 offload 与安全边界。
---

# iOS iSH Runtime and Isolation Contract

导航：[Spec 索引](index.md)。

状态：现行运行契约与当前实现说明。本文面向 shell 工具、会话文件、原生 offload 和取消/超时相关改动；它不是 iSH 内部库或类文件的逐项架构清单。

## 范围与证据

当前工程的 iOS deployment target 为 26.0。旧文档中的“iOS 14+”、全局 FIFO、固定 handler 数量、100 KB 输出上限等描述不再作为事实。

主要源码来源：

- [ISHExecutionCoordinator.swift](../../src/ios/Agent/ISH/ISHExecutionCoordinator.swift)：命令执行、并发、环境变量、超时和停止。
- [MinisFsRouter.swift](../../src/ios/Agent/ISH/MinisFsRouter.swift)：会话文件路由。
- [ISHKernel.m](../../src/ios/iSH/ISHKernel.m)：kernel 启动和 native offload 注册。
- [OffloadPermissionManager.swift](../../src/ios/Agent/Offload/OffloadPermissionManager.swift)：App 层工具许可；详见 [iOS 工具权限与副作用](ios-tool-permissions-and-side-effects.md)。

底层模拟器、网络栈和长时间稳定性未在本轮运行验证。

## 执行前提

一次 Agent shell 执行必须具备：

- 已启动的 `ISHKernel`；否则返回 `kernelNotBooted`；
- 非空 session id；文件作用域和停止范围以它为边界；
- 可创建独立 `/bin/sh` 进程及 stdin/stdout/stderr pipe；
- 对命令访问的外部挂载或 iOS 数据具备对应授权。

shell 默认工作目录为 `/root`。用户环境变量由 `EnvVarStore` 注入；其值属于凭证/个人配置，不得写入普通日志或错误回显。

## 并发与进程模型

### 现行契约

- 不同会话可以并发执行 shell。
- 同一会话内的多个 `shell_execute` 也可以并发执行。
- 每次调用创建独立 shell、PID、pipe 和会话 `fs_context`；不存在可依赖的共享交互式 shell 状态。
- 调用方不得依赖提交顺序等于完成顺序，也不得通过一个命令的 `cd`、局部环境变量或 shell 变量影响下一个命令。
- 并发写同一文件、端口、数据库或外部资源时，调用方负责避免竞态或显式串行化。

`perSessionInflight` 名称和部分遗留注释仍提到“队列/一个 shell”，但当前 `execute` 不等待前项；该表只用于记录 PID、停止和清理。实现判断以执行路径而非过时注释为准。

## 文件系统作用域

### 会话目录

`MinisFsRouter` 为每个 session id 分配稳定的 `fs_context`，并把四个 guest bucket 路由到对应会话目录：

| Guest 路径 | Host 作用域 |
|---|---|
| `/var/minis/attachments` | `<minis-base>/<session-id>/attachments` |
| `/var/minis/offloads` | `<minis-base>/<session-id>/offloads` |
| `/var/minis/workspace` | `<minis-base>/<session-id>/workspace` |
| `/var/minis/browser` | `<minis-base>/<session-id>/browser` |

fork 出的子进程应继承同一 context。并发会话不得通过“最后挂载的 session”互相覆盖四个 bucket。

### 全局与外部目录

`/var/minis/memory`、`/var/minis/skills`、`/var/minis/shared` 走静态全局挂载，可以跨会话访问。用户外部目录位于 `/var/minis/mounts`，依赖 security-scoped bookmark/File Provider 权限，并可能只读或暂时不可达。

“全局可见”不等于“可任意写入”。文件工具和 offload 仍需执行路径、只读、授权及操作级别检查。

### MCP独立daemon的边界

MCP CLI通过独立daemon复用HTTP/STDIO连接，其生命周期不等于每次shell的会话PID。停止所属shell调用不证明daemon、长期服务子进程和远端动作同时取消；全局挂载或会话开关也不证明统一执行许可。超时层次、TTL、自动重试及配置秘密见[MCP集成](ios-mcp-integrations.md#超时重试与取消边界)，不能把本文会话停止要求当作该路径已经全面实现的证据。

## 超时、停止与结果

- 未指定时，shell 默认超时为 300 秒。
- 超时会终止整个进程组，而不只是根 PID，并主动完成超时 context 清理；结果以退出码 `-1` 和明确超时文本返回。
- 用户停止某会话时，应终止该会话记录的所有 live PID；紧急全局停止可以终止所有会话的命令。
- 非隔离的 PID 快照停止路径用于 actor 本身被阻塞时仍能发出 kill；调用方应根据返回的 PID 数记录实际发出了多少次停止信号。
- 停止/超时只证明发送了终止和清理动作，不自动证明外部副作用被回滚。已写文件、已提交系统事件或已发出的网络请求可能保留。
- 输出必须保留 stdout/stderr 对问题定位有用的内容，并对超长结果采用资源开销规范中的截断/offload 机制；本文不规定一个未经源码确认的固定 100 KB 上限。

## Native offload

iSH kernel 在 `execve` 阶段按注册名拦截部分命令，把它们交给 iOS 原生 handler，再通过进程 I/O 返回结果。当前注册清单以 [ISHKernel.m](../../src/ios/iSH/ISHKernel.m) 的启动代码为准，覆盖媒体、日历、位置、照片、健康、Home、提醒事项、浏览器、会话、配置、调试等能力。

约束：

- 不在本文维护固定“共 N 个 handler”；新增/移除注册项时应更新对应能力 Spec 和命令帮助。
- 原生 offload 仍是 shell 命令的一部分，必须遵守 iOS 系统授权、App 工具许可和操作级确认，详见[工具权限规范](ios-tool-permissions-and-side-effects.md)。
- `minis-debug logs` 当前可在每个构建注册；依赖 RPC 的调试子命令仍由 handler 在 Release 中拒绝。不得从“命令存在”推断所有子命令可用。
- offload 已开始执行后，shell 停止不保证系统 API 已提交的副作用回滚。

## 安全与资源边界

- iSH 是 App 进程内的 Linux 兼容运行环境，不是独立设备或硬件虚拟机。不得把它描述为对 App 数据的绝对安全边界。
- 会话隔离依赖正确传播 `fs_context` 和所有旁路文件解析器遵守同一规则；Host 侧直接访问仍需单独审查。
- 网络命令使用 App 可用的网络能力；是否允许访问特定地址、局域网或远端服务由 iOS 权限、网络环境和上层产品策略共同决定。
- JIT/解释器内部故障处理、宿主崩溃隔离和长时间内存稳定性未由本 Spec 证明。
- 并发数、输出规模、图片数量和上下文 offload 继续遵守[资源开销规范](resource-efficiency.md)，不得因为底层支持并发就无界 fan-out。

## 场景与验收

### 场景 A：同会话并发命令

前提：kernel 已启动，会话 S 同时发起两个互不冲突的命令。

可观察验收：两者获得不同 PID 和 pipe，可以重叠运行；各自输出和退出码不串线；停止 S 时所有 live PID 都被纳入停止范围。

### 场景 B：跨会话同名文件

前提：A、B 同时写 `/var/minis/workspace/result.txt`。

可观察验收：Host 分别落到 A、B 目录，内容不互相覆盖；重新读取时仍按各自 session context 返回。

### 场景 C：命令超时并带子进程

前提：命令派生子进程并超过默认或指定 timeout。

可观察验收：整个进程组收到终止，调用完成为超时而非永久挂起；后续命令仍能执行。是否存在残留线程/子进程需要运行期或设备级验证，不能由静态阅读替代。

### 场景 D：外部只读挂载

可观察验收：读取在授权有效时成功；写入明确失败；远端不可达不会把路径解析到内部目录；停止 shell 不伪造“已回滚”结果。

### 场景 E：offload 权限分层

可观察验收：命令注册存在但系统权限拒绝时返回系统授权错误；App 设置为 Not Allowed 时在执行前拒绝；命令自身需要确认时仍不能由前两层授权替代。

## 已知限制与待验证事项

- 已核实问题：旧 Spec 的 iOS 14+、全局 FIFO、固定 handler 数、原子切换工作副本等描述与当前源码不一致，本文已移除。
- 当前源码中仍有少量 FIFO/单 shell 遗留注释，与实际并发路径冲突；它们是代码注释清理事项，不改变本文契约。
- 待验证：高并发、超时进程树、外部 File Provider 阻塞、后台挂起和长时间内存表现。
- 待维护者确认：产品层允许的最大 shell 并发和网络边界；在确认前只应用资源开销上限，不发明固定数值。
