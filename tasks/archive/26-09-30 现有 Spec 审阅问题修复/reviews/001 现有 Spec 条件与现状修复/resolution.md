# 现有 Spec 条件与现状修复 — 主 Agent 处置

日期：2026-09-30（Asia/Taipei）。独立 reviewer：全新GPT-6-Astra medium，review_existing_spec_fixes，fork_turns=none。原始报告见report.md；固定文件版本由manifest.json和changes.patch绑定。

## 逐项处置

| 编号 | 状态 | 主Agent核实与判断 |
|---|---|---|
| S01 | 文档已修复 | 元数据和值、providers secrets导出及选择性恢复前提均写明；目标无既有值样本验收保留。 |
| S02 | 文档已修复 | 时间字段、聊天筛选和跨类别一致快照分开；保持产品取舍待确认。 |
| S03 | 文档已修复 | 严格路径要求与当前任意其他POST进入RPC的差异同节可见；未误报认证绕过。 |
| S04 | 文档已修复 | 上下文快照、实际token、费用估算和账户余额分开；未宣称现有账本已统一归因。 |
| S05 | 文档已修复 | fetch为browser，原生下载为workspace；写盘结果仍需实际检查。 |
| S06 | 文档已修复 | 空链System路径及不同原因未区分的现状已写明，降级语义仍待确认。 |
| S07 | 文档已修复 | 普通UI排除voice_corrections，显式调用路径仍保留。 |
| S08 | 文档已修复 | 正式iOS26范围与历史availability分支分开。 |
| S09 | 文档已修复 | 现存Provider、语音、同步Spec以用途链接取代未来措辞。 |
| S10 | 文档已修复 | zone/类别入队前提与暂停发送区别明确；补齐不声称已验证。 |
| H01 | 文档已修复 | 更新精确选择器并实际读取；无旧标题依赖。 |
| H02 | 文档已修复 | 被抽取小节保留就近已知偏差链接，不把规范要求当全面现状。 |

Reviewer判断：12项充分，无新增或残留确定文档错误。主Agent根据已确认范围、实际源码核实、工作区静态检查、固定报告及最终版本一致性，同意完成本轮有限文档修复。不是仅凭no_findings接受，也不是全产品功能验收。

## 证据与限制

主Agent在实际工作区执行索引、outline、17项完整章节、130处链接、tracked/untracked whitespace及无关内容基线核对；reviewer独立核对39份固定文件哈希和五个关键小节抽取，并定向核对源码。各自证据范围没有互换。

固定材料持久副本：/Users/huyuanzhao/.codex/.chatgpt-projects/g-p-6aa8f27e863c8191be6cf501db847b1a/artifacts/spec-reviews/2026-09-30-existing-spec-fixes 。其manifest原字节及39份文件SHA与临时审阅对象相同。

缺失Spec G01—G03未实施。现有产品缺陷、待验证行为和未决语义保持开放，不因文档归档升级为已修复/已运行。未构建、测试、模拟器、真机、远端、提交或推送。

## 并行工作区变化

归档前发现并保留了一项并行改动：AGENTS.md 的代码审阅模型从 GPT-6-Astra medium 改为 GPT-6.1-Sol high。本轮未修改该文件。原始审阅按委派时规则完成；本轮仅修正文档，未涉及代码审阅，当前 review-task 和 collaboration 仍保留原审阅指引，因此不为此重复审阅或修改共用规则。最终核对中12份修订文档及17份审阅源码均与固定材料一致，其余38份基线文件未变；AGENTS 的并行版本另存哈希，以免错误归因。原始报告、清单与首轮静态记录保持原字节。
