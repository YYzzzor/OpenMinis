---
description: MinisX iOS MCP 的配置身份、HTTP与STDIO调用、发现启停、OAuth与凭证、重试取消及同步备份边界；用于外部工具集成维护。
---

# MinisX iOS MCP 集成

导航：[Spec 索引](index.md)；shell 执行与停止见 [iSH 运行契约](ios-sandbox-ish-summary.md)，授权与远端副作用见 [工具权限](ios-tool-permissions-and-side-effects.md)，配置传播与恢复见 [同步](ios-sync-and-conflict-resolution.md) 和 [备份](ios-backup-restore.md)。

范围：iOS 上的 MCP 集成，由原生配置与授权界面、iSH 中的 CLI 与 daemon 协作完成。不包括同目录下的 Android 实现。

## 配置与导入

- **C1** `servers.json` 的格式为 `{"mcpServers":{"<name>":{...}}}`。server name 同时是配置 id，也用于 OAuth 凭证和会话覆盖。
- **C2** HTTP 配置 `url` / `headers`；STDIO 配置 `command` / `args` / `env`；另有 `enabled`、`note`、`createdAt` / `updatedAt`、`oauth`、`startupTimeoutSeconds`。
- **C3** `parseImport` 接受标准的 `mcpServers`、按名称组织的对象和单条配置，`disabled` 映射为 `enabled=false`；`commitImport` 同名覆盖，保留原有的 `createdAt`。导入成功只表示配置已解析并保存，不代表依赖已安装、握手或工具可用；配置更新也不代表已有的 daemon 连接改用了新的端点或凭证。
- **C4** 配置位于隐藏的 MinisConfig 持久目录，通过 `/var/minis/mcp-servers` 提供给 guest，不在“文件”App 中公开。
- **C5** 普通 JSON 导出原样保留 `url` / `headers` / `env`，包括内联 token 和占位符；它不是脱敏分享。

## 发现与启停

- **D1** 会话中是否启用：会话覆盖优先于全局 `enabled`；与全局相同的覆盖会被删除。
- **D2** 发现片段按会话中的有效启用状态，选出 `createdAt` 最新的 20 个 server，`note` 截断到 200 字符。它只提供 server 信息和 CLI 用法提示，不把每个远端 MCP 工具注册为原生 Agent 工具。
- **D3** 斜杠菜单按同样的有效启用状态插入 `/<name> `，只是输入辅助；实际调用仍需通过 `shell_execute` 运行 `minis-mcp-cli`。
- **D4** 发现片段在 Agent 循环开始和 fallback 重建时生成；已发出的请求和已读取的工具清单不会因为开关变化而被撤回。
- **D5** 启停的作用范围各不相同，合起来也不是完整的执行许可：
  - 会话覆盖只影响发现片段和斜杠菜单；
  - 全局 `enabled` 还决定 daemon 能否建立新的（冷）连接，关闭时返回 `DISABLED`；
  - 已有的 warm 连接复用时不重新检查全局 `enabled`。
  现状缺口见“待决定”。

## 调用

- **P1** `list` / `tools` / `ping` / `call` 通过 loopback TCP 与自动启动的 daemon 通信。STDIO 是长期运行的子进程，通过 stdin / stdout 传 JSON-RPC；HTTP 用 POST initialize 及后续请求，携带 `Mcp-Session-Id`，解析 JSON 或 SSE 文本。这不代表支持完整的 MCP 协议版本、通知或流式能力。
- **P2** `tools <server>` 获取远端工具清单；`refresh` 或 `tools --refresh` 断开该连接后重新握手。原生的 `refreshTools` 要求 iSH 已启动，外层超时 120 秒。
- **P3** `call <server> <tool> --input ...` 执行具体工具。server 存在、ping 成功、tools/list 成功、tools/call 业务成功是四个不同阶段；daemon 返回 ok 不代表远端结果成功（需看 `isError`）或副作用已发生。
- **P4** STDIO 缺少命令、握手失败、server 不存在、全局关闭（`DISABLED`）、工具不存在、HTTP 失败、`AUTH_REQUIRED`、参数错误，都保留可诊断的错误类别，不把空工具列表当成功。
- **P5** 当 daemon 同时看到 `command` 和 `url` 时优先按 STDIO 处理，而列表和原生摘要优先按 HTTP 显示（见“待决定”）。

## 凭证与 OAuth

- **A1** 配置中优先用 `$$NAME` 引用 App 或进程的环境变量，不在聊天或日志中输出值。HTTP 的变量展开支持 `$VAR`、`${VAR}`、`$$VAR`、`$${VAR}`；未设置的变量展开为空字符串。
- **A2** OAuth 使用交互授权、PKCE 和不同步的 Keychain 存储，并生成 guest 可读的 OAuth bridge 文件（含 access / refresh token 和必要的 client secret，权限 600）。guest 可以刷新并改写 bridge。只同步 OAuth 配置不代表另一台设备已授权。
- **A3** guest 缺 token 时返回 `AUTH_REQUIRED` 和 App 授权深链；token 过期或 401 时有刷新路径，401 最多额外重试一次 OAuth。本地有 token 不代表未过期、服务器接受或未被撤销。
- **A4** `signOut` 清除 token 和 bridge，保留 client secret；`purge` 另外清除 secret。删除本地文件不代表远端 token 已撤销。
- **A5** client secret 的临时种子文件与 Keychain / bridge 的同步由 `MCPOAuthController` 处理，不出现在日志中。

### 内联凭证与同步备份例外

- **A6** 配置 JSON 中的 `headers` / `env` / `url` 内联值会出现在 JSON 导出和 `mcp_servers` 备份中；OAuth 的 Keychain 与 bridge 不走普通配置同步，但内联秘密可能随配置同步传播。
- **A7** MCP OAuth secrets 随含凭证的 providers 备份类别处理，需要密码；关闭 `includeCredentials` 不会清除 `mcp_servers` 中的内联值，无密码的分享副本也不代表没有秘密。见 [备份](ios-backup-restore.md)。

## 超时、重试与取消

- **T1** STDIO initialize 的 `startupTimeoutSeconds` 默认 60 秒，接受 1–900 的整数及可转为整数的数值字符串；CLI 支持兼容的别名字段，主字段优先。布尔值、非数值、非整数、越界值回落到默认值并警告。原生端只保存字段，实际计时在 daemon。
- **T2** RPC / HTTP 超时 300 秒，loopback 连接 310 秒，设置页外层 120 秒。多层超时不是统一的保证：较长的启动超时也可能先被外层切断。
- **T3** Stop 或超时可以结束所属的 shell 调用，但不代表独立的 daemon、长期的 STDIO 子进程或远端请求一并取消。调用失败或断开也不代表外部动作没有执行：创建、发送、购买等要区分“失败”与“结果未知”，不盲目重试。

## 资源与同步

- **R1** daemon 按 server 复用连接：空闲 600 秒断开，巡检间隔 30 秒，连接池清空后再等 60 秒退出，期间有新活动则取消退出。`shutdown` 提供统一的停止路径。计时依赖 iSH / App 在运行，不是后台持续执行的保证。
- **R2** `MCPStore.sync` 按 server 记录同步，以 `updatedAt` 后写者胜；扫描 CLI 在外部的修改，用语义指纹抑制回声；本地删除发出远端删除，收到的删除单独处理。
- **R3** 会话覆盖保存在本地 SQLite，不在按 server 的同步和配置 JSON 备份中。运行中的连接不随配置同步迁移；恢复 OAuth 秘密不代表远端授权有效。

## 待决定

- [待决定] D5 的缺口：CLI 不知道 App 的会话覆盖，daemon 建新连接时只检查全局 `enabled`。全局开启而某会话关闭时，显式 CLI 调用仍可成功；已有的 warm 连接复用时不重新检查全局 `enabled`；设置页的开关和删除不驱逐 daemon 中的缓存连接。启停是否应成为强制的执行许可、何时让缓存失效，待决定。
- [待决定] 有副作用工具的重试：`call_with_retry` 对 `TIMEOUT` / `STDIO_CRASH` 驱逐后重试一次，也作用于 `tools/call`；HTTP 会话错误会重新握手重试；OAuth 另有 401 重试。这些都不检查工具是否幂等，响应丢失后可能重放副作用，与 [工具权限](ios-tool-permissions-and-side-effects.md) 的 F4 不一致。
- [待决定] OAuth 端点：原生授权只检查 scheme 以 `http` 开头，错误文案却要求 https；是否允许 HTTP 开发端点、如何校验重定向目标。
- [待决定] P5 的优先级：同时配置 `command` 和 `url` 时，daemon 与界面的解释不一致。
- [待决定] 非有限的数值字符串（`NaN`、`Infinity`）作为启动超时时，转换整数会抛出未捕获的异常（T1）。
- [待决定] `config.load_config` 对缺失或格式错误的配置返回空对象，与“无错误配置”无法区分。
- [待决定] 删除或登出时并发刷新的清理；内联秘密在同步、导出、备份中的保护；共享连接的取消归属，以及连接数、响应大小的资源上限。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 导入同名 server；分别配置 HTTP 和 STDIO | 覆盖规则、字段保留和错误都可见；同时配置两种目标时分别检查解释是否一致；不由“配置存在”推断能连接（C3、P5） |
| 全局与会话启停相反，且已有 warm 连接 | 对比发现片段、菜单、冷连接与 warm 调用的表现，记录现有门禁缺口；界面隐藏不作为拒绝的证据（D1、D5） |
| 远端新增工具后执行 refresh | 重新握手后清单变化；原生外层 120 秒超时可见；清单存在不代替实际的工具结果（P2、P3） |
| OAuth 取消、过期、401、另一台设备同步 | 取消不伪报已授权；刷新有界；另一台设备需要单独授权（A2、A3） |
| 有副作用的工具提交后丢失响应 | 观察实际调用次数和远端结果，不把自动重试当作安全的幂等（T3，待决定的重试缺口） |
| Stop、离开设置页、空闲超时、shutdown | 分别检查 shell PID、daemon、子进程、远端动作；检查资源释放，不承诺会话退出即全部取消（T3、R1） |
| 配置含内联 token 或 `$$` 引用后导出、备份 | 用占位测试值检查 JSON 是否原样保留；不输出真实秘密，不把分享副本称为自动脱敏（C5、A6、A7） |

## 代码入口

- 配置、启停、发现片段、同步：[MCPStore](../../src/ios/Agent/Session/MCPStore.swift)
- OAuth：[MCPOAuthController](../../src/ios/Agent/Session/MCPOAuthController.swift)
- CLI 与 daemon：[main.py](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/main.py)、[daemon.py](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/daemon.py)、[config.py](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/utils/config.py)、[http.py](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/transport/http.py)
- 测试：[test_startup_timeout.py](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/test_startup_timeout.py)、[test_http_reinit.py](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/test_http_reinit.py)
