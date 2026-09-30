---
description: MinisX iOS MCP 的配置身份、HTTP与STDIO调用、发现启停、OAuth与凭证、重试取消及同步备份边界；用于外部工具集成维护。
---

# MinisX iOS MCP 集成

导航：[Spec 索引](index.md)；shell执行与停止见[iSH runtime](ios-sandbox-ish-summary.md)，授权与远端副作用见[工具权限](ios-tool-permissions-and-side-effects.md)，配置传播及恢复见[同步](ios-sync-and-conflict-resolution.md)与[备份](ios-backup-restore.md)。

## 范围、状态与来源

MCP集成由原生配置/授权UI与iSH内CLI/daemon协作。本文记录2026-09-30当前工作区静态状态及已有安全、资源和证据规范的维护要求，不证明外部MCP服务、OAuth、网络、iSH子进程或真机后台行为已成功；没有新增运行证据。仅覆盖iOS当前入口，不把同目录Android实现当iOS验收。

源码：[MCPStore](../../src/ios/Agent/Session/MCPStore.swift)、[MCPOAuthController](../../src/ios/Agent/Session/MCPOAuthController.swift)、[CLI main](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/main.py)、[daemon](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/daemon.py)、[配置](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/utils/config.py)、[HTTP transport](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/transport/http.py)。

## 配置身份、导入与文件

`servers.json`采用`{"mcpServers":{"<name>":{...}}}`，server name既是配置id，也用于OAuth凭证和会话覆盖。HTTP配置url/headers，STDIO配置command/args/env，另有enabled、note、createdAt/updatedAt、oauth及startupTimeoutSeconds。当前daemon优先有command的STDIO，而列表/原生摘要优先url的HTTP；两种目标同时填写时解释不一致，配置验收应分别检查，统一优先级仍待决定。

MCPStore.parseImport接受标准mcpServers、按名称对象及单条配置，disabled映射enabled=false；commitImport同名覆盖，保留既有createdAt。导入成功只代表配置解析/持久化，不代表依赖安装、握手或工具执行可用。配置更新不会自动证明已有daemon连接已使用新端点/凭证。

配置位于隐藏MinisConfig持久目录，通过`/var/minis/mcp-servers`提供给guest，不能因共享挂载而声称可在iOS Files公开读取。普通JSON导出保留url/headers/env原值，包括内联token和占位符；它不是脱敏分享功能。

## 发现、全局启停与会话覆盖

isEnabledForSession以会话覆盖优先于全局enabled；与默认相同的覆盖被删除。systemPromptSnippet按有效启用状态选最新createdAt优先的20个server，note最多200字符，只提供server发现信息与CLI使用提示，不向模型注册每个远端MCP工具为原生Agent工具。

App斜杠菜单按同一有效启用值插入`/<name> `；它是输入辅助，实际调用仍需shell_execute运行minis-mcp-cli。初始Agent loop和fallback重建会生成发现片段；已发请求或已读工具清单不会因开关追溯删除。

### 启停不是统一执行许可

CLI没有App会话覆盖id，daemon建立新session时只检查servers.json全局enabled。全局开启但某会话关闭仍可能通过显式CLI调用；全局关闭而会话开启可展示名称，但冷连接会得到DISABLED。已有warm session在pool.get中先复用，未重新检查全局enabled，所以切换全局开关不能承诺即时阻止缓存连接。

设置页toggle/delete没有直接驱逐daemon缓存连接。此处披露实现缺口，不把它写成允许绕过用户拒绝的规范。需要强制拒绝所有调用的产品，必须定义执行门禁、生效时点与缓存失效并验证；现行[副作用原则](ios-tool-permissions-and-side-effects.md)仍适用。

## 握手、工具列表与调用

首次list/tools/ping/call通过loopback TCP与自启动daemon通信。STDIO为长期子进程stdin/stdout JSON-RPC；HTTP当前为POST initialize及后续请求，携带Mcp-Session-Id，可解析JSON或SSE文本。不能由支持这两种返回推导完整MCP协议版本、通知/流式能力或任意服务器兼容。

`tools <server>`发现远端清单，`refresh`或`tools --refresh`驱逐该连接后重新握手；原生refreshTools要求iSH已启动并以mcp-settings执行，外层超时120秒。`call <server> <tool> --input ...`执行具体工具；server存在、ping成功、tools/list成功和tools/call业务成功是不同阶段。daemon的ok envelope不能取代远端结果/isError或实际副作用核对。

STDIO缺命令、握手失败、服务不存在、全局关闭、工具不存在、HTTP失败、AUTH_REQUIRED及参数错误应保留可诊断类别，不伪报空工具列表为成功。当前config.load_config对缺失或畸形配置返回空对象；不能把这一兼容行为当无错误配置的证明。

## 凭证、OAuth与分享

维护要求延续现有秘密保护：Agent配置优先使用`$$NAME`引用App/进程环境变量，不在聊天/日志输出值。HTTP expand_env同时支持$VAR/${VAR}/$$VAR/$${VAR}，未设置变量当前展开为空；未检查有效鉴权前不能宣称占位符已解决。

OAuth原生使用交互授权、PKCE和Keychain非同步存储，并生成guest可读取的oauth bridge文件，含access/refresh token及必要client secret，权限设置为600。guest可刷新并改写bridge；跨设备只同步oauth配置不代表另一设备已授权。CLI client secret临时种子文件与Keychain/bridge的同步由MCPOAuthController处理，不应在日志展示。

原生authorize当前只检查endpoint scheme以http开头，错误文案却要求https；不能宣称已有严格HTTPS endpoint校验或统一重定向目标保护。通用安全要求与当前实现差异必须保留，是否限制HTTP开发端点仍待维护者决定。

guest缺token返回AUTH_REQUIRED及App授权深链；到期/401有refresh路径，401最多进行一次额外OAuth重试。存在token只说明isAuthorized的本地判断，不证明有效期、服务器接受或revocation状态。signOut清tokens与bridge并保留client secret；purge额外清secret。缓存连接和并发refresh的失效/清理需验证，不能把本地文件删除当远端token已撤销。

### 内联凭证与同步备份例外

MCPServerItem包含原配置JSON，JSON导出和mcp_servers备份均保留headers/env/url内联值。OAuth Keychain/bridge不走普通MCP配置同步，但内联秘密可能随配置传播；这些路径并不是“所有凭证不离开本机”的保证。

专用MCP OAuth secrets随含凭证的providers备份类别处理，另有密码前提；仅关闭includeCredentials不会清除mcp_servers内联值。无密码share copy也不能由此推导完全无秘密。详见[备份内联凭证缺口](ios-backup-restore.md#内联mcp凭证与分享副本限制)。

## 超时、重试与取消边界

STDIO initialize的startupTimeoutSeconds缺省60秒，接受1—900整数；CLI支持兼容别名，primary字段优先，非法值回落默认并警告。原生仅保留字段，真正计时在daemon。RPC/HTTP当前300秒，loopback连接310秒，设置页外层120秒；多个层次的超时不是一个统一保证，更长startup值也可能先被外层切断。

daemon.call_with_retry对TIMEOUT/STDIO_CRASH驱逐并重试一次，且作用于tools/call；HTTP会话错误另有重新握手重试，OAuth有独立401重试。这些路径不检查远端工具是否幂等，可能在响应丢失后重放副作用，是与[安全重试要求](ios-tool-permissions-and-side-effects.md#拒绝超时和错误语义)不一致的现状；本轮仅披露，未修复代码。

Stop/超时能够结束所属shell调用，不代表独立daemon、长期STDIO子进程或远端请求同时取消。调用失败/断开也不证明外部动作未执行；创建、发送、购买等必须区分失败与结果未知，不能盲目重试。何时驱逐共享连接不得从会话PID停止路径推导。

## 资源生命周期与同步

daemon按server复用连接，空闲TTL600秒，watchdog间隔30秒，池变空后有60秒退出宽限；新活动清除宽限。shutdown提供统一停止路径。计时器受iSH/App运行前提影响，不是后台持续执行保证，也没有从TTL推出池数量、线程或响应大小的硬上限。

MCPStore.sync使用per-server记录及updatedAt LWW，扫描CLI外部修改并保留语义fingerprint抑制回声；本地删除请求delete，入站删除有单独处理。会话覆盖在本地SQLite，当前per-server同步与配置JSON备份不包含它。运行连接不随配置同步迁移；OAuth秘密恢复也不证明远端授权有效。协议/门禁见[同步规范](ios-sync-and-conflict-resolution.md)。

## 场景与验收

本次未执行下列场景；应以测试服务和可丢弃数据取得独立证据。

| 场景与前提 | 可观察验收 |
| --- | --- |
| 导入同名server、分别配置HTTP或STDIO | 覆盖规则、字段保留和错误可见；另检查双目标优先级，不由配置存在推导连接成功。 |
| 全局/会话相反启停，已有warm连接 | 比较发现、菜单、冷连接与warm调用，明确现有门禁缺口，不将UI隐藏当拒绝证据。 |
| 远端新增工具后执行refresh | 重新握手后列表变化，原生外层120秒前提可见；列表存在不代替实际工具结果。 |
| OAuth取消、过期、401及另一设备同步 | 取消不伪报授权；refresh有界；设备侧凭证单独取得；端点HTTPS校验缺口保持开放。 |
| 有副作用工具提交后丢失响应 | 观察实际调用次数和远端结果，不能把自动重试当安全幂等；当前未满足项明确记录。 |
| Stop、离开设置页、空闲TTL或shutdown | 区分shell PID、daemon、子进程和远端动作；检查资源释放，不承诺会话退出全部取消。 |
| 配置含内联token或$$引用后导出/备份 | 使用占位测试值检查JSON字节是否保留；不输出真实秘密，不将share copy称为自动脱敏。 |

## 证据与待维护者决定

[test_startup_timeout.py](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/test_startup_timeout.py)和[test_http_reinit.py](../../src/ios/default_mount/usr/local/lib/minis-mcp-cli/test_http_reinit.py)提供超时和重连测试入口，本轮未运行；它们不能证明真实iSH/OAuth/后台或外部动作正确。

待决定：启停是否为强制执行许可及warm缓存失效；HTTP开发端点与HTTPS策略；有副作用工具重试/幂等策略；删除/登出的并发refresh清理；内联秘密同步、导出和备份保护；共享连接的取消归属及数量/响应资源上限。新增Spec不意味着这些决定或缺陷已关闭。
