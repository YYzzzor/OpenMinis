# Retry Thinking 与测试修复审核

## 目标

审查本轮围绕 “Retry 后可能出现重复 Thinking bubble” 的实现核查、回归测试，以及为解除 `MinisTests` 编译阻断所做的最小测试导入修复。不顺便重构生产代码。

## 已确认的实现边界

- 当前生产代码已经在 Retry、自动重试和 fallback 清理路径中删除未提交的 Thinking block。
- 本轮新增回归测试，通过真实 `retry()` 入口和 `processStreamEvents` 锁定“失败流 Thinking 被 Retry 流替换”的行为，并验证已提交前缀不会被清理。
- Pi 复审指出 fallback 提示插到消息首部时可能令当前和上一轮两个绝对下标落后一个位置；本轮同步移动 `committedBlockCount` 与 `prevCommittedBlockCount`，避免后续 Retry 或 Stop 误删、重复提交已完成内容。
- 队列切换到新的 assistant 消息时同时重置两个提交游标。清理函数只按消息内可用范围收紧边界，避免错误处理删掉空文本后游标暂时大于块数时误删已提交内容。
- Retry 清理完成后，以实际保留下来的块数同步当前和上一轮提交游标，避免用户在 Retry 的首个新流中点击 Stop 时重复提交或误删旧内容。
- Resume 与从消息/工具 regenerate 也在进入新流前同步两个游标；恢复的历史会话在用户点击 Resume 时经过同一同步，保证所有复用或新建 assistant 消息的入口遵守同一边界规则。
- `ToolPreflightTests.swift` 原先缺少 `@testable import Minis`，导致无法解析 App 模块内的测试对象；本轮只补充该导入。

## 验收条件

- Retry 前删除失败流产生的未提交 Thinking 和部分文本，下一次流只创建一个新的 Thinking block。
- 已提交的 Thinking、文本和终态工具结果不被误删。
- 运行时代码只修改 Retry/Resume/regenerate、队列切换、fallback 前插和 Stop 清理涉及的消息提交边界；不改动 provider 协议、stream event 解析或其他功能。
- `ToolPreflightTests` 能编译并通过，不通过扩大生产类型可见性来绕过问题。
- `RetryThinkingBlockTests` 与 `ToolPreflightTests` 定向测试通过。

## 已执行验证

- `RetryThinkingBlockTests`：4 个测试通过；其中入口级测试真实调用 `retry()` 清理失败尾部，并通过 `processStreamEvents` 驱动失败流和替换流；新增 fallback 前插与边界超出块数测试，验证两个提交边界同步移动，且错误清理删掉空文本后不会误删已提交内容。
- `ToolPreflightTests`：9 个测试通过。
- 上述两组定向测试合计 13 个，全部通过。
- 完整 `MinisTests` 已能编译和执行：192 个测试中 188 个通过；4 个既有 `ToolLoopDetectorTests` 测试用例共 6 个断言失败。失败集合与修改前一致，本轮未修改其实现或测试。
- `git diff --check` 通过。

## 未验证范围

- 未通过真实模型提供商注入网络中断来做 Retry 端到端测试；已用可控 `AsyncThrowingStream` 覆盖真实 Retry 清理入口和消息事件处理链。
- 完整测试套件尚未全绿，剩余失败集中在 `ToolLoopDetectorTests`。

## Pi 审核处理

- DeepSeek Pi 对最终快照给出 `nonblocking` 结论；报告归档于 `reviews/002`。
- 采纳其低风险意见：Retry 清理完成后同步 `committedBlockCount` 与 `prevCommittedBlockCount`，覆盖 Retry 首个新流中点击 Stop 的时序。
- 未采纳“Stop 后保留仅含 fallback 提示的占位消息”：没有模型文本或工具内容时删除整条占位消息是修改前既有行为，本轮保持该语义，避免扩大范围。
