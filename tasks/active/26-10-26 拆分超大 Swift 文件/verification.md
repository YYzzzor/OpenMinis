# 验证记录：拆分超大 Swift 文件

## 工具

- `tools/check_split.py`：V2 的检查脚本。比较基准提交与工作区之间所有改动过的 Swift 文件。运行：`python3 -I tools/check_split.py --self-test`（在仓库根目录运行时写完整路径）。
- `tools/build_warnings.sh <输出目录>`：用全新的 DerivedData 做模拟器 Debug 和 Release 两次完整构建，输出去掉路径和行号后的警告多重集合（`debug-warnings.txt`、`release-warnings.txt`）。V0 和 V3 使用。

V2 的规则 6（存储属性留在类型主体中）不由脚本检查。原因：Swift 不允许在扩展中声明实例存储属性，违反时 V3 的构建会失败。

## V0 基线（2026-10-26，`main` 提交 `fbc0aa4`）

**构建**
- 模拟器 Debug 完整构建：成功，1505 条警告。
- 模拟器 Release 完整构建（不签名）：成功，1434 条警告。
- 警告列表：`evidence/baseline/debug-warnings.txt`、`evidence/baseline/release-warnings.txt`。

**截图**（iPhone 17 Pro，iOS 26.4，UDID `A6D580D2-1D43-4307-BD75-8D7E3504E282`，Debug 构建）

| V6 步骤 | 截图 | 结果 |
| --- | --- | --- |
| 1 首页会话列表 | `evidence/baseline/1-home.png` | 显示 2 个会话 |
| 2 长对话滚到顶部 | `evidence/baseline/2a-top-code.png` | 用户消息、思考块、Swift 代码块正常显示 |
| 2 滚回底部 | `evidence/baseline/2b-bottom.png` | 编号列表末尾正常显示 |
| 3 发送消息，流式回复 | `evidence/baseline/3-streaming.png` | 回复逐步显示 |
| 4 表格和公式 | `evidence/baseline/4-table-math.png` | 3 列表格和块级 LaTeX 公式正常显示 |
| 5 设置 → 外观 → 语言列表 | `evidence/baseline/5-appearance-languages.png` | 语言列表正常显示 |

## V6 的操作步骤（拆分后按同样步骤重做）

以下命令中的 `R` 是 `.agents/skills/debug-server/examples/minis_rpc.py`，`D` 是上面的 UDID。

1. 安装本次构建的 Debug App，启动：`xcrun simctl install $D <Minis.app>`，`xcrun simctl launch --terminate-running-process $D com.yyzzzor.minisx`。
2. 首页截图：`python3 $R --png <文件> debug.screenshot '{"scale":0.5}'`。
3. 新建对话，点输入框：`debug.tap {"text":"发消息给 MinisX（@ 提及文件）"}`。
4. 输入提示词：`debug.inputText`，内容为：“这是界面测试，请直接回复，不要调用任何工具。回复依次包含：1) 一个 10 行的 Swift 代码块；2) 一个 3 列 6 行的 Markdown 表格；3) 一个块级 LaTeX 公式（二次方程求根公式）；4) 一个 40 项的编号列表，每项一句话。”
5. 发送：`debug.tap {"label":"发送"}`。约 6 秒后截流式回复。
6. 用 `chat.session.status` 等 `isRunning` 为 `false`。
7. 滚到顶部：`debug.scroll {"x":200,"y":300,"deltaY":500}` 执行 8 次，截图。
8. 向下滚一次：`debug.scroll {"x":200,"y":600,"deltaY":-380}`，截表格和公式。
9. 滚到底部：`debug.scroll {"x":200,"y":600,"deltaY":-500}` 执行 8 次，截图。
10. 打开外观设置：`xcrun simctl spawn $D defaults write com.yyzzzor.minisx pendingSettingsReopen appearance`，再重新启动 App。
11. 向下滚 4 次（`deltaY` 为 -500），用 `xcrun simctl io $D screenshot <文件>` 截语言列表。

注意：
- `debug.tap` 点不中首页工具栏的“设置”按钮。所以第 10 步用 `pendingSettingsReopen` 打开外观页。
- `xcrun simctl openurl` 会弹出系统确认框，debug-server 不能操作这个框。不得使用 `openurl`。如果弹出了，重启模拟器清除它。
- 发送消息调用真实模型（DeepSeek）。用户允许基线和最终检查各发 1 条（2026-10-26）。

## 批次 1：`CollectionViewMessageListV3`（2026-10-26）

实施：implementer 子代理。主会话复核了 V2 和 V3 的输出，以及工程文件的改动。

- V1 通过：原文件删除；新目录 `src/ios/Agent/MessageList/CollectionViewMessageListV3/` 中有 22 个文件，文件地图写在 `CollectionViewMessageListV3.swift` 头部。
  - 上游有、MinisX 没有对应代码的文件没有建：`BridgedToolGroupV3`、`Search/*`、`RetryLogSheet`、`ComposerShrinkAbsorption`、`QueuedCandidateSpacing`、`+ToolFolding`、`Support/MessageListV3HeightCache`。
  - MinisX 没有需要新文件的独有代码。
  - 目录设为同步文件夹；原文件的 `PBXFileReference`、`PBXBuildFile` 和 Sources 引用已删除。
- V2 通过：`check_split.py --self-test` 输出“反向测试：通过”和“无其他差异”（拆分前 1 个文件，拆分后 22 个文件）。
  - 例外：3 行顶层 `private typealias`（`+Setup` 和 `+Snapshot` 中的 `Section`，`+ScrollingScreenshot` 中的 `Coordinator`）。原因：代码移进 `extension CollectionViewMessageListV3.Coordinator` 后，`Section` 解析成 `SwiftUI.Section`，`Coordinator` 找不到，构建失败。别名恢复原来的名字解析。上游 1.15 在同样 3 个位置有同样的 3 行。检查脚本已改为允许这种“与嵌套类型同名的顶层别名”。
- V3 通过：Debug 和 Release 完整构建成功；警告列表与基线相同（Debug 1505 条，Release 1434 条）。
  - `build_warnings.sh` 改为把 DerivedData 路径换成 `<scratch>`，基线文件做了同样的替换。原因：2 条代码签名警告的文本包含 DerivedData 路径。
- V4 通过：`build-for-testing` 输出 `** TEST BUILD SUCCEEDED **`。
