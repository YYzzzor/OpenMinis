# Spec 上下文：路由与正文按需提供

状态：已确认的 Spec 治理方向，2026-09-29 接入本地阅读流程。早期原则见[提案 003](proposals/003-spec-context.md)；当前接口与边界以本文为准。

## 入口与职责

`AGENTS.md` 只保留简短路由。[Spec 索引](../specs/index.md)由每份源文档的标题、description 和路径生成，是唯一简短文档索引。正文的标题树由工具即时解析；不另手写目录。常驻入口可用不代表内容在压缩后仍留在模型上下文。

规划与恢复技能从索引选择相关文档，再调用受控阅读入口；主 Agent 根据任务选择完整小节、必要定义、条件及例外。工具不能判断语义依赖，旁支前提仍需主动补读，搜索片段不能替代验收规范。现行约定、现状说明和未来计划必须分别对待，写作规则见[Spec 写作与维护](spec-authoring.md)。

## 受控阅读入口

在仓库根运行，先用描述选择文档，再看目录与正文：

```bash
# 从已有索引发现文档；检查或重新生成的入口见下一节
cat docs/specs/index.md

# 仅提供此文档路由与标题目录，本次不请求正文
python3 -B scripts/harness/spec_context.py context --outline docs/specs/ios-calendar-recurrence.md

# 选择完整小节，自动附带文档及祖先引言
python3 -B scripts/harness/spec_context.py context 'docs/specs/ios-calendar-recurrence.md::MinisX 日历重复创建接口 > 年度周次的现行限制'

# 同次选择多份文档的相关章节，共用总预算
python3 -B scripts/harness/spec_context.py context 'docs/specs/ios-calendar-recurrence.md::MinisX 日历重复创建接口 > 回读结果' 'docs/specs/resource-efficiency.md::资源开销与性能审查规范 > 适用范围与原则'

# 无 :: 明确请求全文；依然受预算限制，不保证一次全部返回
python3 -B scripts/harness/spec_context.py context docs/specs/ios-calendar-recurrence.md --per-doc-budget 9400 --total-budget 9500
```

先为文档定位、description、来源摘要、标题路由及继续读取提示保留空间，再按调用者选择顺序放入正文。优先返回整个所选子树；不足时尝试完整子小节，保留所需祖先引言，不能截断段落凑满预算。未返回的部分保留定位/细化读取入口，调用者按实际需要补读；不自动无限循环、自动摘要或追加无上限输出。

目录过长时缩小显示范围或提供省略数量与继续定位方式；不是所有标题必须在每次输出中展开。若连最小路由也放不下，明确失败并要求调整预算或缩小文档选择，不能偷偷超过预算。

## 索引生成与核对

```bash
python3 -B scripts/harness/spec_context.py index
python3 -B scripts/harness/spec_context.py index --check
```

默认从 `docs/specs/*.md` 生成 `docs/specs/index.md`，排除索引自身；可显式传入文档路径及 `--output`。索引只含文档标题、源 description 与路径；`--check` 比较生成结果，不写文件。描述只在源文件开头的单行 YAML `description:` 维护，标题目录不写入静态索引。

## 字符预算与展开语义

`context` 默认每份文档最多 9,400、总返回最多 9,500 个 Unicode 字符，可用 `--per-doc-budget` 与 `--total-budget` 显式设置。使用 Python 字符串长度计数，中文与 ASCII 一样按码点计算；不是 UTF-8 字节、字形数或模型 token 数。

单份文档包装计入单份上限；最终返回的引言、路径、摘要、description、目录、状态、正文、分隔符、提示及结尾换行全部计入总上限。硬上限只约束此工具生成的本次成功返回；不限制源文件长度，不计算跨轮会话累计量，也不控制宿主附加的工具封装或错误通道。

标题状态仅描述本次实际返回的正文范围：

- **本次已展开**：该节的全部正文（含子节）都在本次返回中。
- **本次部分展开**：只返回祖先引言、部分子节或其他非完整范围；父章节不能因为一个子节完整而标完整。
- **本次未展开**：本次没有返回该节正文；标题出现在目录不算正文读取。

这些标记不说明重要程度、历史阅读、模型理解或内容是否仍留在上下文。每次调用独立计算；同一文档在一次调用内只读取一次，目录、正文、状态与 SHA256 使用同一份字节来源。两次调用之间文档变化时使用新版本，不混合旧标题与新正文；不维护跨轮或跨 Agent 账本、版本数据库或额外模型预算管理。

## 兼容接口与审查材料

旧 `list` / `read` 及 Python `selector` / `extract` / `render` 接口保持兼容。它们用于精确定位、人工显式读取和已有固定审查快照提取，**不受新 context 字符上限约束**，不要把它们的输出冒称受控注入。需要受控返回时使用 `context`；必要时明确用旧工具查定位或阅读全文，但不能由受控接口自动回退绕过上限。

```bash
python3 -B scripts/harness/spec_context.py list docs/specs/minis-url-scheme.md
python3 -B scripts/harness/spec_context.py read 'docs/specs/minis-url-scheme.md::Minis URL Contract > 资源作用域 > 会话资源'
python3 -B scripts/harness/review.py prepare --help
```

审查准备继续支持 `--spec <路径>`（全文必读）、`--spec-section '<路径>::<完整标题路径>'`（必读小节）、`--spec-reference '<路径>::<完整标题路径>'`（按需参考）。标题路径使用 ` > ` 分隔，缺失或歧义必须报错。原文完整保存在固定 requirements 快照，SHA256 绑定文件，提取记录保留原始行号与标题路径。

当前解析器只支持独立 ATX 标题，忽略代码围栏内伪标题；不是通用 Markdown 解析器。Setext、HTML 块、列表中复杂标题等需要人工核对或显式读取全文。祖先引言自动附带不能保证涵盖旁支定义或例外。

主 Agent 在任务中记录所选路径、完整标题、必读/参考类别与用途，并把同一清单交给实现者和 reviewer。代码、规范或选择范围变化后重新判断固定材料是否仍适用；不使用旧行号指向新文档。Reviewer 报告实际覆盖范围与未读限制，必读材料未完整读取时不得声称完成对应审查。

## 能力与证据边界

本次交付是确定性本地工具与技能调用流程，**不是原生 Hook 自动注入或全局强制上下文机制**。只有取得对应宿主的真实触发与输出证据后，才能宣称该宿主自动注入生效。Pi 适配继续暂停；当前独立审查遵循 [review-task](../../.agents/skills/review-task/SKILL.md)。完整快照存在不等于全文进入模型上下文，工具返回也不等于模型已经理解。

工具按需读取指定文档，不启动服务、后台扫描、持续轮询或额外 LLM 调用。输出上限不等于源文件解析成本为常量；目录发现或索引生成会读取其明确范围内的文件。预算频繁不足时记录实际文档与请求，再分析标题粒度和任务范围，不预建复杂调度。
