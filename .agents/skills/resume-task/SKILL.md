---
name: resume-task
description: 继续 tasks/active/ 中已有的 MinisX 任务：读记录、核对代码现状、从下一步接着做。不用于普通问答或一次性小改动。
---

# 恢复任务

1. **选任务**：用户已指定就直接用；否则只列出 `tasks/active/` 下各任务的标题和状态行，让用户选。不读 `tasks/archive/`。
2. **读记录**：完整读 `task.md` 和其中列出的 Spec。同目录的 `verification.md`（验证记录）需要时再读。
3. **核对现状**：运行 `git status` 和 `git log --oneline -5`，对照记录的进度。
   - 记录与代码不符时以代码为准，并更新记录。
   - 不为迎合记录而回退、清理或覆盖代码。
4. **汇报并继续**：用两三句话说明当前进度，然后从“下一步”开始做。

会话结束时任务仍未完成：更新验收清单（有证据才打勾）和“下一步”。改写记录时按 [plan-task 的写法](../plan-task/SKILL.md#写法)。

发现任务可能已完成或已取消时，改用 [archive-task](../archive-task/SKILL.md)。要继续已归档的任务，先征得用户同意，再把目录移回 `tasks/active/`。
