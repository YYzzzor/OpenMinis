# 26-09-21 数学公式上下标 fallback 修复

状态：done
更新：2026-09-21 21:02 CST

## 恢复信息

分支：`feat/minisx-branding`
最近核验 HEAD：`74987c3`
工作区：本任务修改 `SwiftMathRenderer.swift`，新增 `SwiftMathRendererTests.swift` 及本任务记录；另有无关未跟踪文件 `tasks/active/26-09-21 MinisX TestFlight 身份与签名准备.md`，未修改、未纳入审查。
下一步：无；实现与验收已完成，等待用户决定是否提交。
待审批：无；用户已授权本项目今后按既定 Harness 流程直接交给 Pi 做只读代码审核，无需逐次询问。

## 目标与验收

修复 SwiftMath 主渲染失败后，Unicode fallback 把 LaTeX 的 `^`、`_` 和脚本文本显示成普通基线字符的问题。

- [x] fallback 输出不再显示 LaTeX 的 `^`、`_` 和脚本分组花括号。
- [x] 单字符及 `{...}` 分组的上标使用较小字号并上移基线。
- [x] 单字符及 `{...}` 分组的下标使用较小字号并下移基线。
- [x] SwiftMath 主渲染、Markdown 数学识别和其他 Markdown 内容保持不变。
- [x] 新增定向单元测试并通过 iOS Simulator 构建与测试。

## 上下文与决定

- `SwiftMathRenderer.render` 是首选路径，能正常排版上下标。
- `SwiftMathRenderer.renderFallback` 在首选路径失败时调用 `latexToUnicode`；现有实现明确保留 `^`、`_`，随后 `buildAttributedString` 对所有字符使用同一基线，因此问题真实存在且只在 fallback 条件下“偶尔”出现。
- `MathAttachment.performRender` 当前没有调用 `KaTeXRenderer`；恢复 WKWebView 异步 fallback 会扩大生命周期、缓存和刷新范围，本任务不采用。
- 采用原生 attributed-string 修复：解析脚本标记，为脚本文本设置缩小字体和 `baselineOffset`，保持同步渲染链不变。

## 实现计划

- [x] 将 Unicode fallback 的纯文本构建改为可识别上标、下标及分组。
- [x] 调整 fallback 图片测量/绘制边界，避免基线偏移后的脚本被裁切。
- [x] 新增针对单字符、分组和实际 fallback 入口的回归测试。
- [x] 运行定向测试、App 构建及 `git diff --check`。
- [x] 通过 Harness 请求独立 Pi 审核并处理意见。

## 进展与验证

已完成最小实现：只修改 Unicode fallback 的 attributed-string 构建与图片边界，未改 SwiftMath 主渲染、Markdown 识别或附件生命周期。

验证结果：

- iOS Simulator App 构建通过（Xcode 27，iOS 27 Simulator，部署目标仍为 iOS 26）。
- 初次实现的 `SwiftMathRendererTests` 4/4 通过。
- 根据 Pi R1-R3 补齐空脚本、命令分组、组内转义和图片透明边界验证后，`SwiftMathRendererTests` 6/6 通过。
- 根据第二轮 Pi R1、R2、R4 保留 text 命令内字面 `^/_`、支持转义字符作为单个脚本参数，并增加图片必须包含非透明内容的正向断言；`SwiftMathRendererTests` 8/8 通过。
- 第二轮 R3 不采纳：报告把绘制矩形原点直接当作最终字形边界，忽略了它会与测量边界的 `minX/minY` 抵消。新增 80pt 大字号上下标像素验证，图片有非透明内容且四边均无非透明像素。
- 第三轮 Pi 发现 text 命令使用普通花括号分组会干扰既有 `\\frac`/`\\sqrt` 正则，此项为中等风险且成立；已改用内部私有分组标记，并补齐嵌套脚本及脚本参数前空白处理。`SwiftMathRendererTests` 11/11 通过。
- `git diff --check` 通过。

## 阻塞与纠偏

首次 Harness 审查结论为 `nonblocking`，提出 3 项低风险意见：图片边界缺少像素验证；空/末尾脚本仍会显示语法标记；命令分组和组内转义处理不完整。主 Agent 核实后全部采纳并修复。

第二轮 Harness 审查结论为 `nonblocking`，提出 4 项低风险意见。R1、R2、R4 已核实并修复；R3 经运行验证不成立，理由见验证记录。旧快照因后续代码和任务记录更新而正常变为 stale，原始报告仍保存在仓库外的持久 bundle 中。

第三轮 Harness 审查结论为 `blocking`：R1 为 text 分组对分数/根式的既有语义回归，R2/R3 为嵌套脚本与空白脚本参数边界。三项均已核实并修复，新增测试全部通过；等待修复后复审。

第四轮 Harness 审查结论为 `nonblocking`。3 项剩余意见分别涉及私有 Unicode 区冲突、原本就不支持的多行 LaTeX fallback，以及缺失脚本参数的非法公式；均不影响本任务已确认的有效输入范围，具体理由和验证见处理记录。

## 审查

首次报告：`openminis-math-script-fallback-001`，结论 `nonblocking`，R1-R3 已处理。

第二轮报告：`openminis-math-script-fallback-002`，结论 `nonblocking`，R1、R2、R4 已修复；R3 不采纳并补充运行证据。等待最终复审。

第三轮报告：`openminis-math-script-fallback-003`，结论 `blocking`，R1-R3 已修复；等待最终复审。

最终报告：[reviews/004/report.md](reviews/004/report.md)，结论 `nonblocking`。

处理记录：[reviews/004/resolution.md](reviews/004/resolution.md)。主 Agent 验收通过；没有未解决的实质问题。
