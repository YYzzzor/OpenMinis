# Pi 审核处理记录

## 审核标识

- Snapshot: `bfd367e01921b0050af0257b49b782ad478f12f8b059a0c6e723be5b87e34f6b`
- Reviewer: DeepSeek `deepseek-v4-flash` via project Harness
- Pi 建议结论: `nonblocking`
- 主 Agent 验收判断: 本轮两项代码改动可接受；保留一个既有 Retry 文本边界风险和完整测试套件未全绿的明确限制。

## R1 — 接受为测试范围限制，不追加改动

Pi 正确指出 `RetryThinkingBlockTests` 直接测试 `clearUncommittedStreamTail`，并用手工追加 Thinking block 模拟新流，没有实际驱动 `retry()`、自动重试、fallback 或 SSE provider。

本轮目标是为当前已经存在的最小运行时修复补回归保护。helper 测试已经锁定“失败流 Thinking 被删、已提交前缀保留”的核心不变量；生产调用点另经静态检查确认均复用该 helper。完整网络断流端到端测试需要可注入 provider/stream，属于更大的测试基础设施工作，不在本轮扩展。

验证：`RetryThinkingBlockTests` 2/2 通过。

## R2 — 待单独核实，不在本轮修改

Pi 指出的注释与代码差异成立：`retry()` 的旧注释声称 helper 总会保留非空文本，但 helper 实际以 `committedBlockCount` 为唯一提交边界，并删除边界后的所有 text/thinking block。如果该计数确实落后于已持久化内容，可能误删界面中的已提交文本。

这不是本轮新增行为；相关代码和注释均来自当前基线。现有主循环在成功提交每轮 blocks 后会更新本地及实例 `committedBlockCount`，因此 Pi 无法确认“计数落后”是否仍可真实发生。贸然改为保留所有非空 tail text 会保留失败流的部分回答，并可能在新流开始后造成重复文本，不能作为安全的顺手修复。

处理：保留为独立待核实风险。如要处理，应另开任务构造可复现的计数落后场景，再决定修复提交边界还是清理策略。

## R3 — 接受并以本地执行结果确认

完整 `MinisTests` 已在 iOS 27.0 模拟器实际执行：192 个测试中 188 个通过、4 个失败。失败均位于 `ToolLoopDetectorTests`：

- `testArgsHash_ignoresToolTitle`
- `testArgsHash_keyOrderInvariant`
- `testGlobalCircuitBreaker_blocksAtThirty`
- `testPollNoProgress_warningAtTenCriticalAtTwenty`

本轮生产逻辑未改；`@testable import Minis` 是 Swift 文件级导入，只作用于 `ToolPreflightTests.swift`。上述测试直接构造纯 `ToolLoopDetector`，静态依赖与本轮改动无交集，因此确认属于另一个既有问题，不在本轮修复。

验证：`ToolPreflightTests` 9/9、`RetryThinkingBlockTests` 2/2 通过；`git diff --check` 通过。
