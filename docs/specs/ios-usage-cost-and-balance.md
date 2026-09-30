---
description: 上下文占用、会话 token 累计、DeepSeek 会话费用估算与账户余额的计量规则、显示规则和验收场景。
---

# MinisX iOS 用量、费用与余额

范围：聊天界面“会话 Token 用量”页展示的四种数值。模型身份与切换见 [Provider 路由](ios-provider-model-routing.md)；停止、重试与消息持久化见 [Agent 生命周期](ios-agent-run-lifecycle.md)。

## 四种数值

| 数值 | 定义 |
| --- | --- |
| 上下文占用 | 最近一次请求的输入 + 缓存读取 + 缓存创建，与当前模型窗口比较。 |
| 会话 token 累计 | 每次模型请求返回后累加一次；打开会话时由已保存消息的用量重建。 |
| 会话费用估算 | 本机费用账本中，本会话各请求的 DeepSeek 估算金额之和（CNY）。 |
| 账户余额 | 当前 Provider 账号在 DeepSeek 服务端的 CNY 余额。 |

四者各自计算，不互相推导：例如不用余额减费用，不用上下文占用代替累计。

## 计量规则

- **U1** 同一请求的流式 usage 是累计值：input/output 取最大值，缓存字段取最新值；不把片段相加。
- **U2** 上下文快照仅在会话、历史 revision、stream entry 与配置身份都匹配时更新；不匹配时保留上次有效值或显示未知。

## 计价规则

- **P1** 仅计价官方服务：HTTPS `api.deepseek.com`（根或 `/v1`，可带 `:443`）+ 源码列出的 flash / pro 模型 ID。模型按服务端响应中的 `model` 判断（缺失时用配置的模型 ID）。其他域名、代理、Azure、同名兼容服务一律不计价。
- **P2** 当前账号需同时满足：启用、API Key 鉴权、OpenAI 或 OpenAI Responses 路由、非 azureMode、且当前模型满足 P1。
- **P3** 读取总输入（`prompt_tokens`，Responses 为 `input_tokens`）、输出与缓存命中（`*_tokens_details.cached_tokens` 或 `prompt_cache_hit_tokens`）。新输入 = 总输入 − 缓存命中，缓存单独计价。字段须为非负整数且缓存 ≤ 总输入；存在 `prompt_cache_miss_tokens` 时须等于总输入 − 缓存。任一条件不满足 → 该请求未计价。
- **P4** 价格版本 `2026-09-29`（单价见源码）。按请求**开始时刻**（Asia/Shanghai）定档：工作日 9:00–12:00、14:00–18:00 为峰时，周末与 2026 法定节假日为闲时，闲时按峰时 50%。以下情况不估算：开始或结束不在 2026 年；早于该模型价格生效时间（pro 2026-08-17，flash 2026-09-10 12:00）；开始日为源码列出的调休休息日。
- **P5** 金额用 Decimal 保存，连同价格版本、档位与时间依据；已保存记录不因价格更新而重算。

## 账本规则

- **L1** 只有本机新建的会话登记账本；旧会话、云端导入、备份恢复的会话不登记，也不按当前价格回算。
- **L2** 已登记会话中的**每个**模型请求都分配一个 UUID 登记，不区分 Provider：开始时请求数 +1、未计价数 +1；首次成功计价时计入总额、未计价数 −1。重复完成不重复计费。
- **L3** 仅在无流错误且收到 stopReason 时计价；取消、中断、用量不完整、不满足 P1/P4 的请求保持未计价。Retry 与 fallback 都是新请求，不回滚旧记录。
- **L4** 编辑、截断、Retry 消息不撤销已记费用；删除会话时级联删除其账本。
- **L5** 统计范围为经聊天流处理的模型请求：主回答、工具循环、提醒、重试与 fallback。标题生成、上下文压缩、浏览器 / MCP 等服务不计入。

## 余额规则

- **B1** 请求 `GET https://api.deepseek.com/user/balance`，Bearer 鉴权；拒绝重定向，不用 cookie / URL 缓存；超时 12 s（请求）/ 15 s（资源）；仅接受 HTTP 200，响应最多读取 16,384 字节。
- **B2** 只接受唯一且合法的 CNY `total_balance`；缺失、重复或格式错误 → 查询失败。`is_available=false` 不影响余额值；0 与负数照常显示。
- **B3** 账号身份 = providerID + config / auth revision；读取 Key 前再次确认身份仍是当前账号。身份变化立即清除旧余额，迟到的旧响应被丢弃。
- **B4** 余额状态随费用页面存在：页面打开时查询；页面存续期间同一身份 60 秒内复用结果，“刷新余额”强制请求。每次请求前先清除旧值；失败（含无 Key）显示“—”与失败提示。关闭页面取消请求，不显示失败；重新打开即重新查询。无后台轮询。

## 显示规则

- **D1** 未登记账本的会话（L1）不显示“费用与余额”分区；尚未保存的新对话显示。
- **D2** 当前账号不满足 P2 时，费用与余额都显示“—”，即使账本中有旧金额。
- **D3** 会话费用仅在未计价数为 0 时显示金额（无请求时显示 ¥0.00），否则显示“—”。因此会话中只要出现一次未计价请求（如用过非 DeepSeek 模型、一次中断），该会话此后一直显示“—”。这是已确认的行为（2026-09-30 维持现状），不显示部分金额。
- **D4** 正数小于 0.0001 显示 `<¥0.0001`，其余保留 2–4 位小数；显示舍入不改变存储值。
- **D5** token 累计、历史统计与费用账本覆盖范围不同，数值可以不相等；不为对齐而改写任何一方。

## 资源约束

每个请求开始 / 完成各一次有界数据库事务；读取总额为单行查询，不扫描账本；余额不随 token 刷新。通用要求见 [资源规范](resource-efficiency.md)。

## 不在范围内

- 账户全部消费（仅覆盖 L5 所列请求）；与官方账单逐笔一致。
- 费用记录的备份与同步：账本是本地表，恢复聊天不恢复费用。

## 待决定

- [待决定] 账本记录没有 instance / entry 字段，暂不支持按实例分账；见 [Provider 用量身份](ios-provider-model-routing.md#配置变化和用量归因)。
- [待决定] 旧会话是否追溯；费用的保留、同步与备份。
- [待决定] 价格更新流程；2027 年起的节假日与价格；跨峰谷请求的服务端结算依据。
- [待决定] 数据库写入失败时的界面提示（目前静默失败）。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 新会话一次回答触发 3 次 DeepSeek 请求（含 2 次工具） | 登记 3 个请求；全部计价后显示总额；上下文占用 ≠ 三次之和（U1、L2） |
| 同一请求收到多次累计 usage | 不重复相加；新输入 + 缓存 = 总输入；字段缺失则该请求未计价（U1、P3） |
| 中断后 Retry；重复完成；截断消息 | 中断请求未计价，新请求独立计费，已记金额不变，会话费用显示“—”（L2–L4、D3） |
| 同一会话先用非 DeepSeek 模型，再切到 DeepSeek | 前者登记为未计价；切换后费用显示“—”，余额正常查询（L2、D3） |
| 打开旧会话或导入的会话 | 不显示“费用与余额”分区（L1、D1） |
| 请求中切换模型 / 实例 / Key | 上下文快照跟随新身份，旧费用保留，旧余额响应被丢弃（U2、B3） |
| 代理服务同名模型；调休日或 2027 年的请求 | 费用显示“—”（P1、P4、D2、D3） |
| 余额超时、取消、重复 CNY、负数 | 失败显示“—”与提示；取消不报错；重复拒绝；负数照常显示（B2、B4） |
| 页面内 60 秒内再触发；手动刷新；关闭再打开 | 复用；重新请求；重新请求（B4） |

## 代码入口

- 用量：[ChatModels.TokenUsage](../../src/ios/Agent/Chat/ChatModels.swift)、[AIChatViewModel](../../src/ios/Agent/Chat/AIChatViewModel.swift)、[SSEStream](../../src/ios/Agent/Chat/AIChatViewModel+SSEStream.swift)
- 计价与账本：[Billing](../../src/ios/Agent/Chat/AIChatViewModel+Billing.swift)、[DeepSeekRequestUsage](../../src/ios/Providers/OpenAI/DeepSeekRequestUsage.swift)、[DeepSeekBilling](../../src/ios/Providers/OpenAI/DeepSeekBilling.swift)、[SessionCostLedger](../../src/ios/Providers/OpenAI/SessionCostLedger.swift)
- 余额：[DeepSeekBalanceClient](../../src/ios/Providers/OpenAI/DeepSeekBalanceClient.swift)
- 界面：[UsageStatsView](../../src/ios/Views/Chat/UsageStatsView.swift)、[AIChatView 中的 SessionBillingSection](../../src/ios/Views/Chat/AIChatView.swift)
- 测试：DeepSeekBillingTests、SessionCostLedgerTests、DeepSeekBalanceModelTests、ContextUsageTests（`src/ios/MinisTests/`）
