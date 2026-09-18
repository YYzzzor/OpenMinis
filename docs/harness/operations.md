# Harness 操作说明

当前入口为项目根目录的 Python 脚本与 `.agents/skills/` 中的三项技能（plan-task、resume-task、review-task）。面向用户的用途和示例见[项目技能使用说明](skills-guide.md)。Python 需要 3.9+，Git 必须有初始提交。Pi 已核验本机版本 0.85.1；模型通过命令参数指定。未自动修改全局 Pi 配置。

路径含空格时，命令参数用引号包围。任务命名使用创建日期加名称：`YY-mm-dd Name`。

## 恢复和检查点

```bash
python3 scripts/harness/task_state.py inspect 'docs/tasks/active/26-09-11 实现 OpenMinis 开发 Harness/task.md'
python3 scripts/harness/task_state.py checkpoint 'docs/tasks/active/26-09-11 实现 OpenMinis 开发 Harness/task.md'
```

`inspect` 返回 0 表示检查点与当前状态一致，2 表示缺失或变化，需要阅读实际差异。它不修改源代码、任务或审批。检查点使用同目录的 `task.checkpoint.json`，保存 Git 状态和文件内容摘要，不复制聊天或全部源码。被忽略文件不参与检查；子模块记录提交与状态，但不保证发现子模块中同一 dirty 状态下的内容变化。需要这类任务时直接进入子模块检查。

先核实旧记录，再更新任务与检查点。每次有意义的进展更新，不需要每个工具调用后执行。提交或暂存会改变 Git 状态，恢复时如实核实即可；不要为了检查点显示 match 去撤销用户改动。

## 准备审查

`review.py --help` 和各子命令 `--help` 提供实际参数。以下 `<...>` 为需替换的值，不是可直接执行的路径。

```text
python3 scripts/harness/review.py prepare \
  --repo <仓库绝对路径> --base <审查基准提交> \
  --task <相对任务路径> --spec <相对规范路径> \
  --output <仓库外持久目录/轮次> \
  --exclude deps/ish --exclude deps/proot
```

`--spec` 与 `--exclude` 可重复。只有与本任务无关的路径才能排除。第一版对子模块与符号链接要求显式排除，否则拒绝准备；若本任务需要审查其内部实现，此适配范围不足，应单独准备对应仓库的审查，不能以排除绕过验收。

### 按小节提供 Spec

先从 AGENTS.md 的简短索引选择文档，再在任务记录填写必读和参考清单。准备请求时，可用下列参数替代整篇 `--spec`：

```text
--spec-section 'docs/specs/minis-url-scheme.md::Minis URL Scheme Specification > 3. Session Model'
--spec-section 'docs/specs/minis-url-scheme.md::Minis URL Scheme Specification > 10. Security Considerations'
--spec-reference 'docs/specs/ios-sandbox-ish-summary.md::iOS Sandbox Environment: iSH Virtualization Summary > 3. Mount System'
```

这些是路径解析任务的示例，不是所有任务的默认输入。完整原文仍保存和绑定；必读小节进入 request.md，参考材料先只给定位。存在跨小节前提时加入对应必读条款，短文档或边界不明确时保留 `--spec` 全文读取。详见 [Spec 上下文](spec-context.md)。

快照保存选定普通文件的实际内容、暂存/未暂存/基准差异、任务与规范副本、Git 状态和 SHA256 标识。未跟踪新增文件位于 snapshot 和 manifest 中，不出现在 Git diff 里。被 Git 忽略且未跟踪的内容不包含在快照中。

完整 bundle 放在仓库外，避免递归复制自己；正式任务应使用用户选择的持久目录，临时测试可用 `/tmp`。不默认提交完整源码副本。原始仓库路径仅用于来源记录，reviewer 使用快照中的材料。快照摘要用于发现意外变更，不是防恶意篡改的签名系统。

## 调用 Pi

```text
python3 scripts/harness/review.py run <bundle> \
  --provider deepseek --model deepseek-v4-pro --timeout 300
```

采用 Pi 非交互模式；关闭自动扩展、skills、项目上下文和提示模板发现，传入独立 reviewer 指令，仅启用 read/grep/find/ls。共享 review-task skill 指导发起与处理，脚本给独立 reviewer 传入同范围的输出要求，避免递归调用审查流程。只读工具白名单不构成文件系统或网络沙箱。

`--offline` 只关闭 Pi 启动附加网络操作，不关闭模型请求。Pi 使用已有认证；脚本不复制凭据到快照。调用可能需要本机配置目录写锁权限和模型网络访问。

默认最多执行一次模型调用，失败保留轮次后用新目录重试，不自动无限重试。超时、非零退出、错误模型、非 JSON/缺字段/版本不匹配的报告均记录为 incomplete。主进程被强制终止时可能遗留 running，恢复时先核实进程，不认为它完成。

`reviewed` 只表示得到完整报告，不是验收通过。必须阅读 conclusion、findings 和 limitations。`unable` 同样属于未完成审查。此适配不运行测试；主 Agent 另行执行验证。

conclusion 是 Pi 的建议结论。主 Agent 必须核实意见并在 resolution.md 中另记验收判断；blocking 不自动否决，no_findings 不自动通过。不采纳需附具体依据，实质疑点未解决时不能标记验收完成。

## 核验与导出

```text
python3 scripts/harness/review.py check <bundle>
python3 scripts/harness/review.py check <bundle> --repo <仓库绝对路径>
python3 scripts/harness/review.py export <bundle> \
  --repo <仓库绝对路径> --output <任务目录/reviews/001>
```

不带 repo 检查快照完整性，带 repo 还检查是否仍匹配当前代码、需求与 Git 状态。export 在仓库未变化时保存请求、manifest、原始 JSON 文本、渲染 Markdown、调用状态和完整 bundle 位置。正式使用需保留完整 bundle 才能还原代码；导出文件本身不包含完整源码。

导出本身会改变仓库状态，因此之后的严格 freshness 检查会报告变化。这是保守检测：主 Agent 需确认仅新增了报告，不能据此重写原审查标识。若代码确实改变，新建一轮审查。原始报告不覆盖；旁边新增 `resolution.md`，逐项记录处理理由、修复版本和验证。

## 验证

```bash
python3 -B -m unittest discover -s scripts/harness -p 'test_*.py' -v
git diff --check
```

格式校验与模拟测试不证明模型行为正确；实际 Pi 验证和独立恢复验证记录在 `validation.md`。真实项目试用仍需在后续任务中进行。
