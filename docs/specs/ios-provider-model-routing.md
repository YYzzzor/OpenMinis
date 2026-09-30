---
description: MinisX iOS Provider 实例、模型条目、会话绑定、模型组路由、fallback、凭证与实际用量身份规范。
---

# MinisX iOS Provider 与模型路由

导航：[Spec 索引](index.md)；运行中的 Retry/Resume 和 Agent loop 见 [iOS Agent 运行生命周期](ios-agent-run-lifecycle.md)；配置跨设备传播见 [iOS 同步与冲突处理](ios-sync-and-conflict-resolution.md)。

状态：现行路由约定与 2026-09-29 当前实现并列记录。主要证据为 [ProviderInstance.swift](../../src/ios/Providers/ProviderInstance.swift)、[ProviderConfigStore.swift](../../src/ios/Providers/ProviderConfigStore.swift)、[ModelGroup.swift](../../src/ios/Providers/ModelGroup.swift)、[ModelGroupRouter.swift](../../src/ios/Providers/ModelGroupRouter.swift)、[LLMTypes.swift](../../src/ios/Providers/LLMTypes.swift)、[AIChatViewModel+ProviderFactory.swift](../../src/ios/Agent/Chat/AIChatViewModel+ProviderFactory.swift) 和 [AIChatViewModel+Fallback.swift](../../src/ios/Agent/Chat/AIChatViewModel+Fallback.swift)。本轮没有向任何 Provider 发请求。

## 身份模型

- **ProviderInstance**：一个具体账号/端点配置。相同 provider type 可以有多个实例；实例拥有启用状态、凭证类型、可选 base URL 和实例级协议选项。
- **ModelEntry**：某实例下的一个模型配置。路由身份必须包含实例与模型，不能只用 model id 区分两个账号或端点。
- **ModelGroup**：有序的 ModelEntry 引用集合，策略为 fallback 或 load balance，可有默认 thinking 与 context limit。
- **SessionModelBinding**：会话的 primary source，以及可选 sub-model source；source 可以是直接 entry，也可以是 group 加当前 resolved entry。

展示名、model id 和可执行身份不是同一概念。持久化、统计、fallback 和错误提示需要能回答“实际使用了哪个实例的哪个 entry”，不能只报告同名模型。

## 可用性与凭证

模型组候选只有在以下条件同时满足时可路由：entry 存在且未隐藏；所属实例存在且启用；本设备有当前凭证类型可用的凭证。缺凭证候选显示为不可用并跳过，不应先让请求 401/403 再把它当正常 fallback。

Provider 元数据可以通过同步到达另一台设备，但 Keychain/OAuth token 的设备可用性必须单独判断。看到实例和模型条目不等于该设备可发送请求。未知的新版 provider type 当前可无损保留 raw value 并视为 unsupported，旧客户端不得把它重写成另一个 provider。

创建 provider 必须使用 entry 所属实例的凭证、端点和协议模式。自定义 endpoint、OAuth 和 API key 的鉴权不能互换；凭证改变后需要使可用性缓存和配置 revision 失效。

## 直接绑定和组绑定

直接选择模型时，session binding 保存 entry 引用及兼容用 composite key。目标 entry 被删除时，调用方应明确进入重新选择/默认回退，而不是静默把同名 model id 绑定到任意实例。

组绑定保存 group id 和当前 resolved entry。group 成员顺序或可用性改变后允许重新解析；成功 fallback 到不同 entry 时，应把新的 resolved entry 写回 binding，并同步会话的 model id 显示字段。sub-model 选择独立于 primary；未显式设置 sub-model 时，标题生成等轻量任务当前优先沿用会话 primary，而不是偷偷跳到全局默认。

## 初始路由

### Fallback 组

初始选择第一个可用成员。每个 reasoning turn 最多尝试每个当前可用成员一次；从当前成员向后并可环绕，但 `triedEntries` 防止同一轮无限循环。成员缺失、隐藏、实例禁用或缺凭证不消耗请求尝试，应在最终错误中给出跳过原因。

### Load-balance 组

当前 `ModelGroupRouter` 使用 `abs(sessionId.hashValue) % available.count` 选初始成员。这个实现能在同一进程和同一候选集合内按 session 分散，但 Swift `hashValue` 不提供跨进程永久稳定承诺；成员集合变化也会改变映射。

因此现行可承诺的是“按会话在可用成员间分散并保存当前 resolved entry”，不能写成“同一会话跨重启永远命中同一模型”。是否需要稳定哈希或严格 sticky routing 是待维护者确认的产品语义。

## 错误重试与 fallback

`FallbackStrategy.limited`：Provider 级可 fallback 错误（如限流、无效凭证、Provider 拒绝）立即尝试下一成员；网络/暂时错误先在当前成员自动重试，重试耗尽后再换成员。

`FallbackStrategy.always`：任何错误都立即换成员，不先在当前成员倒计时重试。

每次换 entry 必须：

- 用新 entry 的模型能力重新计算 max tokens 与 thinking 上限；
- 在发请求前 clamp thinking level，成功后必要时回写会话配置；
- 用新模型的 capability/behavior fragment 重建 system prompt；
- 成功打开 stream 后记录实际 entry，而不是仍归因给初始 entry；
- 不删除前面已提交的 assistant/tool 内容。

若用户在自动重试倒计时中改变模型，当前实现会重新读取 binding。当前上下文占用快照无法可靠确认实际 entry 时必须保持未知或符合身份条件的上次有效值，不能猜一个身份；历史实际消费不因当前身份变化而自动丢弃，见[配置变化和用量归因](#配置变化和用量归因)。

## 配置变化和用量归因

这里区分当前上下文占用和历史消费；同一次响应的不同数值不能套用同一发布门禁。[用量、费用与余额](ios-usage-cost-and-balance.md)独立维护字段完整性、请求账本、估算支持范围和账户查询，本节只规定路由身份关联。

| 数值 | 当前实现与维护要求 |
|---|---|
| 当前上下文占用快照 | `recordContextUsage` 使用 `latestContextTokens`，核对请求、实际 stream entry、配置及当前身份；不匹配时不能覆盖当前模型快照。记录 stream 身份和 revision 的门禁适用于这一快照。 |
| 会话 token 累计 | Agent loop 对每次正常返回的 streamResult 累计已观察的 input/output/cache token；异常或缺失用量不代表消费为零，也不是完整账单；不共用上述快照门禁。配置改变不能成为抹掉已发生消费的理由。累计值不等于某个当前 entry 的上下文占用。 |
| 会话费用估算 | 当前 [AIChatViewModel+Billing.swift](../../src/ios/Agent/Chat/AIChatViewModel+Billing.swift) 以 session/request id 记录已完成且有可估算用量的 DeepSeek 请求；不使用上下文快照的 revision 门禁。账本不是所有 Provider 已有统一 entry 归因的证明，也不是整个账号账单。 |
| 账户余额 | 当前余额入口单独使用 Provider 实例、配置和鉴权 revision 判断账号身份；它是账号查询状态，不由会话 token 或费用累计推导。请求失败或身份无法确认时不能显示猜测余额。 |

源码边界见 [AIChatViewModel.swift](../../src/ios/Agent/Chat/AIChatViewModel.swift) 的 `recordContextUsage` 与响应后的会话统计，以及上述 Billing 路径。请求配置变化后的快照发布、累计和费用记账需要分别验证；本轮未发送请求，不将静态分支视为正确归因的运行证据。

模型组 fallback 成功后，UI 的当前模型、session binding、持久化 model id 和后续请求起点应一致。仅更新显示文字或只更新数据库其中一处都不合格。

现行身份要求：同名模型跨实例的账号余额、限流和错误不能因 model id 相同而混为一个身份。会话可以汇总多个请求的消费，但汇总不能冒充某个账号余额。后续完善账本归因时，应使用请求当时捕获的实际 entry/instance；不能在响应结束时按当前 binding 猜旧请求身份，也不能把这一要求写成所有现有账本均已实现。

## 同步冲突与删除

Provider V3 同步分别保存 instance、entry、group 和 thinking rule。普通标量按更新时间 LWW；group 成员使用每成员 add/remove 时间合并并发意图。删除 instance/entry/group 后，session binding 可能成为悬空引用；解析层必须检测并重新选择或返回明确无可用模型，不能崩溃或悄悄使用无凭证实例。

## 场景与验收

### 场景 A：两个同名模型来自不同账号

用户绑定账号 B 的 entry 后，请求、错误、用量和后续 fallback 都保留 B 的 instance 身份；界面不能只显示 model id 后实际发送到账号 A。

### 场景 B：组首成员缺凭证

首成员在本设备没有凭证，第二成员可用。初始路由直接选择第二成员；最终错误或诊断说明首成员因缺凭证跳过，没有先产生一次认证失败请求。

### 场景 C：limited 策略遇到网络错误

先对当前 entry 按自动重试策略处理；耗尽后才尝试下一个未尝试成员。成功后 binding、显示和实际用量身份更新为成功 entry。

### 场景 D：always 策略遇到任意错误

不等待当前 entry 的自动重试倒计时，立即尝试下一成员；一轮内每个可用 entry 最多一次，耗尽后给出各成员失败/跳过原因。

### 场景 E：请求期间修改配置

旧请求可以完成显示，但迟到结果不得覆盖新配置的上下文占用快照；同时分别核查会话 token 和已完成、可估算请求的费用记录，没有仅因配置变化而被丢弃或记给当前新账号。下一轮按新 binding/凭证重新解析。余额只反映其捕获的账号身份，不能由这些累计数值计算。

## 待验证与待确认

- 待验证：真实 Provider 限流、认证失败、断网重试、stream 中断、fallback 后统计归因，以及 iCloud 同步造成的悬空 binding。
- 待确认：load balance 是否要求跨重启稳定；若要求，当前 `hashValue` 实现不满足，需要稳定哈希或持久 sticky 规则。
- 待确认：当直接绑定 entry 被删除、或组内所有成员不可用时，应强制用户选择、回落默认组，还是保持可恢复错误；当前不同调用路径含有多级 fallback，尚不能提升为统一产品承诺。
