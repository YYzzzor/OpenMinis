# v1.13 与旧分支两项修复的对照

结论：v1.13 已实现两项问题的基础处理，但**没有完整包含旧分支补丁处理的边界**。因此不能把“新版也删除 thinking / 也实现上下标”视为原修复已全部覆盖。本轮只读检查和运行隔离探针，没有修改应用源码，也没有迁入旧补丁或测试。

比较对象：

- 旧分支 `74987c3bfc86cf1ccb93f7f1da05d5e5a7f53f94`：thinking 重试及提交边界。
- 旧分支 `00300d5291a11433ff54e14da8c4456ed401c7a1`：Unicode fallback 数学上下标。
- 新基线 `7414c0d6e8ec52e51d158f622e4379654872e7b5`，以及正在迁移的工作树。数学文件相对新基线没有修改；Chat 文件本轮名称等改动不涉及以下清理逻辑。探针输入的文件 SHA-256 已写入 `upstream-bug-probe-inputs.json`。

## Thinking 重试

一个重要区别：删除未提交 `.thinking` 的 `clearUncommittedStreamTail` 主体在 `74987c3` 的父提交中就存在。`74987c3` 的主要补充是维护提交边界，不能仅通过发现 `.thinking` 的过滤分支判定该补丁已被覆盖。

| 原修复覆盖的行为 | v1.13 证据与判断 |
| --- | --- |
| 保留已提交前缀，丢弃失败的 thinking/text 和仍在执行的工具，保留已完成工具 | `AIChatViewModel.swift:4710` 的现有 helper 实现这些分支；边界正确时基础行为覆盖。 |
| 提交计数大于当前块数时钳制，避免误删 | 同文件 4711 行使用 `max(0, min(...))`；基础防御覆盖。 |
| 模型 fallback 提示插入数组开头时同步当前和前次提交边界 | **未覆盖**。5316 行直接 `blocks.insert(infoBlock, at: 0)`，没有平移边界；旧补丁新增 `prependFallbackInfoBlock` 并同步两个游标。 |
| retry/resume 清理后立即同步两个提交边界 | **没有旧补丁的同步**。新代码在 2839–2844、2989–2992 行取得保留块数后启动新一轮；没有设置两个实例游标。 |
| rerun 使用已有消息或新占位消息时初始化边界；队列插入新消息时清零上次边界 | **没有旧补丁的全部处理**。3484–3506 行没有相应赋值；4288–4289 行只清零当前计数，没有清零 `prevCommittedBlockCount`。 |
| Stop 时区分 UI 提示与真实已提交模型块 | **仍是旧判定**。4574 行只判断 `prevCommittedBlockCount == 0`；没有旧补丁的 `hasCommittedModelBlock`。 |

最小可验证触发：消息为 `[已提交文本, 失败 thinking]`，提交边界为 1。新版将 fallback 提示插到开头后变为 `[提示, 已提交文本, 失败 thinking]`，边界仍为 1；下一次清理会把真正已提交的文本当作未提交尾部丢弃。旧补丁将边界加 1，可保留 `[提示, 已提交文本]`。

`upstream-retry-boundary-probe.swift` 原样提取新代码的清理 helper，使用最小消息类型和同样的插入操作运行。它只验证上述数组/边界结果，**没有运行完整 `AIChatViewModel`、真实 provider、Stop 或重试 UI**。其余游标/Stop 差异属于静态缺口，未据此声称每条路径均已在模拟器复现。

## 数学 fallback

新版采用真实 Unicode 上下标字符，字符不支持时使用缩小字号和 `baselineOffset`；旧补丁统一用排版属性。因此 `x_i^2` 在新版可能得到 `xᵢ²`，不能因它不同于旧测试的 `xi2` 属性串就判断显示错误。

| 旧测试覆盖的场景 | v1.13 判断 |
| --- | --- |
| 单字符、分组上下标，如 `x_i^2`、`a_{ij}^{10}` | 解析器正确标记，排版源码有 Unicode 映射与缩小/基线偏移；基础实现覆盖，未做本轮 UIKit 像素验证。 |
| 空/末尾脚本，如 `x^{}y_` | 隔离解析运行输出 `xy`，覆盖。 |
| `\frac{\text{a}}{\text{b}}`、`\sqrt{\text{a}+1}` | 隔离解析运行分别输出 `a/b`、`√(a+1)`，这些旧样例覆盖。 |
| `\_`、`\^` 保持字面字符 | **未覆盖**。解析器仍把转义后的 `_` 当脚本，并保留/误处理反斜杠。 |
| `\text{snake_case a^b}` 内脚本标记保持正文 | **未覆盖**。354–359 行先剥掉 text 包装，后续将 `_` 和 `^` 解释为脚本。 |
| `x^ 2+y_ 1` 跳过脚本标记与操作数间的空格 | **未覆盖**。509–514 行消费一个空格并丢掉标记，随后 `2`/`1` 保持普通正文。 |
| `x^\text{hi}` 将 text 内容整体作为脚本 | **未覆盖原边界**。包装先被剥掉，得到 `x^hi`，只把 `h` 作为上标，`i` 留在基线。 |
| 嵌套脚本去掉原始 `^`/`_` 标记 | 新版递归解析覆盖标记消除；混合嵌套方向的实际排版未做本轮验证。 |
| 20 pt、80 pt 上下标位图不裁边 | **未运行，不能认定等价**。新版 277–286 行加固定 3 pt 边距；旧补丁按 boundingRect 原点平移。需要 UIKit 图片/像素测试才能确认。 |

隔离运行直接提取新版 `latexToUnicode`、`markScripts` 与常量，保留原源码逻辑，使用 macOS Swift/Foundation 执行。日志将私有哨兵显示为 `<SUP>` / `<SUB>` / `</SCRIPT>`，代表解析阶段的脚本区间：

```text
escaped:        x\<SUB>l</SCRIPT>abel \caret
text literal:   snake<SUB>c</SCRIPT>ase a<SUP>b</SCRIPT>
whitespace:     x2+y1
command operand:x<SUP>h</SCRIPT>i<SUB>a\<SUB>b</SCRIPT>\c\</SCRIPT>
```

其中输入依次是 `x\_label \^ caret`、`\text{snake_case a^b}`、`x^ 2+y_ 1`、`x^\text{hi}_{a\_b\{c\}}`。这些是**实际执行的纯解析结果**；字体、图片裁剪和用户界面仍只有静态判断，未声称完成渲染验收。

## 现有测试的可运行范围

- 旧分支新增 `RetryThinkingBlockTests.swift` 4 项和 `SwiftMathRendererTests.swift` 11 项。新工作树没有这两个文件。
- 新代码不存在旧测试依赖的 `prependFallbackInfoBlock` 与 `fallbackAttributedString`，因此直接复制两份旧测试不能编译，数学测试的字符串/属性断言也需要适配新版合法的 Unicode 表示。
- 当前 `Minis` scheme 包含 `MinisTests`。`ToolPreflightTests.swift` 已有 `@testable import Minis`，说明旧提交附带的这项测试导入修正已存在；它不验证 thinking 或数学渲染。
- 本轮没有启动完整应用 XCTest 或模拟器 UI 测试，避免与主任务构建同时占用同一应用验证环境。实际执行的是上述两个仓库外隔离探针。
- 如需保留旧补丁全部边界，应作为明确的后续修复范围处理；本次迁移不应悄悄重放整文件，尤其新版数学渲染另外包含暗色模式和公式基线方面的上游改进。

## 附件

- `upstream-bug-probe-inputs.json`：源码摘要与样例输入。
- `upstream-math-parser-probe.swift` / `upstream-math-probe.log`：精确提取的解析源码与运行结果。
- `upstream-retry-boundary-probe.swift` / `upstream-retry-probe.log`：精确提取的清理 helper、最小消息类型与边界结果。

未读取其他任务归档正文；没有把旧记录中的验证结果作为本轮运行结果。
