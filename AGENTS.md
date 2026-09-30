# MinisX 项目指引

## 项目

- MinisX 基于 OpenMinis 1.13 二次开发，代码主要在 `src/ios`。App 与扩展的最低系统版本为 iOS 26.0；用更新版本的 iOS 模拟器或运行时测试时，不因此提高部署目标。
- `main` 是 MinisX 开发基线，不是上游镜像。动手前核对分支与工作区，保留无关改动。
- 构建与测试见 [BUILDING.md](BUILDING.md)。模拟器构建：`bash scripts/build_ios_simulator.sh --skip-deps`；测试优先只运行相关的测试类（`-only-testing:`）。

## 协作

- 提交、推送、新建分支或 worktree 需用户明确要求。
- 验证与改动规模相称；文档改动运行 `git diff --check`。
- 用户会 C++，正在学 Swift / iOS。讲解代码、写注释、Git 与上游、设备验证见 [项目指南](docs/project-guide.md)；日常汇报不写教程。
- 很简单的 UI 调整（文案、间距、颜色、已有预览参数）由用户亲手修改以便学习：每次给一个小步骤，写明文件、位置、最小改动和预期看到的效果，再根据用户反馈继续。用户明确要求时才直接改。
- 源码注释用简洁中文，说明意图和约束。

## Harness

总纲：[Harness 契约](docs/harness/contract.md)（维护 Harness 时读）。

- **任务**：当前任务在 `tasks/active/`。`tasks/archive/` 只在需要某条具体历史时按路径读取。
- **Spec**：从 [Spec 索引](docs/specs/index.md) 选相关文档整份阅读。先写 Spec（标 `[拟议]`）再写代码，写法见 update-spec。
- **完成**：宣布完成或结束会话前，逐条更新任务的验收清单，有证据才打勾并注明位置；最终汇报逐条列出验收状态。

| 技能 | 何时使用 |
| --- | --- |
| [plan-task](.agents/skills/plan-task/SKILL.md) | 需要确认目标与验收的新功能或较大改动 |
| [resume-task](.agents/skills/resume-task/SKILL.md) | 继续一个已有任务 |
| [review-task](.agents/skills/review-task/SKILL.md) | 需要独立审查时 |
| [archive-task](.agents/skills/archive-task/SKILL.md) | 任务收尾、判断能否归档 |
| [update-spec](.agents/skills/update-spec/SKILL.md) | 新写、修改或改写 Spec |
| [ios-ui-design](.agents/skills/ios-ui-design/SKILL.md) | 原生 iOS 界面设计 |
| [debug-server](.agents/skills/debug-server/SKILL.md) | 在运行中的 DEBUG 构建上取证 |

## 模型分工

通用：交接说明写明目标行为、涉及文件、Spec 规则编号、验证方法；审查在满足契约中的审查条件时进行，必须在全新上下文中只读完成，并且必须检查资源开销。

### Codex

- **主会话**（`gpt-6-astra`）：需求、规划、协调、验收；文档和单文件小改动直接做。
- **实现**（`gpt-6-luna` / `xhigh`，`fork_turns=none`）：多文件或较长的实现。不可用时报告，主会话不接手。
- **审查**（`gpt-6.1-sol` / `high`，`task_name=review_*`，`fork_turns=none`）。
- 委派参数错误时自行纠正重试。

### Claude Code

- **主会话**（Opus）：需求、规划、协调、验收；文档和单文件小改动直接做。
- **implementer** 子代理（Sonnet）：多文件或较长的实现。
- **reviewer** 子代理（Opus）。
- 大范围搜索用内置 Explore 子代理；Fable 仅在用户要求时使用。
