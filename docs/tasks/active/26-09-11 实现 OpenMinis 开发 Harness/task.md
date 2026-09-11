# 26-09-11 实现 OpenMinis 开发 Harness

状态：blocked（用户决定将剩余真实代码修改与 iOS 运行验证延后至迁移 Mac；已通过结果保留）
更新：2026-09-11

## 恢复信息

- 分支：`ios-annotated`。
- 开始实施前 HEAD：`8399e1f`，`docs(ios): annotate chat send entry point`。
- 此提交保存了用户原有 AIChatView.swift 注释；仅清理一处行尾空格，无运行行为变更。未推送。
- 用户已要求为 Mac 拉取准备提交：本批 AGENTS.md、共享 skills、脚本、测试、Harness 文档与证据及真实分析交付纳入本次提交。实际提交与推送状态以 git log/status 和 origin 为准。
- 下一步：等待用户将项目迁移到 Mac 后恢复；先核对新路径、分支、HEAD、未提交工作、工具配置与检查点差异，再按实际任务核实 Xcode/设备条件，继续真实代码修改、检查、Pi 审查及运行验证。首个真实分析试用已通过，不重做同一调查，不把运行验证标为完成。
- 首轮实际审查：用户在已打开的 Pi 中选择 deepseek-flash，已返回固定快照报告。本轮未由 Codex 另行外发或再次调用模型；既有自动审批拒绝保留为历史，不推断为任意后续外发授权。

## 目标与验收

用户需要轻量、可迁移、跨 Codex 与 Pi 的开发 Harness，具备跨会话恢复和受控改进。

- [ ] 新会话无需原聊天即可核实代码状态并继续正确任务。
- [ ] 主 Agent 检查后可调用 Pi + DeepSeek 独立审查。
- [x] 报告绑定代码快照、Git 状态和需求依据，保存原始意见与处理结果。
- [ ] 调用失败、残缺报告、未验证行为不被标记通过。
- [ ] 当前任务自动纠偏；影响后续任务的规则变更先由用户审核。
- [ ] 普通小修改不强制复杂任务流程；按需委派有边界的工作。
- [ ] 完成临时工作区验证以及双方工具的实际兼容性检查。
- [ ] 两三个真实 OpenMinis 任务试用后记录效果与限制。

## 已确认决定

- 排除 Superpowers；保留 Spec 思路，暂不引入完整 Trellis。
- 主 Agent 负责目标与验收，实现按需委派；Pi 不是必须采用内部 sub-agent 协议的执行者。
- 主 Agent 先检查，再由 Pi 独立审查，主 Agent 核实意见并修复、验证。
- 报告必须绑定 Git 状态及实际代码版本；需求版本也固定。
- 自动更新当前任务；共用规则变更先提供计划、原因供用户审核。
- 使用自带 skill-creator；共享格式与工具适配分离。
- 其他项目的科学计算案例不作为本项目领域要求。
- 用户要求先提交原有工作，已完成；之后又明确要求为 Mac 拉取准备 Harness 提交，本批保存已获授权。
- 用户批准按 GPT-6 Astra 指导完成六项文档调整：教学触发、自主执行、CodeGraph 回退、验证停止条件、委派标准、分支范围。见 [提案 002](../../../harness/proposals/002-instruction-scope.md)，已实施；不扩展 DeepSeek 外发授权。
- 用户批准 Spec「索引常驻、正文按需、默认按小节」设计；见 [提案 003](../../../harness/proposals/003-spec-context.md)。必读/参考区分并随委派与审查传递，完整原文仍固定版本。三份上游 Spec 正文不变。

- 用户明确批准 Pi 结论需核实、不能直接决定验收；[提案 004](../../../harness/proposals/004-review-judgment.md)已实施，同步 AGENTS.md、review-task skill 与设计/记录约定。主 Agent 的不采纳同样需有依据。

- 用户指定任务命名为 `YY-mm-dd Name`；当前目录由 `2026-09-11-harness` 更名为 `26-09-11 实现 OpenMinis 开发 Harness`，历史报告与快照保留原路径。见 [提案 005](../../../harness/proposals/005-task-naming.md)。

## Spec 阅读清单

此 Harness 任务不依赖应用领域 Spec 的行为条款。必读设计依据为 docs/harness/spec-context.md 的「选择原则」「审查材料与可追溯性」及提案 003；审查处理与验收判断另必读提案 004；docs/specs 下的文件仅用作目录与小节提取的真实样例，不据此改变应用行为。

## 实施计划

- [x] 检查分支、差异并提交原有工作。
- [x] 固化设计、任务与报告格式、具体规则提案。
- [x] 用户审核提案 001 后启用最小入口。
- [x] 实现共享恢复 skill 与检查点支持。
- [x] 核验本地 Pi/Codex 版本和 DeepSeek 配置，不暴露凭据。
- [x] 实现隔离快照、审查请求、Pi 调用与原始报告保存。
- [x] 实现意见处理、失败状态和针对性复审。
- [x] 完成提案审批状态与纠偏记录的隔离行为验证（先纠偏与提案、模拟批准后限定实施）。
- [x] 在临时工作区测试恢复、中断、Git 脏状态、失败和规则边界。
- [x] 完成用户批准的六项 AGENTS.md 调整并同步设计；检查两项共享技能，无需改动。
- [x] 实现提案 003 的 Spec 索引、必读/参考小节输入及版本绑定，完成本地验证。
- [x] 完成 Pi 正常新会话只读恢复初步验证。
- [x] 完成 Codex 真正的新对话正常状态只读恢复初步验证（不以 sub-agent 替代）。
- [x] 独立隔离案例验证过时记录、保留未提交代码、未批准提案不生效及恢复后验证续接。
- [x] Pi 显式使用 review-task 独立审查合成样例并由主 Agent 核实意见。
- [ ] 进行真实任务试用，更新实际效果与限制。

## 验证与环境

- 原有注释提交前 `git diff --check` 通过；纯注释未执行 iOS 构建。
- 用户确认本机为 WSL；此前记录中的 Linux 指该环境。可找到 `/home/huyz/.local/bin/pi`、`/home/huyz/.local/bin/codex`、Python 和 Node。
- Pi 0.85.1，已配置 DeepSeek/deepseek-v4-pro；真实小样例审查成功，未泄露凭据。
- 基础机制阶段曾通过 20 项测试；两项技能格式检查及独立恢复前向验证通过。
- OpenMinis 实际仓库快照准备成功，显式排除 deps/ish 与 deps/proot，未将其内部代码纳入审查。
- 详见 [验证记录](../../../harness/validation.md) 和 [操作说明](../../../harness/operations.md)。
- 提案 002 为纯文档调整；提案 003 增加小节提取及审查输入脚本。该阶段 27 项测试通过，实际文档提取通过；上游 Spec 正文不变。更新检查点后核实与工作区一致，旧审查快照不覆盖此次改动。

- 首轮 Pi 报告有 5 项非阻断意见，主 Agent 已逐项处理；该阶段 29 项测试通过，原问题已获第二轮独立复审。见 [处理记录](../../../harness/evidence/pi-harness-001/resolution.md)。

- 第二轮新增意见经主 Agent 判断：N1 用已有 --spec 完成交接，N2 已复现修复，N3 改为能力探测。当前 30 项测试通过，两个小改动的最终针对性复核已完成。见 [第二轮处理记录](../../../harness/evidence/pi-harness-002/resolution.md)。用户说明模型为 DeepSeek-V4.1-flash，Pi 自报别名 deepseek-flash。

- 最终复核：主 Agent 验证新快照绑定并结合此前运行证据，关闭 N1/N2/N3。实现审查闭环完成，整体试用验收未完成。见 [最终处理记录](../../../harness/evidence/pi-harness-003/resolution.md)。

- Pi 正常新会话恢复初步通过：用户返回报告，主 Agent 独立核验旧检查点 match；Pi 自报自动发现两项 skill 并实际读取 resume-task，review-task 执行未验证。见 [评估记录](../../../harness/evidence/pi-recovery-001/assessment.md)。Codex 真正的新对话恢复为用户新增必验项，现已完成下述正常只读演练。

- Codex 正常新对话只读恢复初步通过：目标、进展与边界识别正确；主 Agent 独立核验旧检查点 match。见 [评估记录](../../../harness/evidence/codex-recovery-001/assessment.md)。双方恢复后实际续接与异常场景尚未验证，整体验收仍开放。

- 隔离恢复续接案例通过：独立执行者识别 changed，保留正确实现和未跟踪笔记，运行 2 项测试并纠正任务；提案未生效、任务未关闭。主 Agent 核验仅任务与检查点变化，最终 match。见 [评估记录](../../../harness/evidence/recovery-drift-001/assessment.md)。这不是 Pi 客户端异常恢复测试，也不替代真实应用任务试用。

- Pi review-task 实际执行验证材料已准备：`/tmp/openminis-pi-skill-review-uvjx3_0g/review`，快照 `bbf4d90126da137d09d7d84a62e690dd60cafb26ef27b00d0faf3ef6296ded67`。报告已返回，显式独立审查初步通过；模型版本未在本轮报告确认，范围外建议不采纳。见 [准备记录](../../../harness/evidence/pi-skill-review-001/preparation.md)。

- Pi review-task 执行结果见 [处理记录](../../../harness/evidence/pi-skill-review-001/resolution.md)：主 Agent 穷举 400 个有效输入确认 R1，R2 部分接受、R3 范围外不采纳。样例不修复，不扩大本轮审查。

- 主动纠偏与审批两阶段隔离演练通过：批准前仅纠正任务并提出具体方案；模拟批准后精确替换指定指导，未扩展范围，未关闭缺失集成验证的任务。主 Agent 独立文件核对与最终 inspect 通过。见 [评估记录](../../../harness/evidence/rule-approval-001/assessment.md)。

- 首个真实分析试用完成：findings.md 关键判断与抽查代码/Apple 官方文档一致，保留真机限制；未强制 Pi 审查、未修改应用或共享规则。见 [试用评估](trial-001-assessment.md)。

## 参考入口

- [设计](../../../harness/design.md)
- [记录格式](../../../harness/record-formats.md)
- [规则提案](../../../harness/proposals/001-bootstrap.md)

## 阻塞与审批

2026-09-11 用户说明本机为 WSL，决定剩余真实代码修改/实现验证待整个项目迁移到 Mac 后开展。当前不启动该验证，也不因环境限制降低验收。解除条件为用户完成迁移并具备对应任务所需的构建/运行条件；这不是新增规则审批。

迁移前确认本批 Harness、任务与证据文件已提交并推送至 origin/ios-annotated；Mac 拉取该分支后核对这些文件齐全。历史 /tmp 路径是来源记录，不假定 Mac 上存在，已归档材料从仓库内读取。新环境差异先核实再更新检查点，不为获得 match 撤销工作。检查点保留提交前核验状态；提交及迁移导致 HEAD、index、路径等差异属于需核实的预期变化，不追求提交后的自引用 match。当前会话仅执行已获授权的保存操作，推送状态另行确认。


用户于 2026-09-11 明确批准提案 001。早期由 Codex 发起的实际 Harness 项目文件 DeepSeek 调用被自动审批拒绝；未绕过。之后用户自行在 Pi 完成首轮审查，原始报告及完整快照已归档于 docs/harness/evidence/pi-harness-001。临时实现快照位于 /tmp/openminis-harness-review-001（临时路径可能失效，恢复时核实并必要时重新准备）。真实小样例材料已持久化到 docs/harness/evidence/pi-smoke-001。

需要后续真实任务验证的语义边界仍未标完成；不以脚本测试通过代替整体 Harness 验收。

## 迁移提交检查

暂存区完整 diff --check 发现历史 pi-harness-002/request.md 和 pi-harness-003/request.md 的 Markdown 空引用行含行尾空格；为保持原始快照哈希，保留其字节。排除这两份固定证据后的其余暂存内容检查通过。此为本次历史材料处理记录，不新增通用检查豁免规则。
