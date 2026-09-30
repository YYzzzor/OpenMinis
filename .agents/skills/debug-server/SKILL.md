---
name: debug-server
description: 通过 MinisX DEBUG 构建内置的调试服务（端口 8321）查看和操作运行中的 App：界面树、点击输入、截图、日志、数据库、Agent 运行记录、同步与浏览器状态。用于在模拟器或 USB 真机上为改动取证，或排查只在运行时可见的问题。只读代码、Release 构建不使用。
---

# 调试服务

规则见 [Debug Server API Spec](../../../docs/specs/debug-server-api.md)；验证原则见 [项目指南：设备与验证](../../../docs/project-guide.md#设备与验证)。

## 接入

1. App 以 DEBUG 构建运行。`curl -s 127.0.0.1:8321/schema` 返回 `"auth":"v1"` 即可用。
   - 模拟器与 Mac 共用网络，直接访问；真机先用 USB 转发：`iproxy 8321 8321`。
2. 用客户端调用（标准库，无依赖）：

   ```sh
   python3 .agents/skills/debug-server/examples/minis_rpc.py <method> ['<params-json>']
   python3 .agents/skills/debug-server/examples/minis_rpc.py --png shot.png debug.screenshot '{"scale":0.5}'
   ```

   首次调用自动配对：模拟器自动批准；真机弹出 Allow/Deny，需用户点 Allow。令牌缓存在 `~/.cache/minis-debug/`，失效时自动重新配对。
3. 方法、参数和返回值以 `rpc.discover` 为准，不凭记忆调用。

## 常用方法

| 目的 | 方法 |
| --- | --- |
| 找元素 | `debug.search`（`scope:"text"` 可找 SwiftUI 文字）、`debug.viewTree`、`debug.inspect` |
| 操作 | `debug.tap`（优先 `identifier` / `label` / `text`，坐标只作兜底）、`debug.inputText`、`debug.scroll` |
| 看画面 | `debug.screenshot`（配合 `--png` 保存后查看） |
| 看状态 | `debug.logs.flush` → `debug.logs.read`、`debug.db.list` / `debug.db.query`（只读）、`debug.agentTrace`、`debug.sync.*`、`debug.browser.*` |
| 性能 | `debug.hangDetector.*`、`debug.perfTrace.*` |

## 约束

- 先说明要用哪些观察结果证明目标行为；截图或调用成功只证明那一步。
- 改变数据或产生费用的方法先向用户确认，例如 `config.set`、`chat.prompt`（调用真实模型）、`debug.backup.restore`、各类删除方法。
- 真机上只操作用户确认过的设备。
- 与 Xcode 的 device-interaction 工具互补：界面交互可用任一方，App 内部状态用本服务。

## 协议摘要（v1，供自写客户端）

- `POST /pair {"client_name", "plain": true}` → `{"token": hex32B}`，仅限回环来源；局域网须改用 X25519 包装（见 Spec P2）。
- `POST /rpc` 发送信封 `{v:1, tok, ts, nonce, ct, tag}`。K 为令牌：`tok = SHA256(K)[:4]`，nonce 16 字节，`ts` 为 Unix 秒（±120s）。
  - `k_mac = HMAC(K, "minis-dbg-v1|mac"‖nonce)`；`tag = HMAC(k_mac, "v1"‖tok‖be64(ts)‖nonce‖ct)`。
  - `ct = 明文 XOR 密钥流`；密钥流第 i 块 = `HMAC(k_enc, nonce‖be32(i))`，`k_enc = HMAC(K, "minis-dbg-v1|enc-req"‖nonce)`。
  - 响应 `{v, nonce, ct, tag}`：用 `"enc-resp"` 派生的密钥解密，`tag = HMAC(k_mac, "resp"‖nonce‖ct)`。
- 认证失败返回 401 和 `{error:{code}}`，常见 `token_unknown`、`token_expired`、`ts_skew`、`nonce_replayed`。
