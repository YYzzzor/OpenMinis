# 提案 001：启用项目 Harness 的最小规则

状态：implemented；用户于 2026-09-11 明确批准新增规则与两项共享 skill 的实施范围。
日期：2026-09-11

## 原因

用户已认可 Harness 设计并授权开始实施，同时要求影响后续任务的规则先提交具体计划与原因审核。当前 AGENTS.md 没有持久化恢复、审查交接与规则改进入口，需要明确这些边界，防止每次会话重新推断。

## 修改计划

现有 AGENTS.md 内容保留，在末尾新增以下章节（原文无此章节）：

```markdown
## Development Harness

- For complex or cross-session development, maintain a task record under `docs/tasks/active/` using `docs/harness/record-formats.md`. Small self-contained edits do not require a task record.
- When resuming, locate the relevant task, read its intent, decisions, next action and pending approvals, then verify the actual branch, HEAD and working-tree state. Resolve stale records before continuing; do not overwrite work to match a record.
- Keep task checkpoints current after meaningful progress, changed decisions, blockers and handoffs. Track implementation and verified acceptance separately.
- The main agent owns intent, integration and acceptance. Delegate only bounded, independently useful work, supplying scope, constraints, acceptance criteria and write boundaries. Avoid overlapping concurrent edits.
- For behavior changes, bug fixes and cross-module refactors, the main agent checks the implementation and available tests before requesting independent Pi review. Bind each review to fixed code, Git state and requirements. Preserve the original report and record the disposition of findings separately.
- A failed, incomplete or stale review is not a passing review. Record unavailable validation and pending review explicitly; do not mark the task complete while required acceptance remains unmet.
- Automatically correct current task records after significant misalignment. Before changing rules, specifications or skills that affect future tasks, present the concrete change, reason, scope and validation plan for user approval. Pending proposals are not active instructions.
- Shared skills and records must remain usable by Codex and Pi. Keep tool-specific execution and project-specific settings outside portable instructions where practical.
```

按实际需要新增共享 skills：

| Skill | 触发范围与主要行为 | 原因 |
| --- | --- | --- |
| resume-task | 用户续接已有开发任务；定位记录、核验工作区、恢复下一步 | 跨会话与跨工具恢复 |
| review-task | 发起或执行任务审查；固定依据、输出可核实发现、处理报告 | 意图审查与版本绑定 |

skills 使用自带 skill-creator 和标准格式；不为普通任务增加强制阶段。纠偏提案先使用文档格式，只有重复实践确有收益时再考虑独立 skill。新增 skill 的内容遵循上述已审核范围；有新的全局行为则另行提案。

## 影响与成本

影响未来复杂开发、恢复、审查和共用规则修改。行为改动增加一次独立 Pi 审查成本；纯注释和简单文档不默认调用 Pi。初次启用时若审查工具尚未可用，任务明确保持待审查，不把工具缺失当作审查通过。

## 验证与撤销

验证正常恢复、过时记录、未批准提案、Pi 失败、版本变化和小任务误触发。若规则导致无谓等待、重复上下文或错误路由，提交缩小范围或撤销的具体方案。审批状态与运行测试状态分别记录。

## 审批和实施

- 用户审批：2026-09-11 用户明确表示「AGENTS.md 的新增规则，以及两项共享 skill 的实施范围我都批准」。
- AGENTS.md：已按提案新增。
- skills、适配脚本：已实现；本地测试与 Pi 小样例通过，实际实现审查等待外发授权。
- 实施与验证证据见 ../validation.md；尚未宣称真实项目试用完成。
