# 审查处置

Reviewer：新会话 review_spec_governance，gpt-6-astra / medium / fork_turns=none，只读。原始报告为同目录 report.json；完整固定输入保存在 `/Users/huyuanzhao/.codex/.chatgpt-projects/g-p-6aa8f27e863c8191be6cf501db847b1a/outputs/spec-governance-review/001`，快照 `6211386033d344f9002373457bd8d0a5cf76d51d50d376d766d01ca39d91a436`。

Reviewer 建议：blocking，四项 P2。主模型只核对四处对应代码与任务要求，没有重复全面审查；四项均接受，因为分别影响前提保留、预算降级、既有提取兼容和请求顺序，属于已确认验收范围。

| 发现 | 处置 | 依据与后续验证 |
| --- | --- | --- |
| R1 | 已修复 | 递归对子节关闭 preamble，却不判断此前是否成功放入；改为候选始终保留必需前言，测试不足预算时不输出脱离前提的正文。 |
| R2 | 已修复 | 只尝试相邻路由模式，会把中间模式变长误判为无可用方案；覆盖能够容纳 minimal 的实例如实返回。 |
| R3 | 已修复 | 旧 extract 无需 description，但被新严格元数据解析收紧；恢复普通 Markdown 分隔线兼容。 |
| R4 | 已修复 | 按文档分组后遍历改变交错请求顺序；分离文档读取缓存与全局选区分配次序。 |

第一轮时验收未完成。后续 Luna 已完成最小修复、14 项回归及新鲜会话复审，四项全部关闭；详见[第二轮处置](<../002 前提保留与兼容修复复审/resolution.md>)。第一轮原报告保持不变，不以旧 10 项测试替代修复证据。
