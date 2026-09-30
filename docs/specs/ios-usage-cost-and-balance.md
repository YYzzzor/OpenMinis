---
description: MinisX iOS 上下文占用、token累计、请求费用账本与账户余额的定义、身份归因、未知状态、持久化和资源边界；用于统计与费用展示变更。
---

# MinisX iOS 用量、费用与余额

导航：[Spec 索引](index.md)；模型身份与切换见[Provider路由](ios-provider-model-routing.md)，停止/重试及消息持久化见[Agent生命周期](ios-agent-run-lifecycle.md)。

本文记录2026-09-30当前工作区静态实现及延续现有证据、身份和资源规范的维护要求，没有本轮运行或账户查询证据。它不是Provider账单、当前官方价格表或未来费率保证。价格和时间适用性只以源码中版本化估算器说明；更新估算器前另行核实服务约定，不能由本Spec证明官方计费一致。

## 范围、状态与来源

主要入口：[ChatModels.TokenUsage](../../src/ios/Agent/Chat/ChatModels.swift)、[AIChatViewModel](../../src/ios/Agent/Chat/AIChatViewModel.swift)、[SSEStream](../../src/ios/Agent/Chat/AIChatViewModel+SSEStream.swift)、[Billing](../../src/ios/Agent/Chat/AIChatViewModel+Billing.swift)、[DeepSeekRequestUsage](../../src/ios/Providers/OpenAI/DeepSeekRequestUsage.swift)、[DeepSeekBilling](../../src/ios/Providers/OpenAI/DeepSeekBilling.swift)、[SessionCostLedger](../../src/ios/Providers/OpenAI/SessionCostLedger.swift)、[BalanceClient](../../src/ios/Providers/OpenAI/DeepSeekBalanceClient.swift)、[UsageStatsView](../../src/ios/Views/Chat/UsageStatsView.swift)及[SessionBillingSection](../../src/ios/Views/Chat/AIChatView.swift)。

## 四种数值不能互相推导

| 数值 | 定义与当前范围 |
| --- | --- |
| 当前上下文占用 | 最近请求的输入、缓存读取与缓存创建之和latestContextTokens，与当前模型窗口比较；不是累计消费或输出上限。 |
| 会话token累计 | Agent loop对每次返回的streamResult计入input/output/cache；累计已观察到的响应，缺失/异常路径不代表真实计费为零。 |
| 会话费用估算 | 已登记聊天请求的本地费用账本，包含工具循环中的各次模型请求；当前只对支持的DeepSeek请求取得完整用量后计价。 |
| 账户余额 | 当前Provider实例对应账号的独立远端CNY余额查询；不等于会话费用、充值总额或从token计算出的余量。 |

维护要求：未知用量、缺失字段、未计价请求和不支持账号显示未知/不可用，不替换为零。已登记且全部请求完成计价的账本总额为零时（包括尚无请求或完整合法用量计算得到零），以及服务明确返回零余额时，可以显示零；未计价或缺失信息不得伪装为零。token统计、费用记录和余额要保留各自身份与时间依据，不能套用同一个发布门禁。

## 请求用量与上下文快照

TokenUsage.add对流式累计input/output采用max，缓存字段取当前事件值，并更新latestContextTokens，避免将同一请求的每个累计SSE片段再次相加。Agent loop在每次请求返回后再累计会话统计。不能将max聚合器直接用于所有请求的总消费，也不能把最后一次上下文输入当整轮费用。

recordContextUsage核对session、history、请求revision、实际stream entry和配置身份后发布快照；身份不匹配时保持未知或符合身份条件的上次有效值。这里的门禁不意味着已发生的token/费用应被丢弃。缺失用量或非正常返回路径的会话总数可能不完整，不能将它称为Provider实际账单。

DeepSeekRequestUsage.parse要求官方支持的endpoint/model，并读取响应的总输入`prompt_tokens`（Responses为`input_tokens`）、输出及缓存命中数cached。它要求合法非负整数、cached不超过总输入；存在miss字段时核对`miss = 总输入 - cached`。解析后的`DeepSeekRequestUsage.inputTokens = 总输入 - cached`表示新输入，cacheReadTokens保存cached并单独计价，不能将原始总输入与缓存再相加收费。Responses使用input_tokens/output_tokens及对应details；缺失cache或字段不一致返回nil，保持未计价，不猜测零缓存。

## 会话账本与未知状态

SessionCostLedger只在本机新建会话时enroll；旧会话、云端导入或备份恢复的会话不因读取统计而自动登记。不用当前价格重新估算旧消息。每个请求用独立UUID绑定session：begin增加request_count与unpriced_count，finish在该请求首次成功保存record时更新总额并减少未计价计数；重复finish不能重复收费。

SSEStream在开始处理请求时登记，保留最后一次billingUsage，只有没有stream错误且取得stopReason才尝试finish计价。取消、中断、无完整用量、日期/模型/价格不支持均保持未计价；重试创建新请求，不回滚前一次记录。已有费用不随消息编辑、截断或Retry撤销，因为消费与聊天展示生命周期不同；会话删除通过外键级联删除本地账本。

estimatedAmountCNY只有unpricedCount为零时可用；存在任一未计价请求，已知部分合计不能冒充会话总费用。数据库写入失败由ChatStore的try?/false路径处理，尚无完整持久化失败UI保证；不能仅因界面没有错误而确认账本完整。

当前记录保存request/model、金额、priceVersion、开始/结束时间、tokens、priceTier及start时间依据，没有独立instance/entry字段。会话可以跨实例累计；该账本不是账号分账或所有Provider统一归因已完成的证明。补齐请求当时身份及历史迁移策略仍待决定，参见[Provider用量身份要求](ios-provider-model-routing.md#配置变化和用量归因)。

## 价格快照与适用范围

DeepSeekPricing支持源码列出的flash/pro模型别名和HTTPS api.deepseek.com允许路径（根或/v1，可使用443端口），拒绝其他域名、代理、Azure或仅名字相似的兼容服务。实例还需启用、API key类型、OpenAI/OpenAI Responses路由且非azureMode，才能成为当前费用/余额展示账号。

源码priceVersion为2026-09-29，按Asia/Shanghai和请求开始时刻选择峰闲档位，跨档请求保存start依据。估算只覆盖2026年及各模型价格生效后，未核实调休日期等返回nil；开始/结束年份或时间关系不满足条件同样不估算。它不是对未来年份、官方当前价格或服务跨档结算方式的承诺。

金额以Decimal存储，已保存请求保留原金额和版本，不因后续费率变化重算。标题生成、compaction、浏览器/MCP及其他工具服务不在这个聊天请求账本中；不能宣称展示值包含账号全部消费。

## 账户余额、鉴权与缓存

DeepSeekAccountIdentity为providerID加configRevision/authRevision，Keychain读取再次确认当前身份。查询固定GET `https://api.deepseek.com/user/balance`，Bearer鉴权，拒绝重定向；ephemeral会话无cookie/url cache，request/resource超时为12/15秒，实际流式读取最多16,384字节。独立decode另有64 KB上限，不应将它冒称网络客户端的实际上限。

只接受唯一合法CNY total_balance；没有CNY、重复CNY或畸形数值均失败。`is_available=false`不意味着余额为零；合法零值和负余额可以展示，不能从“不能推理”反推余额未知或为空。

页面状态只缓存一个身份，非强制刷新60秒内复用，手动刷新重新请求。身份变化先清旧值，generation拒绝迟到响应；刷新失败清除旧余额，不继续当实时值。页面task负责取消，取消不应发布迟到结果或误报普通查询失败。没有后台轮询，不用会话消费倒扣缓存余额。

## 展示与持久化边界

当前费用界面受deepSeekAccountIdentity控制；当前身份不支持时即使会话账本已有旧估算，也显示“—”。已登记且当前身份支持的空会话可以显示零；旧会话无summary不冒称完整费用。正数低于0.0001 CNY显示`<¥0.0001`，其他金额格式化到2—4位小数，展示舍入不修改账本原Decimal。

UsageStatsView区分有消息身份快照、旧记录按当前会话模型推测、模型已删除及会话未知等归因状态。按modelId聚合不是严格账号/实例分账；有快照不代表金额或远端账单已经核对。当前session token聚合、历史消息统计与费用账本可以因覆盖范围不同而不相等，不能为了让数字相等抹掉消费或填造身份。

费用账本为本地专用表，当前新格式聊天备份/同步没有相应费用记录字段；恢复聊天不保证恢复费用完整性。保留与清除策略、旧会话追溯和跨设备费用合并仍待维护者决定，格式事务由[备份](ios-backup-restore.md)与[同步](ios-sync-and-conflict-resolution.md)维护。

## 资源边界

请求begin/finish各执行有界数据库写入，总额读取不随流式片段扫描全部账本；余额按页面和身份缓存，不逐token刷新或后台轮询。输出格式化、全局UsageStats聚合和消息重载仍需按[资源规范](resource-efficiency.md)定向验证；本轮没有性能实测。余额网络字节限制不代表其他Provider流式响应同样受限。

## 场景与验收

以下条件尚未在本轮运行，测试源码存在不等于已通过。

| 场景与前提 | 可观察验收 |
| --- | --- |
| 新会话一次回答含两次工具后的三次模型请求 | 每请求仅登记一次，全部完整可估算才展示总额；最后上下文占用不等于三请求消费之和。 |
| 同一请求多次累计SSE usage | 片段不重复相加；总prompt拆为fresh和cache，和miss一致，缺失字段保持未知。 |
| 中断后Retry；重复finish；消息截断 | 中断请求保持未计价，新请求独立；已记金额不重复、不随消息回滚；会话总额未知提示正确。 |
| 老会话或云端/备份导入会话 | 不凭读取建立完整账本，不按当前费率回算为已核实费用。 |
| 请求期间切模型/实例/Key | 上下文快照符合当前身份；旧消费仍保留其原金额；余额旧响应不能覆盖新身份，账本instance归因缺口保留。 |
| 代理服务同名DeepSeek模型、未支持年份/日期 | 显示不可估算/“—”，不套用源码快照生成官方账单。 |
| 余额超时、取消、重复CNY及负数 | 失败清旧值、取消不发布；重复币种拒绝，合法负值不改为零。 |
| 关闭费用页面再打开或刷新 | 无后台轮询，生命周期取消与60秒缓存/强制刷新按实际触发检查。 |

## 测试入口与未决事项

[DeepSeekBillingTests](../../src/ios/MinisTests/DeepSeekBillingTests.swift)、[SessionCostLedgerTests](../../src/ios/MinisTests/SessionCostLedgerTests.swift)、[DeepSeekBalanceModelTests](../../src/ios/MinisTests/DeepSeekBalanceModelTests.swift)和[ContextUsageTests](../../src/ios/MinisTests/ContextUsageTests.swift)提供价格、字段、数据库及身份门禁的测试入口。本轮未执行，没有新官方请求、真机或账单对照证据；不引用旧测试通过证明当前工作区。

待决定：未计价请求长期显示方式、实例级分账、费用本地保留/同步/备份、旧会话追溯、价格更新及跨档服务依据。本文不因缺口而修改产品实现，也不将估算升级为扣费保证。
