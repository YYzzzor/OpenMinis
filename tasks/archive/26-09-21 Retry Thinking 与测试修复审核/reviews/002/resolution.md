# Pi 最终审核处理记录

## 审核标识

- Snapshot: `8702a62ee458a552340d95a7a26d1bbbce4bd01d841f3cdd4f6e7da01052fa95`
- Reviewer: DeepSeek `deepseek-v4-flash` via project Harness
- Pi 结论: `nonblocking`
- 主 Agent 验收判断: 无阻断问题；实现可接受，保留真实 provider 网络中断和 Stop 精确时序未做端到端自动化覆盖的限制。

## R1 — 接受并修正文档

验收条件原先只写了 fallback 前插边界，但最终实现还包含 Retry、Resume、regenerate、队列切换和 Stop 清理的同一组边界修正。已把验收文字改为与实际范围一致，不涉及新的代码改动。

## R2、R3 — 接受为测试覆盖限制

现有测试直接覆盖 fallback 前插 helper、真实 `retry()` 清理入口和 `processStreamEvents`，但没有构造真实 provider fallback，也没有在 Retry 首个新流的精确时刻调用 Stop。为此引入可注入 provider 和完整 agent-loop 控制会扩大本轮范围；保留为明确限制。

本地验证已补足静态审核无法执行的部分：App 编译通过，`RetryThinkingBlockTests` 4/4、`ToolPreflightTests` 9/9 通过。

## R4 — 接受为无消费窗口的状态不对称

历史会话加载时只恢复 `committedBlockCount`，但 `prevCommittedBlockCount` 在用户点击 Resume、真正进入新流之前会与当前消息块数同步。加载完成到 Resume 之间没有 streaming/Stop 清理消费该游标，因此不再扩大修改。

## R5 — 接受为不可达防御分支

`launchRerunAgentLoop` 的 SUSPECT 分支只在内部调用者传入越界或非 assistant 索引时触发；当前两个调用点已验证索引，正常路径都会同步两个游标。保留告警分支，不为不可达输入增加额外行为。
