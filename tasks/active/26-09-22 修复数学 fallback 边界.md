# 26-09-22 修复数学 fallback 边界
状态：planned
更新：2026-09-22 00:37 +0800

## 恢复信息
分支：后续从 MinisX main 创建修复分支；本轮仅登记。
核查来源：官方 v1.13 7414c0d + 已验收的 MinisX 迁移。
下一步：等待用户启动修复；先复现下列边界，再适配旧补丁及测试。
待审批：用户明确“旧的 bug 先记录一下，后面我会修正”；当前没有修复授权，不自动执行。

## 问题与已知证据
v1.13 已有基本上下标，使用 Unicode 字符或缩小字号/基线偏移，但仍未覆盖旧补丁的解析边界：
- `x\_label \^ caret`：转义的 `_` / `^` 应按字面显示。
- `\text{snake_case a^b}`：text 内容中的下划线和乘方标记应保留为正文。
- `x^ 2+y_ 1`：脚本操作符后的空格不应导致上下标语义丢失。
- `x^\text{hi}`：整个 hi 应作为上标，不能只处理 h。
- 嵌套脚本、20 pt / 80 pt 位图裁切：尚未完成本轮 UIKit 像素验证，不能先认定通过或失败。

旧参考提交：00300d5291a11433ff54e14da8c4456ed401c7a1（保留在 feat/minisx-branding）。
主要入口：src/ios/Agent/Markdown/SwiftMathRenderer.swift；按 latexToUnicode、markScripts 和 fallback 图片排版入口定位，不依赖旧行号。
迁移期间已原样提取相关解析函数执行 Swift 探针，上述前四类解析边界可复现；未把纯解析输出等同于完整 UIKit 显示结果。

## 后续验收要点
- [ ] 转义、text 字面量、空格、命令整体脚本、分组/嵌套脚本正确。
- [ ] 保留 v1.13 新增的暗色模式、基线及合法 Unicode 上下标行为。
- [ ] 适配旧 SwiftMathRendererTests.swift 的11项测试；不能直接复制旧字符串断言而否定新版合法排版。
- [ ] 验证不同字号位图不裁边，并检查实际 UIKit/聊天显示。
- [ ] 完成相关测试、构建和 Harness Pi 审查；明确哪些仅静态或隔离验证。

## 指定证据
本任务后续修复明确需要以下迁移归档材料，允许按具体文件读取，不加载其他归档：
- [两项旧 Bug 对照](<../archive/26-09-21 迁移 MinisX 到上游 v1.13/upstream-bug-comparison.md>)
- [数学解析探针](<../archive/26-09-21 迁移 MinisX 到上游 v1.13/upstream-math-parser-probe.swift>)

## 进展
2026-09-22：只登记未修复问题，没有修改渲染实现或迁入旧补丁。
