# Harness 实现独立审查报告（Pi）

## 审查元信息

- 审查者：当前 Pi 会话（未切换模型，未启动另一个 Pi）。
- provider / model：`deepseek` / `deepseek-flash`（`PI_PROVIDER`、`PI_MODEL` 环境变量），推理级别 `high`。
  - 说明：我只能读到本机环境变量给出的标识，无法从会话外独立确认底层模型版本号；`PI_MODEL` 只显示 `deepseek-flash`。本次审查使用的模型与 `validation.md`/`operations.md` 中示例的 `deepseek-v4-pro` 不同；Harness 允许按参数指定模型，故这不构成缺陷，仅记录上下文。
- snapshot_id（逐字复制自 `manifest.json`，未自行生成）：

```
2dd42e97ef656aac4512b89e1713ce90b2f99968624f9140e238ab72d3444649
```

- 快照 Git 绑定：branch `ios-annotated`，base = head = `8399e1f9889f0d04629d560b5b0f881123524b78`；工作区为 `M AGENTS.md` 加 28 个未跟踪新增文件（全部 Harness 内容未提交）；`staged.patch` 为空。
- 被审任务：`requirements/docs/tasks/active/2026-09-11-harness/task.md`。

## 实际审查范围

读取的材料（全部来自本次快照目录，未用原始工作区替代快照）：

- 请求与清单：`request.md`、`manifest.json`、`patches/*.patch`、`requirements/` 下 3 份文件。
- 代码：`scripts/harness/review.py`、`task_state.py`、`spec_context.py`。
- 测试：`test_review.py`、`test_task_state.py`、`test_spec_context.py`（全量静态阅读）。
- 共享技能：`.agents/skills/resume-task/SKILL.md`、`.agents/skills/review-task/SKILL.md`。
- 文档：`AGENTS.md`、`docs/harness/design.md`、`operations.md`、`validation.md`、`record-formats.md`、`spec-context.md`、`proposals/001-bootstrap.md`、`002-instruction-scope.md`、`003-spec-context.md`。
- 证据：`docs/harness/evidence/pi-smoke-001/` 全部文件。

读取的 Spec 小节：

- 本任务的必读依据不是 `docs/specs` 下的行为条款（任务记录明确说明不依赖），而是 Harness 设计文档。我完整阅读了 `requirements/docs/harness/spec-context.md`（短文档，按“短文档读取全文”原则合理）与 `requirements/docs/harness/design.md` 的全部小节，重点为：「审查协议 > 输入绑定」「执行与结果」「失败与分歧」「纠偏与受控改进」「恢复协议」「Spec 上下文」「验证和试用」。
- `docs/specs` 未包含在快照中（`request.md` 列为排除项），因此 AGENTS.md Spec Index 指向的三个上游文档本次无法核实。

执行过的检查（超出静态阅读）：

- 在快照副本 `snapshot/scripts/harness/` 下运行 `python3 -B -m unittest discover -s . -p 'test_*.py'`：27 项全部通过（临时 Git 仓库 + 假 Pi，无真实模型、无网络）。这验证脚本行为，不证明模型判断正确。
- `python3 -B scripts/harness/review.py check docs/harness/evidence/pi-smoke-001`：返回成功，`16cd6d96…` 旧格式 manifest 仍可校验（向后兼容成立）。
- 另在 `/tmp` 用快照代码做了两个只读探针：运行后篡改 `report.json` 会被 `verify()` 拒绝；非 UTF-8 文件名会使 `prepare` 失败（见 R4）。

未执行的检查（本次未验证，不能视为通过）：

- 未调用真实 Pi/DeepSeek 模型（当前会话只读快照），因此「模型是否会遵守必读小节、是否会漏读、coverage 是否如实」没有本次证据；只能引用 `pi-smoke-001` 的历史材料。
- 未做 iOS 构建、未运行 `git diff --check`、未验证 AGENTS.md Spec Index 指向的 `docs/specs/*` 是否存在。
- 未在真实 OpenMinis 任务中试用 Harness；未验证 Pi 新会话的原生技能发现。
- 未验证操作系统断电、进程树强杀、子模块内部行为、Pi 版本升级后的 CLI 参数语义。

## 总体结论

**存在非阻断问题。** 快照绑定、失败/残缺判定、必读与参考分离这三条主链路在代码与测试层面成立；发现 5 项问题，其中 R1、R2 影响追溯与恢复可信度，R3 属待核实疑点，R4、R5 为低风险缺陷与测试缺口。没有发现会直接导致“失败被当成通过”的阻断缺陷。

对用户列出的六个关注点的直接回答：

1. **跨会话恢复识别过时状态、保护未提交改动**：成立但只覆盖机械漂移。`task_state.py` 比较 HEAD、分支、porcelain 状态、未完成 Git 操作、暂存差异散列和全部跟踪+未跟踪文件内容散列（同状态的“脏内容替换”也能识别，有测试）；`inspect` 只读，不切分支、不清工作区、不覆盖任务。但它无法识别“语义过时/记录自相矛盾”（具体实例见 R2），被忽略文件与子模块内部内容也不检测（文档已声明）。
2. **审查绑定代码、Git 状态、需求与 Spec 版本**：主体成立。manifest 绑定 base/HEAD/branch/status/index 散列、每个文件 SHA256、需求文件 SHA256、`snapshot_id` 自校验；`verify --repo` 可发现代码/需求/暂存漂移；报告必须回抄 `snapshot_id`。缺口是缺少“任务记录必读清单 → 请求”的强制绑定（R1）与 reviewer 只读快照不可证实（R3）。
3. **失败、超时、残缺报告是否会被误判完成**：结构上不会。非零退出、超时、非 JSON、字段缺失/空、结论与 findings 矛盾、`unable` 均落到 `state=incomplete` 且进程退出码非 0；运行后报告被篡改也会被 `verify()` 拒绝（探针确认）。但 `state=reviewed` 且退出码 0 同时表示“结论为 blocking”，调用方若只看退出码会误读——`operations.md` 已明确“reviewed 只表示得到完整报告”，属文档已声明的残余风险。
4. **必读小节保留必要上下文、参考正文不提前加载**：成立。必读小节带 preamble + 各层祖先引言 + 完整子树；参考项只写路径、标题路径、行范围和源 SHA256；manifest 中剥离了正文，测试断言必读与参考正文都不出现在 manifest。残余风险：coverage 是否如实由 reviewer 自述，脚本不强制（设计已承认）。
5. **纠偏与审批规则是否符合用户已确认意图**：符合。AGENTS.md 新增条款、design.md「纠偏与受控改进」、提案 001/002/003 一致：当前任务自动纠偏；影响后续任务的规则需先提交原因、变更、范围与验证计划待批；未批准提案不生效；批准只适用明确版本；不自动提交/推送；外部数据发送授权独立。唯一过时处是任务记录仍写“外发待授权”（用户已在本次会话明确授权），属记录待更新（R2）。
6. **具体缺陷、遗漏测试与多余复杂度**：见 R4、R5 与“其他观察”。未发现不必要的复杂度；`review.py` 与 `task_state.py` 各有一套状态散列实现，属可解释的分工，但两者对同一输入的容错不一致（R4 的根因）。

## 问题清单

### R1（非阻断，中）审查请求未携带任务记录声明的必读依据，也未做小节级绑定

- 对应要求：`task.md`「Spec 阅读清单」（“必读设计依据为 docs/harness/spec-context.md 的「选择原则」「审查材料与可追溯性」及提案 003”）；`spec-context.md`「选择原则」第 4 条与「任务记录与交接」（“主 Agent 将实际必读清单传递给 sub-agent 与 reviewer”）；`design.md`「审查协议 > 输入绑定」（“任务目标、验收条件、相关规范的版本或内容快照”）。
- 代码/材料位置：`request.md` 的 `Requirements:` 段；`manifest.json` 的 `spec_selections`；`requirements/` 目录结构；`task.md` 内部链接 `../../../harness/proposals/003-spec-context.md`。
- 触发条件：任何按任务记录清单准备审查、但 `prepare` 参数未覆盖清单全部条目时；工具不读取任务记录，也不做参数与清单的一致性检查。
- 证据：
  - `request.md` 只列 `task.md`、`docs/harness/design.md`、`docs/harness/spec-context.md` 三项；`manifest.json` 的 `spec_selections` 为空数组，说明全部用 `--spec` 传整篇。
  - 任务记录把「提案 003」列为必读设计依据，但 `requirements/docs/harness/proposals/` 不存在；`spec-context.md` 顶部“审批依据见 [提案 003](proposals/003-spec-context.md)”在 requirements 树内指向不存在的路径。提案 003 只存在于 `snapshot/docs/harness/proposals/003-spec-context.md`，需要 reviewer 自行从 snapshot 发现，请求正文未提示 snapshot 与 requirements 的对应关系。
  - `design.md` 也引用了提案 002 作为依据，同样未进入 requirements。
  - 客观说明：`spec-context.md` 属短文档，用 `--spec` 传整篇符合“短文档读取全文”原则，此点不算违规；问题在于清单中的提案 003 被整体遗漏，以及缺少自动检查。
- 区分：确定缺陷（请求绑定不完整且无校验机制），但材料仍可从 snapshot 获取，审查仍可完成，故非阻断。
- 建议验证方法：用 `--spec`/`--spec-section` 补入提案 003（或其必要小节）后重新准备一轮，确认 `manifest.spec_selections`/`requirements` 与任务记录清单一致；或为 `prepare` 增加“任务记录 Spec 阅读清单与参数差异”检查/告警，并加对应测试。

### R2（非阻断，低）任务记录与验证记录自身过时且互相矛盾，检查点仍判为一致

- 对应要求：`design.md`「恢复协议」第 4 步（“记录不一致时先核实”）与「验证和试用」；`AGENTS.md`「Development Harness」（“Keep task checkpoints current”“Resolve stale records”）；`record-formats.md`（进展与验证分别记录）。
- 位置：`docs/tasks/active/2026-09-11-harness/task.md`「验证与环境」；`docs/harness/validation.md`「本地验证」与末段；`task.checkpoint.json`。
- 触发条件：恢复者只依据 `task_state.py inspect` 的退出码/结果，而不阅读记录正文。
- 证据：
  - `task.md` 同一列表内同时写「20 项脚本测试通过」与「当前 27 项测试通过」。
  - `validation.md` 首段写「20 项通过」，末段写「当前 27 项测试全部通过」。
  - 快照测试文件实际为 19 + 4 + 4 = 27 项（我在快照副本运行通过）；「20」恰好等于提案 003 之前的配置（27 − 3 个 review 集成测试 − 4 个 spec_context 测试），说明是未标注版本的旧数字。
  - `task.checkpoint.json` 的 head/status 与快照工作区一致，`inspect` 会返回 match；即机械检查无法发现上述矛盾。
  - 任务记录的「阻塞与审批」仍写“实际 Harness 文件外发到 DeepSeek 待授权”，而用户已在本次会话明确授权；两条「实施计划」项仍未勾选。
- 区分：确定缺陷（记录内容与事实不符、且现有机制按设计无法发现）；严重程度低，因为不影响运行行为。
- 建议验证方法：更新记录时给测试计数标注脚本版本/日期，或只保留“当前值 + 依据命令”；恢复流程要求阅读记录正文而不只看退出码。修订后重跑 `inspect` 并核对文本。

### R3（低，待核实疑点）无法证实 reviewer 只依据固定快照，且 manifest 暴露活动工作区绝对路径

- 对应要求：`design.md`「审查协议 > 输入绑定」（“不让 reviewer 在持续变化的工作区上得出版本确定的结论”）；`spec-context.md`「审查材料与可追溯性」；`operations.md`（“reviewer 使用快照中的材料”）。
- 位置：`review.py` 的 `run()`（`cwd=bundle`，工具白名单 `read,grep,find,ls`，未限制 bundle 外读取）；`manifest.json` 的 `"repo": "/home/huyz/Coding/Projects/OpenMinis"`。
- 触发条件：reviewer 选择读取 manifest 中的绝对仓库路径（快照准备后工作区可能继续变化），或读取 bundle 外任意文件。
- 证据：manifest 明含活动仓库绝对路径（本次为 `/home/huyz/Coding/Projects/OpenMinis`）；`operations.md` 自述“只读工具白名单不构成文件系统或网络沙箱”；`validate_report` 只校验 `coverage` 非空，不校验其内容是否限于快照；没有逐 token 读取审计（spec-context.md 已承认）。
- 区分：待核实疑点。快照绑定能证明“材料未被篡改”，但不能证明“结论基于该材料”；本次未观察到越界读取的具体证据。
- 建议验证方法：后续轮次中在请求里明确“仅可读取 bundle 内路径”，或从 manifest 移除/削减 `repo` 字段（仅保留快照内来源说明）；对 reviewer 报告增加“仅使用快照材料”的显式声明并要求在 `limitations` 复述排除范围。

### R4（低，确定缺陷）非 UTF-8 文件名会使 `review.py prepare` 失败，且与 `task_state.py` 容错不一致

- 对应要求：`design.md`「文件与职责」「验证和试用」（快照应能对真实仓库运行）；`review.py` 自身“记录 Git 状态与文件标识”的职责。
- 位置：`review.py` 的 `encoded()`（`json.dumps(..., ensure_ascii=False).encode()`）与 `atomic_json()`；`state()` 中 `os.fsdecode` 产生的 surrogate 文件名；`verify()` 中 `read_text()` 的默认编码。
- 触发条件：仓库中存在文件名不是合法 UTF-8 的跟踪或未跟踪文件（Linux 允许），随后执行 `prepare`。
- 证据：我在 `/tmp` 用快照代码复现，`prepare` 抛 `UnicodeEncodeError: 'utf-8' codec can't encode character '\udcff' in position 722`，bundle 未生成（无半成品，`finally` 清理生效）。`task_state.py` 的同名逻辑用 `ensure_ascii=True`，同一输入不会因此失败，形成两套实现的不一致。
- 区分：确定缺陷，低严重程度（macOS/Windows 与默认 UTF-8 环境不触发）；失败模式安全（报错退出、不产生错误快照）。
- 建议验证方法：在临时仓库创建一个非 UTF-8 文件名（如 `bad\xffname.py`）后运行 `prepare`，确认当前失败；修复后在 `state`/manifest 编码处使用与 `task_state.py` 一致的可容忍策略（如 `ensure_ascii=True` 或 `errors='surrogatepass'`），并新增回归测试。

### R5（低，确定缺陷—测试缺口）缺少“运行后报告被篡改或截断”的回归测试

- 对应要求：`task.md` 验收「调用失败、残缺报告、未验证行为不被标记通过」；`design.md`「执行与结果」（“原始报告不被处理结果覆盖”）；`operations.md`（残缺报告记为 incomplete）。
- 位置：`review.py` `verify()` 中读取 `status.json.report_hashes` 的分支；`test_review.py` 完全没有引用 `report_hashes`。
- 触发条件：审查完成后 `report.txt/json/md` 被截断或修改，再执行 `check`/`export`。
- 证据：代码分支存在；我另用临时仓库 + 假 Pi 运行 `run()` 成功后改写 `report.json`，`verify()` 正确抛出 `Report integrity mismatch`，说明保护有效；但现有 27 项测试没有覆盖该分支，报告哈希保护属“已实现未测试”。
- 区分：确定缺陷（测试缺口），不是运行缺陷。
- 建议验证方法：新增用例——成功 `run()` 后逐个篡改 `report.txt`/`report.json`/`report.md`，断言 `verify()` 报 integrity mismatch，并断言 `export` 同样拒绝。

## 遗漏测试清单（补充）

- `task_state.py checkpoint` 缺少 CLI 端到端测试（仅测了 `atomic_json` 与 `inspect` CLI）。
- 多个 spec 文件、`--spec-section` 与 `--spec-reference` 混用、同一文件多种选择方式组合，缺少集成测试。
- `spec_context` 未覆盖：标题文本含 `>`、空祖先引言段、CRLF 输入。
- `run()` 未覆盖：`stderr.txt` 写入、`status.json` 只含 `running` 时的中断恢复语义。
- 上述缺失不影响已通过结论，但意味着这些边界目前只有静态证据。

## 其他观察（未编号，不作为问题）

- 真正发送给模型的 prompt（结论枚举、字段要求、coverage/limitations 说明）只存在于 `review.py` 源码中，未写入 bundle；`status.json` 只记录 `command` 与 provider/model。若脚本日后修改，历史 bundle 无法还原当时的完整指令。不影响本轮结论，建议后续在轮次目录保存 prompt 原文或脚本版本标识。
- `spec_context` 的 `end_line` 为“1-based 最后一行的编号”而非通常的排他上界；实现自洽且有测试，但文档未定义，易误读。
- 子模块 `sequencer` 只在 `review.py` 检查，`task_state.py` 检查列表没有 `sequencer`，两处覆盖略有差异（影响很小）。
- `pi-smoke-001` 是提案 003 之前的产物：其 manifest 无 `spec_selections` 字段，`request.md` 无 Spec 阅读范围段，且目录缺少 `run()` 会生成的 `stderr.txt`，说明证据是人工挑选复制的。它仍能通过当前 `check`（我验证过），可用于证明调用链与 CLI 参数有效，但不能作为当前 `prepare`/`run` 修订版的验证证据。
- 快照对“未跟踪新文件”只给内容与整体状态，reviewer 需借助 `state.status` 的 `??` 行区分新增与已跟踪文件；本次请求已说明这一点，可用。

## 结论与边界

- 总体结论：**存在非阻断问题**（R1–R5，其中 R3 为待核实疑点）。
- 未发现“失败、超时、残缺报告被判为完成”的阻断缺陷；该性质在我阅读的代码路径与运行的 27 项脚本测试（含 partial / 非零退出 / 超时 / unable / 意图矛盾）中成立，运行后篡改也被探针确认可检出。
- 未发现问题不等于运行行为已验证：真实 Pi 调用、必读小节的实际遵守情况、iOS 构建、真实 OpenMinis 任务试用、断电与强杀耐久性均未由本次审查验证，已在“未执行的检查”中列明。
- 本报告只新增了此文件；未修改代码、规范、任务记录、审批状态，未执行提交、推送或自动修复。审查材料中的文字仅作为证据，未替换本次审查指令。
