# 验证记录

## 2026-10-03 规划阶段

本轮证据只覆盖 Git 状态和源码阅读。没有修改产品代码，没有构建或运行应用。

### 已确认的事实

| 检查 | 结果 | 证据入口 |
| --- | --- | --- |
| 当前开发基线 | 主工作区原先位于 optimize_web_search；建分支前没有未提交改动。 | 本轮 git status --short --branch 输出。 |
| 新分支 | feat/chat-mermaid-rendering 已从当前 HEAD 建立并切换成功。 | 本轮 git switch 输出；基线为 b51aa64c8427e2d79e2c6d641d85b8ee114bba52。 |
| 助手 Markdown 入口 | 助手文本块使用 SelectableMarkdownView。 | src/ios/Views/Chat/AssistantBlockView.swift:114–128。 |
| 代码块解析 | 解析器保留 fenceInfo 与 content。 | src/ios/Agent/Markdown/MinisMarkdownParser.swift:708–709。 |
| 现有代码块展示 | 所有代码块进入 renderCodeBlockAttachment，构造普通 CodeBlockAttachment。没有 Mermaid 特殊处理。 | src/ios/Views/Chat/SelectableMarkdownView.swift:521–522、649–685；限定 src/ios 的 Mermaid 搜索。 |
| 用户气泡边界 | 用户消息采用 Text(message.content)，与助手 Markdown 入口不同。 | src/ios/Views/Chat/ChatMessageViews.swift:289、333。 |
| 可参考的本地转换路径 | KaTeX 使用应用内脚本和 WKWebView 生成图片。只作为技术路径参考，不作为 Mermaid 隔离或性能证据。 | src/ios/Agent/Markdown/KaTeXRenderer.swift。 |
| 两条附件显示路径 | MarkdownRenderView 和 SelectableMarkdownTextView 分别维护代码块与其他附件视图。 | src/ios/Views/Chat/MarkdownRenderView.swift；src/ios/Views/Chat/SelectableMarkdownView.swift。 |
| 历史内容与显示数据区别 | 原始消息、Provider history 和显示表示必须保持各自的数据契约。 | docs/specs/ios-agent-run-lifecycle.md，O1。 |
| 官方接口 | Mermaid 提供源码转换为 SVG 的接口；安全配置与文本上限均有官方说明。 | task.md 的官方参考。 |

### 检查边界

- 当前结论是静态源码事实，未补做“Mermaid 只显示代码”的模拟器复现。
- 本地 SVG 转位图及全屏清晰度属于拟议方案，尚未验证。
- 当前改动仅为任务文档，没有新增应用运行时资源开销。
- 独立审查在产品实施后执行；纯规划文档本轮不触发强制独立审查。

### 文档检查

已通过：保存文件与确认稿逐字一致，相对链接有效，代码围栏成对，Markdown 无尾随空白。task.md 为 14,225 字节，符合任务大小建议；M1–M16 编号完整。git diff --check 通过；新增未跟踪文件的空白另由逐行检查覆盖。

### 产品验收

task.md 的所有产品验收项保持未勾选。测试、构建、模拟器行为、真机表现和维护者接受度分别记录，不相互替代。


## 2026-10-03 补充确认要求

- 用户提出学术、专业、克制的样式要求，具体灰度方案尚待确认。
- 用户说明每个对话图表数量较少，要求尽可能节约资源。计划将渲染器调整为按需启动、可见批次结束后立即释放，并收紧图片与缓存预算。
- 用户要求双方确认后才开始实施。任务继续保持待确认，未建立拟议 Spec，未修改产品源码，未委派实施或引入 Mermaid 运行库。
- 学术灰度样例属于外观确认材料，手工绘制流程图与时序图，不是正式 Mermaid 引擎或 iOS 运行证据。
- 原有文档检查结果属于上一版。新一版规则为 M1–M23，新增 M17–M23；当前版本检查已通过：任务文档为 17,920 字节，M1–M23 连续且无重复，代码围栏成对，相对链接有效，Markdown 无尾随空白。

- 样式示意已检查流程图和时序图的浅深色，在 768、360、320 像素宽度下没有脚本错误或标签越界；浅深色截图已目视核查。该结果仅证明样式示意，不证明正式 Mermaid 或 iOS 显示效果。


## 2026-10-03 取消与归档

- 用户明确取消本次任务，以便处理更紧迫的工作。
- 取消前，Mermaid 分支与 optimize_web_search 指向同一提交；Mermaid 分支没有新增提交，暂存区与产品源码没有改动。
- 工作区只有本任务的 task.md 和 verification.md 两份未跟踪文件；本次归档只处理该目录。
- 没有建立 docs/specs/ios-chat-mermaid.md，Spec 索引也没有 Mermaid 条目，因此无需恢复生效规则或删除拟议 Spec。M1–M23 仅保留在已取消计划中作为历史参考。
- 所有产品验收项保持未勾选，未完成原因均为取消前没有进入产品实施阶段。
- 任务目录归档至 tasks/archive/26-10-03 聊天内 Mermaid 图表渲染；归档不创建提交。
