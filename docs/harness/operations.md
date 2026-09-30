# Harness 操作说明

当前独立审查由全新的 GPT-6.1-Sol high 会话承担，使用 task_name 前缀 review_ 与 fork_turns=none。项目 .codex/hooks.json 中的 PreToolUse hook 检查委派参数和可见的 patch 目标；Python 需要 3.9+，Git 必须有初始提交。面向用户的技能用途和示例见[项目技能使用说明](skills-guide.md)。项目配置层受信任不代表新 hook 定义已获信任；首次触发前必须由用户审阅并信任精确配置，不得绕过。

路径含空格时，命令参数用引号包围。任务命名使用创建日期加名称：`YY-mm-dd Name`。


## Hooks 首次信任与原生验收

本项目配置位于 `.codex/hooks.json`，只匹配委派与可见的补丁调用；项目目录受信任和具体 Hook 定义受信任是两个条件。官方说明要求用户审阅并信任当前定义，未获信任的定义会被跳过；CLI 的 `/hooks` 可查看来源、信任状态和启停状态，见 [Hooks 官方说明](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks)。不要由 Agent 修改信任存储或使用绕过参数。

验收前确认实际会话工作目录属于本项目。仅将某次 shell 命令的工作目录设为仓库，不证明当前会话已加载项目配置；在项目外会话运行政策脚本也只属于手工测试。

用户在 Hook 浏览界面审阅并信任当前定义后，执行一次无副作用的匹配调用，保留宿主的 Hook 运行记录。拒绝样本可使用不会改变文件的空补丁请求；是否被 Hook 拒绝须以宿主记录为准，工具自身的补丁解析错误不能证明 Hook 已触发。随后用符合规则的真实委派或已授权的文档补丁验证允许路径。不要仅为触发而创建可见新对话、修改产品文件或增加持久日志。

验收记录应包含会话工作目录、宿主版本、配置与脚本摘要、匹配工具、原生事件及允许或拒绝结果。手工 stdin 样本、单元测试和审查结论不能替代原生事件。当前脚本仍按 `gpt-6-astra` 识别可修改白名单文档的主模型；其他主模型的文档补丁可能被拒绝。Reviewer 的只读角色不能仅凭模型名称隔离，shell 写入等路径也未被覆盖。

2026-09-30 首轮原生验收确认：合规 Luna `apply_patch` 可新增并删除临时探针，空补丁收到项目策略的原生拒绝；但作者通过 `collaboration.spawn_agent` 提交旧审核参数后获得了代理，已立即中断。CLI JSONL 未包含该协作调用的原始事件，不能据日志缺失确定具体宿主路由。

上游 [Codex issue #36519](https://github.com/openai/codex/issues/36519) 记录了命名空间工具身份与标准 `spawn_agent`/`Agent` 匹配不一致的问题。本机0.159.2的原始返回项已确认 `namespace=collaboration`、`name=spawn_agent`，仅增加带点名称后仍未取得委派拒绝。公开 [名称处理源码](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/mod.rs) 将非默认命名空间与工具名直接拼接，据此识别出的下一步兼容候选为 `collaborationspawn_agent`。用户要求暂停时，该候选尚未实施；当前委派 matcher 仍只接受 `spawn_agent`、`Agent`、`collaboration.spawn_agent` 三种名称，策略执行同一套模型、推理强度及 fork_turns 检查。公开 main 的源码不能证明本机版本的行为；当前委派原生验收尚未通过。后续修改应以调整后的 Harness 为准。

修改 matcher 后，宿主按新的定义摘要重新判断信任。旧用户批准的定义仍保留在信任记录中，但修改后的委派 Hook 为 `modified` 时不会据此执行；须在 Hooks 界面审阅并信任新定义。原有补丁 Hook 未修改，仍为 `trusted`。不要由 Agent 修改信任存储、沿用不匹配的摘要或使用绕过参数。兼容修复的策略测试与独立审核不能替代此后的原生拒绝和自动纠正重试验收。

## 恢复和检查点

```bash
python3 scripts/harness/task_state.py inspect 'tasks/active/26-09-11 实现 OpenMinis 开发 Harness/task.md'
python3 scripts/harness/task_state.py checkpoint 'tasks/active/26-09-11 实现 OpenMinis 开发 Harness/task.md'
```

`inspect` 返回 0 表示检查点与当前状态一致，2 表示缺失或变化，需要阅读实际差异。它不修改源代码、任务或审批。检查点使用同目录的 `task.checkpoint.json`，保存 Git 状态和文件内容摘要，不复制聊天或全部源码。暂存变化用完整 blob 标识及模式摘要检测，不读取已归档任务在旧路径的删除正文。被忽略文件与 tasks/archive/ 默认不参与正文摘要、状态或暂存差异检查；归档任务需明确使用 --include-archive。历史检查点采用原范围，目录迁移或过滤规则改变时先核实漂移，再更新当前任务的检查点。子模块记录提交与状态，但不保证发现子模块中同一 dirty 状态下的内容变化。需要这类任务时直接进入子模块检查。

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

`--spec` 与 `--exclude` 可重复。只有与本任务无关的路径才能排除。对子模块与符号链接要求显式排除，否则拒绝准备；若本任务需要审查其内部实现，此适配范围不足，应单独准备对应仓库的审查，不能以排除绕过验收。

### 按小节提供 Spec

先从[生成的 Spec 索引](../specs/index.md)选择文档，按[受控阅读入口](spec-context.md#受控阅读入口)查看目录与正文，再在任务记录填写必读和参考清单。准备请求时，可用下列参数替代整篇 `--spec`：

```text
--spec-section 'docs/specs/minis-url-scheme.md::Minis URL Contract > 资源作用域 > 会话资源'
--spec-section 'docs/specs/minis-url-scheme.md::Minis URL Contract > 已知实现偏差 > 请求预算解析仍会跨会话扫描'
--spec-section 'docs/specs/minis-url-scheme.md::Minis URL Contract > 路径安全契约'
--spec-reference 'docs/specs/ios-sandbox-ish-summary.md::iOS iSH Runtime and Isolation Contract > 文件系统作用域'
```

这些是路径解析任务的示例，不是所有任务的默认输入。完整原文仍保存和绑定；必读小节进入 request.md，参考材料先只给定位。存在跨小节前提时加入对应必读条款，短文档或边界不明确时保留 `--spec` 全文读取。详见 [Spec 上下文](spec-context.md)。

快照保存选定普通文件的实际内容、暂存/未暂存/基准差异、任务与规范副本、Git 状态和 SHA256 标识。tasks/ 和兼容旧路径 docs/tasks/ 默认不进入泛代码快照与补丁；只有通过 --task、--spec、--spec-section、--spec-reference 明确指定的记录文件纳入需求与内容绑定，附件不自动递归包含。这样刚从 active 移出的记录也不会通过删除补丁泄露到审查上下文。未跟踪新增文件位于 snapshot 和 manifest 中，不出现在 Git diff 里。被 Git 忽略且未跟踪的内容不包含在快照中。

完整 bundle 放在仓库外，避免递归复制自己；正式任务应使用用户选择的持久目录，临时测试可用 `/tmp`。不默认提交完整源码副本。原始仓库路径仅用于来源记录，reviewer 使用快照中的材料。快照摘要用于发现意外变更，不是防恶意篡改的签名系统。

## 暂停的 Pi / DeepSeek 旧审查适配

> **当前已暂停。** 当前审查流程使用独立 GPT-6.1-Sol high 会话；不要运行本节的 Pi run 命令。仅在用户明确要求恢复后再使用旧适配。历史授权不推翻当前暂停。

```text
python3 scripts/harness/review.py run <bundle> \
  --provider deepseek --model deepseek-flash --timeout 300
```

`run <bundle>` 省略 `--provider` 和 `--model` 时使用上述默认值；不修改全局 Pi 配置，也不在调用失败时自动换模型或提供商。

### 持续授权与执行边界

历史授权记录：维护者曾在 2026-09-27 授权对 DeepSeek 发送审查所需源码、选定任务记录和适用规范。当前暂停决定优先；若用户将来要求恢复，先确认当时的接收方范围与授权仍适用。

如用户将来明确恢复旧适配，仍须遵守当时有效的网络、沙箱和自动审批要求；项目规则不允许绕过工具拒绝。

采用 Pi 非交互模式；关闭自动扩展、skills、项目上下文和提示模板发现，传入独立 reviewer 指令，仅启用 read/grep/find/ls。共享 review-task skill 指导发起与处理，脚本给独立 reviewer 传入同范围的输出要求，避免递归调用审查流程。只读工具白名单不构成文件系统或网络沙箱。

`--offline` 只关闭 Pi 启动附加网络操作，不关闭模型请求。Pi 使用已有认证；脚本不复制凭据到快照。调用可能需要本机配置目录写锁权限和模型网络访问。

默认最多执行一次模型调用，失败保留轮次后用新目录重试，不自动无限重试。超时、非零退出、错误模型、非 JSON/缺字段/版本不匹配的报告均记录为 incomplete。主进程被强制终止时可能遗留 running，恢复时先核实进程，不认为它完成。

`reviewed` 只表示得到完整报告，不是验收通过。必须阅读 conclusion、findings 和 limitations。`unable` 同样属于未完成审查。此适配不运行测试；按 [AGENTS.md 的模型分工](../../AGENTS.md#codex-model-delegation)，GPT-6-Luna xhigh 执行相关验证，并提交与最终代码版本及目标/设备绑定的原始证据。主 Agent 通过只读检查核验证据；只有出现新变更、失败或实质疑点时才委派针对性补验。

conclusion 是 Pi 的建议结论。主 Agent 必须核实意见并在 resolution.md 中另记验收判断；blocking 不自动否决，no_findings 不自动通过。不采纳需附具体依据，实质疑点未解决时不能标记验收完成。

## 核验与导出

```text
python3 scripts/harness/review.py check <bundle>
python3 scripts/harness/review.py check <bundle> --repo <仓库绝对路径>
python3 scripts/harness/review.py export <bundle> \
  --repo <仓库绝对路径> --output "<任务目录>/reviews/001 上下文统计来源校验"
```

导出目录使用“序号＋内容标题”，标题应替换为本轮实际讨论的审查主题，不能只用 `001` 等序号。脚本的 `--output` 接受自定义路径；导出到 `tasks/active/<任务>/reviews/<轮次>` 时，会在创建任何导出目录前检查轮次名是否包含文字，拒绝纯数字、空白或只有标点的名称，并给出命名示例。标题是否准确表达讨论内容仍由主 Agent 核实；含空格时整体加引号。此检查仅用于活动任务的新导出，不改变历史快照核验和其他位置的导出行为。目录内脚本生成的文件名不变，详细规则见 [每轮审查](record-formats.md#每轮审查)。已有纯数字目录改名时，保留原始材料字节与历史路径，通过任务链接和迁移索引提供新入口；外部完整 bundle 不因展示目录改名而自动搬迁。

不带 repo 检查快照完整性，带 repo 还检查是否仍匹配当前代码、需求与 Git 状态。export 在仓库未变化时保存请求、manifest、原始 JSON 文本、渲染 Markdown、调用状态和完整 bundle 位置。正式使用需保留完整 bundle 才能还原代码；导出文件本身不包含完整源码。

freshness 只检查 manifest 已绑定的范围。新 bundle 默认不绑定未显式选择的任务记录和附件：导出到任务的 reviews/ 目录通常不会使 check --repo 变为 stale；这表示绑定输入没变，不代表全仓没有变化。旧全仓 bundle 或导出到其绑定范围内的路径仍可能因导出而报告变化。主 Agent 应核实真实代码、选定需求和排除范围，不能依赖“导出必定导致 stale”作为完成信号，也不能重写原审查标识。代码确实改变时新建一轮审查；需求变化则重新判断适用范围。原始报告不覆盖；旁边新增 `resolution.md`，逐项记录处理理由、修复版本和验证。

## 验证

```bash
python3 -B -m unittest discover -s scripts/harness -p 'test_*.py' -v
git diff --check
```

格式校验与模拟测试不证明模型行为正确；实际 Pi 验证和独立恢复验证记录在 `validation.md`。真实项目试用仍需在后续任务中进行。

## 任务发现与归档

记录位于根目录 tasks/，默认只列出 tasks/active/ 的标题/状态，并在选定后读正文。完成或取消后移动到 tasks/archive/；不要把归档当作每次 Harness 调用的背景材料。根 .ignore 也让普通 rg 搜索和文件发现默认略过 archive，不影响 Git 跟踪。task_state 和 review 工具的 --include-archive 仅用于明确需要的归档操作，不作为默认参数。task_state 的归档扩展限于所指定任务（目录式记录仅该任务目录，单文件仅该记录），不会纳入其他归档；对 active 使用该开关不会加载归档。

审查历史任务时应明确列出需要的具体文件，例如 --include-archive --task 'tasks/archive/<创建日期 名称>/task.md'。历史报告、manifest 及旧快照保留原始路径和摘要，不为迁移改写；旧 bundle 的 check 继续遵循其原先绑定的范围。归档附件如需用于本轮审查，应另用 --spec 显式指定。
