---
description: iOS Agent 从发送、流式响应和工具循环到停止、重试、恢复、持久化、上下文压缩及会话删除的生命周期契约。
---

# iOS Agent Run Lifecycle

导航：[Spec 索引](index.md)。

状态：现行用户可见契约与当前实现说明。本文规范一次会话 turn 如何开始、推进、持久化、中断和恢复；Provider 特有传输与模型路由细节不在本文展开。

## 适用范围与来源

适用于聊天发送、编辑重发、流式显示、工具调用、Stop、Retry、Resume、上下文 offload/compact、App 后台恢复和会话删除。

主要源码依据：

- [AIChatViewModel.swift](../../src/ios/Agent/Chat/AIChatViewModel.swift)：send/retry/resume/cancel 和 agent loop。
- [AIChatViewModel+ConcurrentTools.swift](../../src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift)：工具批次执行。
- [AIChatViewModel+Compaction.swift](../../src/ios/Agent/Chat/AIChatViewModel+Compaction.swift)：上下文压缩与恢复。
- [ContextPolicy.swift](../../src/ios/Agent/Chat/ContextPolicy.swift)：窗口阈值。
- [ChatStore.swift](../../src/ios/Agent/Chat/ChatStore.swift)：会话、消息、compact marker 和删除 tombstone。

本轮为静态核对，没有运行 Provider、后台、同步或设备中断场景。

## 生命周期总览

```text
草稿/附件
  → 发送前校验与上下文检查
  → 建立/载入会话并持久化用户 turn
  → Provider 流式响应
  → 零个或多个工具批次与后续模型轮次
  → 正常完成 / 错误 / 用户停止 / 上下文耗尽 / 轮次上限
  → Retry、Resume 或从历史 user message 重跑
```

UI 消息、Provider history 和数据库记录是相关但不同的表示。任何编辑、重试或压缩都必须保持三者的顺序和边界一致，不能只修屏幕显示。

## 发送前提

`send()` 当前在以下情况不开始新 turn：远端只读会话、文本与已就绪附件都为空、或当前正在 processing。未完成/失败附件会从待发送集合剔除；真正发送时才提交输入模式等“已使用”偏好。

开始前必须：

- 对编辑重发使旧上下文用量失效；
- 检查上下文策略；
- 清理旧的 streaming/running 工具视觉状态；
- 同步清空 composer 草稿并建立用户消息；
- 确保会话、kernel 和后台处理上下文可用；
- 获取会话并发槽后才进入 Agent loop。

编辑已有 user message 后发送会截断它及后续 UI/history/持久化消息，然后以编辑后的 turn 继续。这是破坏后续分支的操作，UI 必须让用户理解其范围。

## 上下文检查与压缩

当前 [ContextPolicy.swift](../../src/ios/Agent/Chat/ContextPolicy.swift) 按模型窗口分层：

| Context window | 自动 offload | 自动 compact | 达到上限 |
|---|---|---|---|
| `<32K` | 无 | 无 | 约 90% 时 exhausted |
| `32K–<64K` | 剩余约 10K | 无 | 到 offload threshold 时 exhausted |
| `64K–<128K` | 剩余约 20K | 剩余约 10K | compact 路径 |
| `>=128K` | 剩余约 40K | 剩余约 20K | compact 路径 |

发送前需要 compact 时，Shortcut 会话或开启 auto compact 的会话自动执行；其他交互会话先提示。Exhausted 时，Shortcut 产生内联错误，交互会话提示新建会话或清空。

Agent loop 每轮还会重新检查：先 offload 大工具内容，再决定 in-loop compact 或停止为可恢复状态。单个 user turn 最多 3 次 in-loop auto compact；该数值和阈值是当前实现，可随产品策略修订，但修改必须同步测试和用户提示。

Compact 以 summary 替代较早的有效 history，同时持久化 marker；UI 可以保留灰化历史和 divider。它不是删除原记录的同义词，也不能破坏工具调用/结果配对。

## 流式响应与工具循环

- 每个 Agent loop 先解析当前 Provider 和可用工具；没有模型配置时显示可见错误并结束。
- 流式内容写入同一个 assistant turn；已提交 block 与未提交流式尾部必须可区分。
- 模型返回工具调用时，工具结果以与 tool use 匹配的 id 回写 history，再进入下一轮模型请求。
- 同批工具当前可以并发执行，因此结果完成顺序不应当被当成声明顺序；组装回模型和 UI 时必须恢复确定的对应关系。
- `ToolLoopDetector` 用于识别重复循环，另有每个 user turn 最多 200 个 Agent loop 迭代的硬上限。到达硬上限必须产生用户可见、可恢复的停止状态，不能无限运行。
- 一次工具结果后的空模型响应可以进行一次带提醒的恢复尝试；仍为空则显式失败，不得静默结束或无限重试。
- Provider 自动重试/组 fallback 只能清理未提交的流式尾部，不能抹掉已提交、已持久化的旧 block。

## 持久化与恢复重建

- 新草稿在首次发送时惰性建立 session，再写入消息。
- 消息读取顺序以 `sort_order ASC, created_at ASC, id ASC` 为确定顺序。
- 错误信息当前为设备本地字段；Retry 清除内存错误时也必须清除对应持久错误，避免重载后旧 banner 复现。
- 工具 use/result、stream interrupt count、模型/Provider 标识和 compact marker 必须足以让会话重载后重建可见状态和有效 Provider history。
- 同步或 reload 可能替换 UI message 实例；运行中的 loop 应以稳定 id 重新定位目标 assistant message，而不是长期持有可能失效的数组下标。
- 孤立 tool result 应移除；孤立 tool use 需要明确的失败占位，避免下一次 Provider 请求因协议不完整失败。

历史测试或已有容错路径不能证明杀进程、跨设备同步和后台回收场景已通过；这些仍需运行验证。

## Stop、Retry、Resume 与历史重跑

### Stop

用户 Stop 应立即让 UI 离开 processing，并：

- 取消并发槽等待和当前 Task；
- 终止该会话的 shell 进程；
- 唤醒前台等待或浏览器 takeover continuation，使取消可以传播；
- 停止自动重试/倒计时和后台处理；
- 将未完成工具转为可理解的中断状态，并在适用时提供 Resume。

Stop 不应删除已经提交的文本/终端结果，也不保证撤销工具已经产生的外部副作用。排队中的 prompt 是否继续按产品队列语义处理，不能与被停止的当前 turn 混成同一条响应。

### Retry 当前失败轮次

`retry()` 只在未 processing 且最后一条为 assistant 时开始。它保留已经完成的工具 block 和对话历史，清除失败轮次未提交的流式尾部、旧错误和孤立结果，然后从最后提交边界继续。它不是“从头重发整段会话”。

### Resume 用户中断

`resume()` 要求 `canResume` 且未 processing：

- 若尾部是部分 assistant turn，保留已提交内容，清理未提交尾部；history 以 assistant 结尾时注入仅供模型理解的 Continue reminder，然后继续同一 assistant 消息。
- 若尾部只有已持久化 user message、尚无任何 assistant row，则从该 user turn 重新请求答复，而不是假装存在部分回复。

### 从历史 user message 重跑

`retryFromMessage` 保留选中的 user message，截断它之后的 UI、Provider history 和数据库记录，再运行新的分支；替换附件时同步更新对应 history 和展示元数据。若 UI 与 history 找不到安全锚点，当前策略是 fail open 保留更多历史，而不是误删大段会话。

## 会话删除

删除会话时，当前实现先排队云端 session/child 删除，再删除本地消息、compact marker 和媒体，并记录 30 天本地 recent-delete tombstone，防止旧的云记录在删除传播完成前把会话复活。

删除是数据生命周期行为，不等于仅从列表隐藏。调用方还应停止该会话活动、清理 badge/live activity/缓存和文件路由；跨设备最终删除仍需同步验证。

## 场景与验收

### 场景 A：正常文本与工具 turn

可观察验收：user message 先持久化；assistant 流式显示；工具 use/result id 配对；最终文本和工具 block 重载后顺序一致；processing 和后台状态在结束后清零。

### 场景 B：工具运行中 Stop 后 Resume

可观察验收：Stop 能终止该会话所有 shell PID；已提交文本/终端结果保留；运行中 block 显示中断而非永久 loading；Resume 不重复已经确认完成的工具副作用，并继续到同一 assistant turn。

### 场景 C：错误后 Retry

可观察验收：旧错误 banner 在内存和数据库均清除；已完成工具结果不消失；只丢弃未提交流式尾部；重载会话不重新出现已清除错误。

### 场景 D：从旧 user message 重跑

可观察验收：所选 user message 保留，之后的分支在 UI/history/数据库三处一致删除；新附件替换正确；同步 reload 不在截断窗口恢复旧分支。

### 场景 E：上下文逼近上限

可观察验收：按模型窗口选择 offload/compact/exhausted；非自动 compact 的交互会话先提示；单 turn 不超过 3 次 in-loop compact 和 200 轮硬上限；达到上限时给出可见恢复入口。

### 场景 F：App 在 user message 后被回收

可观察验收：重载后识别“尾部 user 无 assistant”并提供恢复；恢复从该 user turn 请求，不插入伪造的部分 assistant 内容。

## 发现信息与持久背景知识

初始Agent loop和Provider fallback重建时组装Skill/MCP发现信息及按memoryEnabled控制的GLOBAL/近期日志。发现列表不代表正文已读取、MCP工具已执行或模型已正确遵守。Skill/MCP会话开关目前不是全面执行许可，Memory关闭不清除既有工具历史或阻止一般文件路径；SOUL身份部分不受该开关控制。

具体范围及冲突由[Skill生命周期](ios-skills-lifecycle.md)、[MCP集成](ios-mcp-integrations.md)和[Memory生命周期](ios-memory-lifecycle.md)维护；本节不把开关切换、消息截断、清空会话或Retry解释为全局数据删除和撤销已发生的副作用。费用请求在消息展示之外单独记账，详见[用量与费用](ios-usage-cost-and-balance.md#账本规则)。

## 待验证与待确认

- 待验证：真机后台回收、并发工具 Stop、Provider 中途断流、iCloud reload 竞态、200 轮上限和多次 in-loop compact。
- 待维护者确认：排队 prompt 在 Stop 后继续还是全部取消的最终产品语义；当前实现包含继续排队的路径，不能仅凭代码视为已确认体验。
- 相关现存规范：[Provider 与模型路由](ios-provider-model-routing.md)说明实例身份、fallback 和用量边界；[语音输入生命周期](ios-voice-input-lifecycle.md)说明采集与草稿编辑发送；[同步与冲突处理](ios-sync-and-conflict-resolution.md)说明队列、合并和删除传播。本文通过这些关联划分职责，不重复其细节。
