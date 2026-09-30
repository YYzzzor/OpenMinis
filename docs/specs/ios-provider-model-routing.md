---
description: MinisX iOS Provider 实例、模型条目、会话绑定、模型组路由、fallback、凭证与实际用量身份规范。
---

# MinisX iOS Provider 与模型路由

导航：[Spec 索引](index.md)；运行中的 Retry / Resume 与 Agent 循环见 [Agent 运行生命周期](ios-agent-run-lifecycle.md)；配置的跨设备传播见 [同步与冲突处理](ios-sync-and-conflict-resolution.md)。

范围：Provider 实例与模型条目的身份、会话绑定、模型组的初始路由与 fallback、凭证可用性，以及用量归到哪个身份。

## 身份模型

| 概念 | 含义 |
| --- | --- |
| ProviderInstance | 一个具体的账号或端点配置。同一 provider type 可以有多个实例；实例有启用状态、凭证类型、可选的 base URL 和实例级协议选项。 |
| ModelEntry | 某个实例下的一个模型配置。 |
| ModelGroup | 有序的 ModelEntry 引用集合，策略为 fallback 或 load balance，可设默认 thinking 和上下文上限。 |
| SessionModelBinding | 会话的主模型来源和可选的子模型来源；来源可以是具体的 entry，也可以是模型组加上当前解析到的 entry。 |

- **I1** 路由身份由实例和模型共同确定，不能只用 model id 区分两个账号或端点。
- **I2** 显示名、model id、可执行身份是三个不同的概念。持久化、统计、fallback 和错误提示都要能回答“实际用的是哪个实例的哪个 entry”。

## 可用性与凭证

- **A1** 模型组中的候选同时满足以下条件才可路由：entry 存在且未隐藏；所属实例存在且已启用；本设备有该实例凭证类型所需的凭证。缺凭证的候选显示为不可用并被跳过，不先发请求等 401 / 403 再当作普通 fallback。
- **A2** Provider 元数据可以同步到另一台设备，但 Keychain 或 OAuth token 是否在该设备可用要单独判断；看到实例和模型不代表这台设备能发请求。
- **A3** 未知的新版 provider type 原样保留其 raw value 并视为不支持，旧客户端不把它改写成别的 provider。
- **A4** 创建 provider 时使用 entry 所属实例的凭证、端点和协议模式；自定义端点、OAuth、API key 三种鉴权不能互换。凭证变化后，可用性缓存和配置 revision 失效。

## 会话绑定

- **B1** 直接选择模型时，绑定保存 entry 引用及兼容用的组合键。目标 entry 被删除时，明确进入重新选择或默认回退，不把同名 model id 静默绑定到任意实例。
- **B2** 选择模型组时，绑定保存 group id 和当前解析到的 entry。成员顺序或可用性变化后可以重新解析；fallback 成功切到另一个 entry 时，把新 entry 写回绑定，并同步会话的 model id 显示字段。
- **B3** 子模型的选择独立于主模型。未显式设置子模型时，标题生成等轻量任务沿用会话的主模型，而不是全局默认。
- **B4** 实例、entry 或模型组被删除后，绑定可能悬空；解析层检测到后重新选择或明确返回“无可用模型”，不崩溃，也不悄悄使用无凭证的实例。

## 初始路由

- **R1** fallback 组：选择第一个可用成员。
- **R2** load-balance 组：以 `abs(sessionId.hashValue) % 可用成员数` 选择初始成员，并保存解析结果。它能在同一进程内按会话分散请求；但 Swift 的 `hashValue` 每次启动随机，成员集合变化也会改变映射，所以不保证同一会话跨重启命中同一模型（见“待决定”）。

## 重试与 fallback

- **F1** `limited` 策略：Provider 级错误（限流、无效凭证、Provider 拒绝）立即换下一个成员；网络或暂时性错误先在当前成员自动重试，耗尽后再换。
- **F2** `always` 策略：任何错误都立即换成员，不在当前成员上倒计时重试。
- **F3** 每个推理回合中，每个当前可用成员最多尝试一次：从当前成员往后，可以绕回开头，用 `triedEntries` 防止无限循环。缺失、隐藏、实例禁用、缺凭证的成员不消耗尝试次数，并在最终错误中说明跳过原因。
- **F4** 每次换 entry 都要：
  - 按新 entry 的模型能力重新计算 max tokens 和 thinking 上限；
  - 发请求前限制 thinking 级别，成功后必要时写回会话配置；
  - 用新模型的能力与行为片段重建 system prompt；
  - stream 成功打开后记录实际使用的 entry，而不是仍归给最初的 entry；
  - 不删除之前已提交的 assistant 和工具内容。
- **F5** fallback 成功后，界面上的当前模型、会话绑定、持久化的 model id 和后续请求的起点保持一致；只改其中一处不合格。
- **F6** 自动重试倒计时期间用户改了模型，重试时重新读取绑定。

## 配置变化和用量归因

这里区分“当前上下文占用”和“已发生的消费”：同一次响应的不同数值不套用同一套发布门禁。字段完整性、请求账本、估算范围、账户查询见 [用量、费用与余额](ios-usage-cost-and-balance.md)，本节只规定与路由身份的关系。

| 数值 | 规则 |
| --- | --- |
| 当前上下文占用快照 | `recordContextUsage` 核对请求、实际的 stream entry、配置和当前身份，不匹配时不覆盖当前模型的快照；身份无法确认时保持未知或符合条件的上次有效值，不猜测身份。 |
| 会话 token 累计 | 每次正常返回都累计已观察到的 input / output / cache token，不受上述快照门禁约束；配置改变不是抹掉已发生消费的理由。缺失或异常的用量不代表消费为零。 |
| 会话费用估算 | 按会话和请求 id 记录已完成、可估算的 DeepSeek 请求，不使用快照的 revision 门禁；它不是整个账号的账单。 |
| 账户余额 | 用 Provider 实例、配置 revision、鉴权 revision 判断账号身份；不从 token 或费用累计推算。请求失败或身份无法确认时不显示猜测的余额。 |

- **U1** 同名模型跨实例时，余额、限流和错误不因 model id 相同而混为一个身份；会话可以汇总多个请求的消费，但汇总不能冒充某个账号的余额。
- **U2** 用量归因使用请求当时捕获的实际 entry 和实例，不在响应结束时按当前绑定去猜旧请求的身份（账本现状见用量 Spec 的待决定）。

## 同步

- **S1** Provider V3 同步分别保存实例、entry、模型组和 thinking 规则。普通字段按更新时间后写者胜（LWW）；模型组成员按每个成员的添加与移除时间合并并发修改。

## 待决定

- [待决定] load-balance 是否需要跨重启稳定；若需要，当前 `hashValue` 实现不满足，要改用稳定哈希或持久的 sticky 规则（R2）。
- [待决定] 直接绑定的 entry 被删除、或模型组内所有成员都不可用时，是强制用户重新选择、回落到默认组，还是保持可恢复的错误。目前不同调用路径有多级回退，尚未统一（B1、B4）。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 两个账号下有同名模型，会话绑定到账号 B 的 entry | 请求、错误、用量和后续 fallback 都保留 B 的实例身份，不会显示 B 却实际发给 A（I1、U1） |
| 模型组首个成员在本设备缺凭证，第二个可用 | 直接选第二个成员；最终错误或诊断说明首个成员因缺凭证被跳过，没有先产生一次认证失败的请求（A1、F3） |
| `limited` 策略遇到网络错误 | 先在当前 entry 上自动重试，耗尽后才换下一个未尝试的成员；成功后绑定、显示和用量身份更新为成功的 entry（F1、F4、F5） |
| `always` 策略遇到任意错误 | 不等倒计时，立即换下一个成员；一轮内每个可用 entry 最多一次，耗尽后给出每个成员失败或被跳过的原因（F2、F3） |
| 请求期间修改配置 | 旧请求可以显示完成，但迟到的结果不覆盖新配置的上下文快照；会话 token 和已完成请求的费用照常记录，不因配置变化而丢弃，也不记到新账号上；下一轮按新的绑定和凭证重新解析（U2、A4） |

## 代码入口

- 身份与存储：[ProviderInstance](../../src/ios/Providers/ProviderInstance.swift)、[ProviderConfigStore](../../src/ios/Providers/ProviderConfigStore.swift)、[LLMTypes](../../src/ios/Providers/LLMTypes.swift)
- 模型组与路由：[ModelGroup](../../src/ios/Providers/ModelGroup.swift)、[ModelGroupRouter](../../src/ios/Providers/ModelGroupRouter.swift)
- 创建 provider 与 fallback：[ProviderFactory](../../src/ios/Agent/Chat/AIChatViewModel+ProviderFactory.swift)、[Fallback](../../src/ios/Agent/Chat/AIChatViewModel+Fallback.swift)
- 用量：[AIChatViewModel](../../src/ios/Agent/Chat/AIChatViewModel.swift)（`recordContextUsage`）、[Billing](../../src/ios/Agent/Chat/AIChatViewModel+Billing.swift)
