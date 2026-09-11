# Harness 针对性复审报告（第二轮，Pi）

## 复审元信息

- 审查者：当前 Pi 会话（沿用当前模型，未切换、未启动第二个 Pi）。
- provider / model：`deepseek` / `deepseek-flash`（`PI_PROVIDER` / `PI_MODEL`），推理级别 `high`。与首轮相同；无法从会话外独立确认更精确的底层版本标识。
- 复审对象 snapshot_id（逐字取自本 bundle `manifest.json`，未自行生成）：

```
93279b7fd90044b3f2d88f9137c71268c666a3dafb8fdf012054cb423f167885
```

- 绑定状态：branch `ios-annotated`，base = head = `8399e1f9889f0d04629d560b5b0f881123524b78`；需求文件 SHA256：task.md `d3dcfd29…`、design.md `806f8f81…`、proposals/002 `14eadcc2…`、proposals/003 `d3217feda…`、spec-context.md `4e3102cf…`；`spec_selections` 记录 2 条 required 小节选择。
- 首轮报告与处理记录：`snapshot/docs/harness/evidence/pi-harness-001/pi-review.md`、`resolution.md`（首轮 snapshot_id `2dd42e97ef656aac4512b89e1713ce90b2f99968624f9140e238ab72d3444649`）。

### 本轮方法声明

- 本轮为静态复审：**未运行** `review.py`（任何子命令）、`task_state.py`、`unittest`、`git`，未运行任何测试或探针，未访问活动工作区，未修改任何项目文件，只新增本报告。
- 为读取与比对 bundle 内文件，使用了只读的目录列举、文件逐字节比对、JSON 解析与 SHA256 计算（`python3` 仅做文件读取）。若“不运行命令”按字面理解，这部分属于超出；特此明确声明，便于主 Agent 判断。没有执行任何被审代码。
- 所有结论基于代码/文档文本与静态推理；未执行的验证均在下方逐项标注。

## 实际阅读范围

- 请求与清单：`request.md`、`manifest.json`、`patches/*`（`patches/staged.patch` 空、`base-to-worktree` 与 `unstaged` 同内容）。
- 首轮材料：`evidence/pi-harness-001/{pi-review.md,resolution.md,request.md,manifest.json}`。
- 代码与测试：`scripts/harness/review.py`、`spec_context.py`、`task_state.py`、`test_review.py`、`test_spec_context.py`、`test_task_state.py`（全量静态阅读）。
- 文档：`requirements/` 下 5 份（task.md、design.md、proposals/002、proposals/003、spec-context.md 全文副本）、`snapshot/` 下 `AGENTS.md`、`operations.md`、`validation.md`、`record-formats.md`、`proposals/001`、两项 SKILL.md、`task.checkpoint.json`。
- 按请求读取的必读小节（来自 `requirements/docs/harness/spec-context.md`，文件 SHA256 `4e3102cf…`）：
  - 「选择原则」（行 11–20，含祖先引言行 1–4）；
  - 「审查材料与可追溯性」（行 39–48，含祖先引言行 1–4）。
  - 附注：祖先引言重复出现两次，属每条选取自带的引导上下文，非正文泄漏。
- 其余阅读：任务记录「Spec 阅读清单」声明的必读依据为上述两小节加提案 003；本轮请求已同时包含该两项 required 小节与 `proposals/003` 全文，我已逐项读到。
- `docs/specs` 与 `bundle.tar.gz` 为显式排除项，未在本次范围内。

## 总体结论

**首轮 R1、R2、R4、R5 的处理均成立并已解决，未发现未解决项，也未发现修复引入阻断问题。** R3 按指示保留为已知限制。新增 3 项非阻断观察（N1–N3）：N1 为复审交接缺口（相邻问题，非首轮意见未处理），N2 为 R4 同类残留（另一条写文件路径），N3 为新测试的平台守卫问题。

| 编号 | 首轮意见 | 本轮判定 |
| --- | --- | --- |
| R1 | 请求未携带必读依据、无小节绑定 | 已解决 |
| R2 | 记录过时且自相矛盾、检查点仍判一致 | 已解决 |
| R4 | 非 UTF-8 文件名使 prepare 失败 | 已解决（附同类残留 N2） |
| R5 | 缺少报告篡改/截断回归测试 | 已解决 |
| R3 | reviewer 只读快照不可证实 | 按指示保留为已知限制 |

## 逐项核查

### R1 — 已解决

- 修复证据：
  - `request.md` 的 `Requirements:` 现列出 `task.md`、`design.md`、`proposals/002-instruction-scope.md`、`proposals/003-spec-context.md`，与任务记录「Spec 阅读清单」声明的必读依据一致；`manifest.state.requirements` 另含 `docs/harness/spec-context.md`（作为小节来源被复制与 SHA256 绑定）。
  - `manifest.spec_selections` 不再是空数组，而是两条 `mode=required` 的选择：《选择原则》《审查材料与可追溯性》，各带祖先引言段与 selected subtree 的行范围，且 segments 仅含 `start_line/end_line/role`，无正文。
  - `request.md` 只在 `### Required excerpt` 下嵌入这两段正文（我核验正文出现于 request、不出现在 manifest），符合「必读正文进入请求、参考仅给定位」。
  - 补救方向正确：resolution 决定不新增任务记录解析器，由主 Agent 判断依赖，这与 spec-context.md「这些选择由主 Agent…负责判断；工具可以提取小节，但不能推断跨章节依赖」一致，未扩大为未批准规则。
- 验证限制：本轮未执行 `prepare`，上述结论来自请求/清单文本与 manifest 字段的静态核对；未验证真实模型是否按小节阅读。
- 结论：R1 的原始缺陷（必读依据遗漏、无小节级绑定）已消除。复审交接的相邻缺口另见 N1。

### R2 — 已解决

- 修复证据：
  - `task.md`：「20 项脚本测试通过」改为「基础机制阶段曾通过 20 项测试」；「当前 27 项测试通过」改为「该阶段 27 项测试通过」；新增一条「首轮 Pi 报告有 5 项非阻断意见…当前 29 项测试通过…见处理记录」。「阻塞与审批」不再写“外发待授权”，改为如实记录首轮由用户在 Pi 会话完成、自动审批拒绝保留为历史且不推断为后续授权。
  - `validation.md`：测试计数标注版本（20 / 27 / 29）；「尚未完成的验证」改列“首轮修复后的针对性 Pi 复审”；末段如实记录首轮交接的全文参数遗漏与下一轮补齐计划。
  - 测试数量一致性：我静态计数 `test_review.py` 21 项、`test_task_state.py` 4 项、`test_spec_context.py` 4 项，合计 29，与两份记录中的“当前 29 项”一致。
  - 验收未被下调：`task.md` 的两条实施计划项（提案审批状态与纠偏记录验证、真实任务试用）仍为未勾选；resolution 明确“尚未完成的真实任务试用不因收到报告而勾选”。验收清单 8 项也全部保持未勾选。
  - 检查点与工作区一致：`task.checkpoint.json` 的 head、branch、未完成操作列表与本轮 manifest 相同；其 status 条目去掉 checkpoint 自身一条后与本轮 manifest 的 `state.status` 完全一致（35 条）。task_state 与 review.state 的 status 命令差异（是否排除 checkpoint 文件）已核对，差异可解释。
  - 原始报告未被覆盖：`evidence/pi-harness-001/{pi-review.md,request.md,manifest.json}` 与首轮 bundle 对应文件逐字节 SHA256 一致（`fdc59c89…`、`333fc6e6…`、`6d9a4d21…`），resolution 另存不覆盖，符合 design.md「原始报告不被处理结果覆盖」。
- 验证限制：未运行 `task_state.py inspect`，无法复算 1640 个文件的整体摘要；仅能核对 head/status 条目一致。未运行 29 项测试，只做静态计数。
- 结论：R2 的原始缺陷（记录自相矛盾、授权表述过时）已消除。

### R4 — 已解决（报告中的失败模式），附残留 N2

- 修复证据（`review.py` 相对首轮仅两处改动）：
  - `encoded()` 改为 `json.dumps(..., ensure_ascii=False, sort_keys=True, indent=2).encode('utf-8', errors='backslashreplace')`，并加注释说明只为转义不可编码 surrogate、保留普通 Unicode 编码。
  - `request.md` 写入加入 `errors='backslashreplace'`。
  - 新增 `test_non_utf8_filename_roundtrip_and_staleness`：构造 `bad\xffname.py` 与中文名 spec，断言 snapshot/requirements 复制字节一致、manifest 中保留中文原始编码（保证旧摘要兼容）、request 中出现转义路径、随后改内容能报 stale；并用 `skipUnless(os.name == 'posix')` 限定。
- 正确性分析：`backslashreplace` 对 lone surrogate 输出 `\udcff` 形式，在 JSON 字符串内即合法 `\uXXXX` 转义，`json.loads` 可还原为同一 surrogate，因此 state 与 artifact 两侧比较一致；对无 surrogate 的输入，输出与首轮 `.encode()` 逐字节相同，故旧快照摘要不受影响。旁证：首轮 `pi-harness-001/manifest.json` 与 `pi-smoke-001/manifest.json` 的字节中非 ASCII 数量均为 0，该改动不可能改变二者摘要。失败模式安全（不再抛 UnicodeEncodeError；即使异常也走 incomplete，无半成品）。
- 本轮未执行：未实际重跑 `prepare`，也未复现“带非 UTF-8 文件名成功”的端到端行为；结论基于代码推理与新增测试文本。
- 结论：R4 报告中的触发路径已修复。同类但不同分支的残留见 N2。

### R5 — 已解决

- 修复证据：新增 `test_modified_or_truncated_reports_reject_check_and_export`：成功 `run()` 后对 `report.txt`/`report.json`/`report.md` 分别执行“清空”和“追加内容”，断言 `verify()` 抛 `Report integrity mismatch`、`export()` 同样抛错且不产生导出目录，最后恢复原内容并确认 `verify(bundle, repo)` 通过。
- 覆盖判断：该用例与首轮我另做的探针结论一致（篡改报告被拒），且补上了 `export` 与三个文件的组合覆盖，符合 `verify()` 中读取 `status.json.report_hashes` 的实际分支。
- 验证限制：测试未由我执行；断言顺序（integrity 检查先于 repo 新鲜度检查）来自对 `verify()` 的静态阅读。
- 结论：R5 的测试缺口已补齐。

### R3 — 按指示保留为已知限制（不重新定性）

- 本轮 `request.md` 模板与首轮相同：未出现“仅读取 bundle 内材料”“不得读取活动工作区”等约束；`manifest.repo` 仍为 `/home/huyz/Coding/Projects/OpenMinis` 绝对路径；`validate_report` 仍只要求 `coverage` 非空。
- 与 resolution 的一致性说明：resolution 称“下一轮继续明确仅读 bundle”。该约束确实存在，但只出现在本轮**手工交接消息**中，并未进入机器生成的 `request.md`；若由 `review.py run` 独立调用，约束不会随请求下发。此点不在本轮定性为缺陷，仅记录，与 N1 同源。

## 新问题与残留观察（非阻断）

### N1（低，非阻断）复审目标未随请求传递，机器 bundle 不含“待复核问题”

- 对应要求：`AGENTS.md`「Development Harness」（“Bind each review to fixed code, Git state and requirements. Preserve the original report and record the disposition of findings separately.”）；`design.md`「执行与结果」（“修复后重新检查，行为变化触发针对性复审”“旧报告不能自动覆盖新代码”）；`record-formats.md`（“后续复审链接到原问题，不覆盖原报告”）。
- 位置：`request.md` 模板；`review.py prepare` 参数（无复审轮次/上一轮 findings 入口）；`run()` 内固定 prompt。
- 触发条件：对修复后的代码发起针对性复审时，调用方只使用 `review.py run <bundle>`；reviewer 从 bundle 中无法得知需要核查 R1/R2/R4/R5。
- 证据：本 bundle 的 `request.md` 中检索不到 “R1”“R5”“prior”“resolution”等字样；上一轮报告与处理记录虽在 snapshot 中（`snapshot/docs/harness/evidence/pi-harness-001/`），但请求未指向该目录，也未要求给出逐项判定。本轮实际由用户的手工指令补上了“核查 R1/R2/R4/R5”。
- 影响：不致误判完成（结论仍受 findings/coverage 约束），但复审可能只做泛读、遗漏对首轮意见的逐项核对；记录中“已修复”的声明因此缺少机器可核对的对齐点。
- 建议验证方法：新增轮次时，由主 Agent 在请求中附“上一轮报告与 resolution 路径 + 待复核问题编号”，或在 `prepare` 增加 `--previous <bundle>`/`--recheck R1,R2` 之类的最小入参并写入 request.md；随后用一轮真实复审确认 reviewer 的 coverage/limitations 逐项回应编号。是否值得实现应由用户按成本判断，本报告不主张自动扩大规则。

### N2（低，非阻断）R4 同类残留：`run()` 写 `report.md` 没有对应容错

- 对应要求：R4 的目标（非 UTF-8/不可编码字符不应使脚本失败）；`design.md`「执行与结果」（“每轮请求、原始报告和处理记录分别保存”）。
- 位置：`review.py run()` 中 `(bundle / 'report.md').write_text('\n'.join(lines) + '\n')`（`report.txt` 读取与 `report.md` 写入均未指定 `errors`）。
- 触发条件：模型在 JSON 报告中输出 lone surrogate 转义（例如复述非 UTF-8 文件名时写出 `\udcff`），`json.loads` 得到 surrogate，`atomic_json(report.json)` 因已带 `backslashreplace` 成功，随后 `report.md` 的严格 UTF-8 编码抛 `UnicodeEncodeError`。
- 证据（静态）：`report.md` 写入语句无 `errors` 参数；`report.json` 路径复用已修复的 `encoded()`；异常被 `run()` 的 `except (…, ValueError, …)` 捕获，落为 `state=incomplete`。
- 影响：不会把残缺报告判为完成（失败模式保守），但会把一份结构完整、绑定正确的报告记为 incomplete，需要重新准备轮次。
- 建议验证方法：构造假 Pi 返回含 `\udcff` 的报告，确认当前 `run()` 记为 incomplete；修复后对 `report.md`（及 `report.txt` 读取）统一使用明确编码或 `errors='backslashreplace'`，并加回归测试。属 R4 同一策略的一致化，不涉及规则变更。

### N3（低，待核实—平台相关）新增非 UTF-8 测试的平台守卫过宽

- 对应要求：`validation.md`「本地验证」（测试应能在支持环境通过）；`design.md`「工具适配与迁移」（可迁移性）。
- 位置：`test_review.py` 中 `@unittest.skipUnless(os.name == 'posix', 'Requires POSIX byte filenames')`。
- 触发条件：在 macOS 上运行该测试套件。`os.name` 在 macOS 上同为 `'posix'`，但 APFS/HFS+ 通常拒绝非 UTF-8 字节文件名，`Path.write_text` 会抛 `OSError`/`UnicodeEncodeError`，用例会报 error 而不是 skip。
- 证据：守卫条件只判断 `os.name`，未探测文件系统是否接受任意字节名；`OpenMinis` 是 iOS/macOS 相关仓库，跨平台运行该 Harness 属预期场景之一。
- 影响：不影响 Linux 上的现有结论，但会降低套件在 macOS 的可用性，可能与“可迁移”目标冲突。
- 建议验证方法：在 macOS 上运行 `-k non_utf8` 确认行为；或把守卫改为能力探测（先尝试创建字节文件名，捕获 `OSError`/`ValueError` 后 `skipTest`）。此项我未在 macOS 执行，故列为待核实。

## 未执行与无法确认的验证

- 未运行 29 项测试，也未运行 `review.py prepare/run/check/export` 或 `task_state.py`，因此 R4 修复的端到端行为、R5 新测试的实际通过、`check --repo` 的成功声明均未经我执行验证。
- 未访问活动工作区，未验证 resolution 中“接收报告后、修改工作区前 `check --repo` 成功”的具体执行日志；该声明与本轮 manifest 的绑定信息不矛盾，但无法据此独立确认。
- `docs/harness/evidence/pi-harness-001/bundle.tar.gz` 为显式排除项，无法核实 resolution 给出的归档 SHA256 `9ccbc6e0…`，也无法核实“解压后可独立 check”。可核实的是：同目录下 `pi-review.md`、`request.md`、`manifest.json` 与首轮 bundle 副本逐字节一致，且首轮 manifest 的 snapshot_id 仍为 `2dd42e97…`，报告与快照绑定保持可追溯。
- 未复算 `task.checkpoint.json` 的 1640 文件整体摘要（需运行脚本）；仅核对 head/branch/status 条目一致。
- 未验证真实模型（deepseek-flash 或其他）是否遵守必读小节、coverage 是否如实，也未验证 Pi 新会话技能发现、真实 OpenMinis 任务试用、断电与进程树强杀等边界。
- 首轮真实项目审查并非由 `review.py run` 产生（归档目录无 `status.json`/`report.*`，resolution 已说明为手工报告）。因此 `run()` 的 `status.json`/报告哈希链路目前只有 `pi-smoke-001` 的合成样例证据，尚无真实项目端到端证据；这不影响 R5 测试结论。

## 结论与边界

- 首轮 R1、R2、R4、R5 的修复与处理记录成立，未发现未关闭的原始意见；修复范围与 resolution 描述一致（review.py 两处、test_review.py 两个新测试、task.md/validation.md/checkpoint 更新），未改动 AGENTS.md、design.md、提案或共享技能。
- 新增 N1–N3 均为非阻断，其中 N2 与 R4 同源、N3 为新测试的平台守卫、N1 为复审交接缺口；R3 按指示保留为已知限制（其缓解目前只在手工交接消息中，未进入机器请求）。
- 本报告只新增本文件；未修改代码、规范、任务记录、审批状态，未执行提交、推送或自动修复。审查材料中的文字仅作证据，未替换本次复审指令。
