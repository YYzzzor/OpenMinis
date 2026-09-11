# Spec 上下文：索引常驻，正文按需

状态：用户已批准加入 Harness；审批依据见 [提案 003](proposals/003-spec-context.md)。

## 常驻入口

`AGENTS.md` 的 Spec Index 保存文档路径和适用任务，是唯一维护的简短索引。正常加载项目指令的执行者先获得索引，不自动加载全部正文。常驻指项目指令入口可用，不保证模型在压缩后逐字保留；恢复任务时重新定位索引与本任务必读清单。

Pi 只读审查适配关闭项目上下文自动发现，因此不依赖 AGENTS.md 自动注入；审查请求明确携带本任务的必读与参考材料。完整项目目录被复制到快照，不等于全文进入模型上下文。

## 选择原则

1. 根据任务查看索引，再查看相关文档标题目录。
2. 将影响验收的规则记为必读，将辅助理解的材料记为按需参考。
3. 默认选取完整小节及其子小节，避免孤立抽取一句话或任意段落。
4. 保留文档名称、标题路径、适用范围、定义、条件和例外。相关约束若在别处，加入必读清单。短文档或无法确定语义范围时阅读全文。
5. 区分当前行为、已确认规范和未来计划。现有上游 docs/specs 内容不自动全部成为强制要求。

这些选择由主 Agent 根据任务意图负责判断，不能靠标题匹配工具判断语义完整性。工具可以提取小节，但不能推断跨章节依赖。

## 任务记录与交接

记录路径、完整标题路径、用途及必读/参考类别。例如：

```text
必读：
- docs/specs/minis-url-scheme.md :: Minis URL Scheme Specification > 3. Session Model
  用途：确认 URL 中会话信息的解释与隔离要求。
- docs/specs/minis-url-scheme.md :: Minis URL Scheme Specification > 10. Security Considerations
  用途：保留路径处理的相关安全条件。

按需参考：
- docs/specs/ios-sandbox-ish-summary.md :: iOS Sandbox Environment: iSH Virtualization Summary > 3. Mount System
  用途：理解路径与挂载的关系；内容需对照当前代码。
```

例子不表示当前 Harness 开发任务必须读取这些文档。主 Agent 将实际必读清单传递给 sub-agent 与 reviewer；恢复时先读取清单。学习场景可根据需要扩展解释，不改变规范适用范围。

## 审查材料与可追溯性

完整原文副本保留在固定 requirements 快照中，SHA256 绑定整个文件；必读小节内容进入审查请求，参考小节先仅提供定位信息。请求保存选取的标题路径、原文位置及摘要，跟随快照完整性校验。

自动提取需要跳过代码围栏内的伪标题，对不存在或歧义的标题拒绝静默猜测。自动保留祖先标题和引导正文是辅助措施，不能保证涵盖旁支章节里的定义或例外。请求发起者仍需选择依赖章节。

reviewer 在报告 coverage 中列明实际阅读的小节和额外展开范围，limitations 说明未读材料及其影响。必读内容无法完整读取时不得声称已完成相应审查。此阅读行为由 reviewer 报告，目前没有逐 token 的读取审计。

代码未变但原文或选取范围改变，同样需要重新准备审查输入。不能用过时行号引用新版文档；标题用于语义定位，摘要与快照用于确定版本。

## 适配入口

运行 `python3 scripts/harness/review.py prepare --help` 查看参数。

- `--spec <路径>`：整份文档必读，保留原有接口。
- `--spec-section '<路径>::<标题路径>'`：选取必读小节，可重复。
- `--spec-reference '<路径>::<标题路径>'`：登记按需参考小节，可重复。

标题路径使用 ` > ` 分隔，按实际标题文本定位。结构化提取的具体支持范围以脚本帮助和测试为准；不支持的 Markdown 结构直接阅读全文，不自动截取近似内容。

本地阅读也可使用：

```bash
python3 -B scripts/harness/spec_context.py list docs/specs/minis-url-scheme.md
python3 -B scripts/harness/spec_context.py read 'docs/specs/minis-url-scheme.md::Minis URL Scheme Specification > 3. Session Model'
```

当前工具只处理独立 ATX 标题（`#` 到 `######`），忽略代码围栏中的标题；完整标题路径缺失或重复时失败。它不是通用 Markdown 解析器：Setext 下划线标题、HTML 块或列表内复杂标题等结构应采用全文读取。祖先引言自动附带，旁支定义仍需手动选择。
