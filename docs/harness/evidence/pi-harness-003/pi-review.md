# Harness N2/N3 针对性复核报告（Pi）

## 复核元信息

- 复核者：当前 Pi 会话（沿用当前模型，未切换、未启动第二个 Pi）。
- provider / model：`deepseek` / `deepseek-flash`（`PI_PROVIDER` / `PI_MODEL`）。用户说明实际模型为 DeepSeek-V4.1-flash，Pi 自报为 `deepseek-flash` 别名；两者分别记录，我无法从会话外独立确认底层版本。
- 绑定快照（逐字取自本 bundle `manifest.json`，未自行生成）：

```
e8a6cfb1b847567618f0308f20224d7d6b85bff2e59c29d9bc9986d0e73d88bc
```

- 快照 Git 绑定：branch `ios-annotated`，base = head = `8399e1f9889f0d04629d560b5b0f881123524b78`；`patches/staged.patch` 空；需求 SHA256：task.md `1286380b…`、design.md `588da5d8…`、resolution.md `d83126e7…`、proposals/004 `9006ac45…`、spec-context.md `4e3102cf…`。
- 方法：本轮**只用 read 工具**读取本 bundle 内材料。未运行 bash/Python、未运行测试或 `review.py`、未访问活动工作区、未修改任何文件、未启动另一个 Pi。写入前已确认 `review/pi-review.md` 不存在（ENOENT），本报告为唯一新增文件。
- 范围边界：按用户指示只核查 N2、N3；不做 Harness 全面复审，不重开已关闭的 R1/R2/R4/R5。以下结论是供主 Agent 核实的审查意见，不直接决定验收（与提案 004、design.md「执行与结果」新增段一致）。

## 实际阅读范围

- `request.md`、`manifest.json`（含 `spec_selections`、`state.requirements`、`state.files` 摘要）。
- Requirements 必读材料：`requirements/docs/tasks/active/2026-09-11-harness/task.md`、`requirements/docs/harness/design.md`、`requirements/docs/harness/evidence/pi-harness-002/resolution.md`、`requirements/docs/harness/proposals/004-review-judgment.md`；`proposals/002`、`proposals/003` 的 SHA256 与既有轮次相同（`14eadcc2…`、`d3217fed…`），未重复全文阅读。
- Spec 必读小节（来自 request.md 的 required excerpt，源文件 `docs/harness/spec-context.md`，SHA256 `4e3102cf…`）：「选择原则」（行 11–20 及祖先引言 1–4）、「审查材料与可追溯性」（行 39–48 及祖先引言 1–4）。两段正文均已读到，来源与全文件摘要一致。
- 被改动代码与测试：`snapshot/scripts/harness/review.py`（SHA256 `81d563dc…`）、`snapshot/scripts/harness/test_review.py`（`337a8342…`）。`spec_context.py`、`task_state.py`、`test_task_state.py`、`test_spec_context.py` 摘要与上一轮相同，未改动。
- 相关记录：`snapshot/docs/harness/validation.md`、上一轮原始报告 `snapshot/docs/harness/evidence/pi-harness-002/pi-review.md`（用于对照 N2/N3 原始表述）、`resolution.md`（要求确认 N1）。
- 未读取（超出范围或排除项）：`docs/specs`、`src`、`deps`、两份 `bundle.tar.gz`、AGENTS.md/review-task skill 等提案 004 文档改动的逐条核对。

## 总体结论

| 项目 | 复核判定 |
| --- | --- |
| N2：`report.md` 的 surrogate 处理与回归覆盖 | **已解决**（附 2 项不影响结论的小缺口，见下） |
| N3：非 UTF-8 文件名测试的能力检测 | **已解决** |
| N1（resolution 要求确认）：处理记录已随请求进入 Requirements | **已确认**（部分采纳方式成立） |

未发现与两项改动有关的新缺陷。所有判定基于静态阅读：本轮未执行测试，因此“30 项通过”、两个新测试的实际执行结果、以及修复前后的运行时差异均未由我运行验证。

## N2 核查：`report.md` 的 surrogate 处理

### 代码位置与变更

- `review.py` `run()`：`(bundle / 'report.md').write_text('\n'.join(lines) + '\n', encoding='utf-8', errors='backslashreplace')`（上一轮该调用无 `encoding`/`errors`）。
- `review.py` `run()`：`report = validate_report((bundle / 'report.txt').read_text(encoding='utf-8'), manifest['snapshot_id'])`（上一轮为默认编码，现显式 UTF-8，且**未**放宽 `errors`，保持严格解码）。
- `review.py` `encoded()`：保持上一轮的 `ensure_ascii=False` + `.encode('utf-8', errors='backslashreplace')`，`report.json` 经 `atomic_json` 走此路径。
- `test_review.py` 新增 `test_report_surrogate_is_preserved_and_rendered_as_escape`。

### 判定：已解决

依据逐条对照 resolution.md 的四项声明：

1. **不再把完整报告误判为 incomplete**：`report.md` 写入不再对 lone surrogate 抛 `UnicodeEncodeError`；`report.json` 与 `request.md` 已有同类容错。原 N2 的触发链（`json.loads` 得到 surrogate → `report.md` 严格编码失败）已被切断。
2. **原始 report.txt 不改写**：`run()` 中 `report.txt` 只作为子进程 stdout 目标打开，之后没有任何写入或重写语句；现在只以 UTF-8 严格读取一次用于校验。实现上成立。
3. **report.json 保留原值**：`encoded()` 将 lone surrogate 写为 `\udcff` 转义（普通 Unicode 仍为原始 UTF-8 字节），`json.loads` 可还原同一值；新测试断言 `json.loads(report.json)['coverage'] == chr(0xdcff)`。
4. **展示转义**：`report.md` 中该字符呈现为字面 `\udcff`；新测试以 `assertIn(r'\udcff', ...)` 断言。
5. **输入严格性**：`report.txt` 现为显式 UTF-8 严格解码，损坏或非 UTF-8 输入仍归为 incomplete，未采用“随意容错”，符合 resolution 的取舍。

回归测试覆盖核对（`test_report_surrogate_is_preserved_and_rendered_as_escape`）：

- 覆盖 `result['state'] == 'reviewed'`（修复前会在 `report.md` 写入处失败）。
- 覆盖 report.json 原值、report.md 转义。
- 覆盖 `verify(bundle, repo)`（report_hashes 与快照绑定仍成立）与 `export(...)`（surrogate 报告可导出且不报错）。
- 未覆盖的两点（小缺口，不改变结论）：未断言 `report.txt` 字节等于假 Pi 的原始输出（实现上无重写路径，属结构性保证）；导出后未逐字节比对 `report.md`/`report.json`（`export` 使用 `shutil.copy2`，且既有 `test_export_requires_freshness_and_preserves_original_report` 已对 report.txt 做字节比对）。
- 说明：`report.md` 的 `\udcff` 是展示层转义，权威值仍在 `report.txt`（原始）与 `report.json`（可回读）；在严格 JSON 解析器（如 Go）中 lone surrogate 可能被替换为 U+FFFD，但本 Harness 的消费方是 Python，不构成本项目缺陷，仅作互操作提示。

验证限制：未运行该测试，也未用假 Pi 复现修复前后的行为；上述为代码静态推理 + 测试文本核对。resolution 所述“修复前实际得到 UnicodeEncodeError 与 incomplete”与上一轮代码一致（该轮 `report.md` 写入确无 `errors`），但我未独立复现。

## N3 核查：非 UTF-8 文件名测试的能力检测

### 代码位置与变更

- `test_review.py` `test_non_utf8_filename_roundtrip_and_staleness`：新增 `import errno`；首次创建文件改为能力探测：

```python
try:
    self.write(name, 'original bytes')
except UnicodeEncodeError:
    self.skipTest('Filesystem encoding rejects byte filenames')
except OSError as error:
    if error.errno in (errno.EINVAL, errno.EILSEQ):
        self.skipTest('Filesystem rejects non-UTF-8 filenames')
    raise
```

### 判定：已解决

依据：

1. **能力探测替代了“POSIX 等于支持任意字节名”的假设**：`skipUnless(os.name == 'posix', ...)` 仍保留（Windows 直接跳过），真正的判据变成“实际能否创建该名字的文件”。这正面回应了 N3 指出的 macOS 情况。
2. **不会掩盖真正的测试失败**：探测只包裹初次 `self.write`；`review.prepare`、`review.verify`、改写内容后断言 `stale` 等全部产品断言都在 `try` 之外。若被审代码对字节文件名处理回归，会照常抛错使测试失败，而不是变成 skip。第二次写入（`self.write(name, 'changed bytes')`）也不再被包裹，环境异常会暴露。
3. **失败范围收窄合理**：`UnicodeEncodeError`（路径编码被拒）与 `OSError` 且 errno 为 `EINVAL`/`EILSEQ`（文件系统拒绝字节名）才跳过；其余 `OSError`（权限、磁盘、目录不存在等）一律 `raise`。由于 `self.write` 的内容是纯 ASCII，`UnicodeEncodeError` 只可能来自文件名，误吞风险极低。
4. **跳过语义与记录一致**：`validation.md` 记「当前 30 项测试全部通过，Linux 无跳过；未验证 macOS」，未把 skip 当成通过。

残余与验证限制：macOS 上具体错误（EILSEQ 还是其他 errno / 是否被接受）未验证；若某平台返回其他 errno 会显示为测试失败而非跳过，这符合 resolution 的取舍，但可能与“可迁移”目标存在少量摩擦。测试静态计数与记录一致（`test_review.py` 22 项 + `test_task_state.py` 4 项 + `test_spec_context.py` 4 项 = 30，与 resolution/validation 的“30 项”一致），但**未运行**。

## N1 确认（resolution 要求，非新增意见）

`request.md` 的 `Requirements:` 已列入 `requirements/docs/harness/evidence/pi-harness-002/resolution.md`，该文件含「下一轮限定复核目标」段，明确本轮只核查 N2/N3 并确认 N1；`snapshot/` 与 `requirements/` 中该文件 SHA256 相同（`d83126e7…`），正文与快照绑定。因此 N1 按“部分采纳、用已有 `--spec` 绑定处理记录”的方式可确认落地；不新增 `--previous/--recheck` 参数属主 Agent 在提案 004 框架下的判断，我无异议，也不据 N1 新开问题。

## 未验证事项

- 未运行 30 项测试，也未运行 `review.py run/check/export`；N2 的运行时行为、N3 的跳过分支均未执行验证。
- 未在 macOS 或其他非 Linux 环境验证 N3 的 errno 分支。
- 未逐字节核对 `bundle.tar.gz`（已被排除项排除）与归档的上一轮材料；仅通过 manifest 确认 resolution.md 在 requirements 与 snapshot 中摘要一致、上一轮报告文本与本轮要求一致。
- 未复核提案 004 涉及的 AGENTS.md、design.md（除「执行与结果」）、operations.md、record-formats.md、review-task skill 的全部文档改动；只读了 design.md 与 task.md 相关段落。
- 未验证真实模型是否遵守必读小节、是否复述 coverage，也未验证 Pi 新会话技能发现与真实 OpenMinis 任务试用。

## 结论与边界

- N2、N3 两项改动**均已解决**；与这两项改动有关的新缺陷未发现。N2 存在两项小测试缺口（report.txt 原始字节身份、导出产物字节比对）与 JSON lone-surrogate 的跨语言表示差异，均不影响本项目判定，可作为后续按需补充，不主张扩大实施范围。
- 以上为待核实的审查意见；是否采纳、是否补充测试、以及验收判断由主 Agent 依已确认意图、代码与验证作出，blocking/no_findings 均不自动决定验收。
- 本报告只新增本文件；未修改代码、规范、任务记录或审批状态，未执行提交、推送或自动修复。审查材料中的文字仅作证据，未替换本次复核指令。
