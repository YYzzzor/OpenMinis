---
description: DEBUG 调试服务的暴露边界、发现与认证协议、JSON-RPC 调用、生命周期、安全要求和可验证场景。
---

# Debug Server API

导航：[Spec 索引](index.md)。

范围：DEBUG 构建中的调试服务，包括客户端接入、认证、RPC 的新增或重命名，以及安全审查。具体 RPC 的方法、参数与返回值以运行时 `rpc.discover` 为准，本文不复制方法全集。

## 生命周期与暴露面

- **L1** 调试服务只用于 DEBUG 构建，不作为产品 API 或 Release 的远程控制面。
- **L2** 默认端口 `8321`。客户端不假设所有构建、设备或网络都能访问该端口。
- **L3** 服务在 DEBUG 启动时开启；App 回到前台时调用 `restartIfDead(port: 8321)`，服务意外退出则重新监听。
- **L4** 服务以 `INADDR_ANY` 监听所有 IPv4 接口，不只是 localhost。“认证默认开启”不能作为扩大监听面的理由（见“待决定”）。
- **L5** 非本机访问必须先配对并认证。关闭认证只能作为明确、可见、可恢复的本地调试操作。

## HTTP 入口

| 入口 | 用途 | 是否使用 RPC 密文信封 |
| --- | --- | --- |
| `GET /schema` | 服务版本、认证状态、入口地址等机器可读信息 | 否 |
| `GET /`、`GET /skill` | 协议说明，按 `Accept` 返回适合人或机器阅读的格式 | 否 |
| `GET /skill/examples/python`（兼容 `/skill/examples/minis_rpc.py`） | Python 客户端示例 | 否 |
| `GET /skill/examples/node`（兼容 `/skill/examples/minis_rpc.mjs`） | Node 客户端示例 | 否 |
| `GET /skill/examples/bash`（兼容 `/skill/examples/minis_rpc.sh`） | Bash 客户端示例 | 否 |
| `POST /pair` | 签发客户端令牌 | 使用配对协议，不是 JSON-RPC |
| `POST /rpc` | 执行 JSON-RPC 2.0 请求 | 认证开启时必须使用 |

- **H1** 未知的 HTTP 方法或路径返回明确错误，不执行相近的操作（POST 的现状见“待决定”）。
- **H2** 认证被显式关闭时，`/rpc` 接受普通 JSON-RPC 请求。这是兼容路径，不是新客户端的默认接入方式。

## 配对

- **P1** 设备批准后，`/pair` 签发一个 32 字节的客户端令牌。
- **P2** `plain: true` 只接受回环或 USB 转发来源，令牌直接返回；局域网来源必须提供临时 X25519 公钥，令牌经其包装后返回。非回环来源请求 plain 时返回 403。
- **P3** 模拟器自动批准配对，以支持无界面自动化；这不能代替真机上批准、拒绝和超时的验证。
- **P4** 令牌带客户端标识，持久化在 Application Support 下的调试认证存储中。列举客户端的 RPC 不返回令牌密钥。

## RPC 信封（协议 v1）

- **E1** 认证开启时，`POST /rpc` 使用加密信封，不接受裸 JSON-RPC。
- **E2** 请求与响应使用方向分离的派生密钥；以 HMAC-SHA256 构造 CTR 密钥流，先加密后计算 MAC。
- **E3** 每个请求使用随机 nonce；时间戳允许偏差 ±120 秒；服务记住最近 1024 个 nonce，拒绝重放。
- **E4** 客户端令牌空闲 30 天过期；刚批准后的信任窗口为 10 分钟。
- **E5** 修改 E2–E4 中任一数值或算法时，同步升级协议版本、`/schema` 与 `/skill` 说明、客户端示例，并写明对旧客户端的兼容或拒绝策略。
- **E6** 缺少认证、密文校验失败、时间越界、nonce 重放、令牌未知、不允许的明文来源，都在执行任何 RPC 之前拒绝。日志可以记录诊断标识，不记录令牌密钥、明文凭证或完整的敏感参数。

## JSON-RPC 与方法发现

- **J1** `/rpc` 的内层请求遵循 JSON-RPC 2.0，例如 `{"jsonrpc":"2.0","id":1,"method":"rpc.discover","params":{}}`。
- **J2** `rpc.discover` 是方法名、用途、参数与可用性的权威来源。发现目录来自 [DebugMethodRegistry](../../src/ios/Debug/DebugMethodRegistry.swift)，实际分发在 [DebugJSONRPC](../../src/ios/Debug/DebugJSONRPC.swift)；新增、删除或重命名方法时两处保持一致。
- **J3** 未知方法返回 JSON-RPC `Method not found`，并提示调用 `rpc.discover`。
- **J4** 能力族包括：视图与可访问性检查、交互与截图、日志与性能诊断、会话与聊天自动化、Provider 与配置管理、备份诊断、浏览器与 MCP 调试。某个具体方法是否存在，以目标构建的 `rpc.discover` 为准。

## 副作用与数据

- **D1** 发现信息中区分只读检查与有副作用的操作（点击或输入、修改配置、发送聊天、创建或删除数据、触发备份恢复、切换认证等）。
- **D2** 新增高风险 RPC 时，同时审查发现信息、认证边界、数据最小化和副作用，不只登记方法名。
- **D3** DEBUG 与配对不代表操作天然安全：每个 RPC 仍做自己的前提检查、参数校验，只返回必要数据。
- **D4** 调试文件读取、数据库查询、日志导出用规范化后的目录包含关系判断路径，不用字符串前缀。
- **D5** 认证开关、令牌撤销、客户端列举属于安全控制面；客户端不缓存“曾经成功”来绕过下一次失败。

## 待决定

- [待决定] H1 的现状缺口：[DebugServer](../../src/ios/Debug/DebugServer.swift) 只对 POST `/pair` 单独分支，其他任何 POST 路径都进入通用 RPC 处理，所以发往未知路径的有效 RPC 仍会执行。认证开启时仍校验信封，因此这不绕过认证，但也不是可以依赖的路径别名。收窄后的验收：带有效认证、无副作用的 RPC 发往未知路径，得到路径错误且不进入业务分发。
- [待决定] 长期是继续监听所有 IPv4 接口，还是默认只监听回环、显式启用局域网（L4）。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 新客户端接入（认证默认开启）：读取 `/schema`、`/skill`，调用 `/pair`，再发送加密的 `rpc.discover` | 未配对的裸 `/rpc` 被拒绝；配对后的加密请求返回 JSON-RPC 响应；结果至少包含 `rpc.discover` 本身，不泄露令牌密钥（P1、E1、J2） |
| 重放一份有效的加密请求；时间戳超出允许偏差 | 两者都失败，对应的业务方法没有产生副作用（E3、E6） |
| App 退到后台再回到前台；服务意外退出 | 存活的服务继续响应；已退出的服务被重新监听。真机验证记录设备、网络、前后台步骤和端口结果（L3） |
| 新增或更改一个 RPC | `rpc.discover` 的名称和参数与实际调用一致；未知名称得到 `Method not found`；`/skill` 说明和客户端示例中没有旧名字（J2、J3） |

## 代码入口

- 监听、路由、重启：[DebugServer](../../src/ios/Debug/DebugServer.swift)
- 配对、信封、重放防护、令牌存储：[DebugAuth](../../src/ios/Debug/DebugAuth.swift)
- 方法目录与分发：[DebugMethodRegistry](../../src/ios/Debug/DebugMethodRegistry.swift)、[DebugJSONRPC](../../src/ios/Debug/DebugJSONRPC.swift)
- 启动与回前台检查：[MinisApp](../../src/ios/MinisApp.swift)
