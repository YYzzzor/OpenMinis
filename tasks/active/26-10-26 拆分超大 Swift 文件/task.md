# 26-10-26 拆分超大 Swift 文件

状态：active（用户确认于 2026-10-26）　｜　规则：`docs/project-guide.md`“Git 与上游”最后一条（G1）；不新增、不修改 Spec 规则，Spec 中“代码入口”链接随代码位置更新　｜　验证：[verification.md](verification.md)（实施时创建）

## 目标

完成后：

- MinisX 中 6 个超过 5000 行的 Swift 文件，按上游 OpenMinis 1.15 的文件地图拆成按职责划分的小文件。
- App 的行为与真机 Release 构建的运行效率不变。用户在手机上使用时，感觉不到区别。
- 以后从上游移植功能（第一个是 Ask User）时，上游的一个文件能直接对应 MinisX 的一个文件。

要拆分的文件（行数为 `main` 在 2026-10-26 的值）：

| 批次 | 文件 | 行数 | 上游 1.15 的位置 |
| --- | --- | --- | --- |
| 1 | `src/ios/Agent/MessageList/CollectionViewMessageListV3.swift` | 5313 | `Agent/MessageList/CollectionViewMessageListV3/`（约 35 个文件） |
| 2 | `src/ios/Agent/Chat/AIChatViewModel.swift` | 6773 | `Agent/Chat/AIChatViewModel+*.swift`（上游 37 个，MinisX 已有 21 个），以及 `Agent/Chat/LLMProviderError.swift` |
| 3 | `src/ios/Agent/Chat/ChatStore.swift` | 7506 | `Agent/Chat/ChatStore+*.swift`、`ChatStoreModels.swift`、`ContentPart+ProviderConversion.swift`、`RawMessage+Conversion.swift` |
| 4 | `src/ios/Views/Chat/AIChatView.swift` | 6412 | `Views/Chat/AIChatView/`（37 个文件） |
| 5 | `src/ios/Views/ContentView.swift` | 8085 | `Views/ContentView/`（33 个文件），以及 `Views/Settings/SettingsSheet.swift`、`Views/Settings/AppearanceSettingsView.swift` |
| 6 | `src/ios/Views/Chat/SelectableMarkdownView.swift` | 9410 | `Views/Chat/Markdown/`（约 35 个文件） |

不做：

- 不改变任何逻辑、界面或数据格式。
- 不合入上游 1.14 或 1.15 的功能代码，也不移植 Ask User。Ask User 在本任务完成后另建任务。
- 不拆分其他大文件，例如 `ProviderConfigStore.swift`（3386 行）和 `DebugJSONRPC.swift`（3280 行）。
- 不修改被移动代码中的已有注释，包括写了旧文件名的注释。上游也没有改这些注释。
- 不做性能优化。性能优化如果需要，另建任务并单独测量。

## 方案

### 路线：逐个文件，按上游的文件地图移动代码

上游在 1.15 中做了同样的拆分。上游拆分后的主文件头部写有“文件地图”，说明每个新文件放什么代码，例如 `1.15:src/ios/Agent/Chat/ChatStore.swift` 第 9–64 行。

MinisX 的这 6 个文件来自上游 1.13，再加上 MinisX 自己的 1046 行改动（`git diff --stat 1.13 main`）。本任务按上游 1.15 的文件地图，把 MinisX 当前的代码移到对应的文件中。

选择这条路线的理由：

- 文件名和边界与上游一致时，以后移植的代码能直接放进对应文件，冲突最少。
- 上游已经验证过这些边界能编译、能运行，MinisX 不用自己设计边界。

未采用的方案：

- ✗ 自己按职责设计拆分边界：边界与上游不同，以后每次移植都要重新对照文件位置，失去这次拆分的主要价值。
- ✗ 先合入上游 1.14 和 1.15，直接得到拆分后的文件：会同时引入大量功能改动，冲突多，也不能保证“只移动代码”。

### 批次顺序

1. 批次 1 先做 `CollectionViewMessageListV3`。理由：MinisX 只有 1 个提交改过它，风险最低，用来验证做法和检查脚本。
2. 批次 2–3 做 `AIChatViewModel` 和 `ChatStore`。理由：上游 Ask User 改到的拆分文件，集中在这两个类型和 `CollectionViewMessageListV3` 中。
3. 批次 4–6 做 `AIChatView`、`ContentView`、`SelectableMarkdownView`。理由：Ask User 不改它们；聊天内搜索和数据管理会用到它们。

每批结束时，必须先通过本批的验证（见“验收”），再开始下一批。某一批失败时，只回退这一批。

### 移动时的约束

以下约束只用于本任务的实施和审查。

- **C1 只移动代码。** 与原文件相比，代码只能有以下差异：
  - 每个新文件重复原文件的 `import` 列表。
  - 被其他文件使用的声明，去掉 `private` 或 `fileprivate`。
  - 扩展文件用 `extension <类型> { ... }` 包住成员。
  - 代码移进嵌套类型的扩展后，为恢复原来的名字解析，可以加顶层的同名别名，例如 `private typealias Section = CollectionViewMessageListV3.Section`。上游 1.15 也这样做。
  - 每个用到日志的文件，复制一份原文件的文件级日志声明，例如 `private let logger = AppLogger(category: "ChatStore")`。上游把日志声明集中到一个共享文件时（`Markdown/Support/MarkdownLoggers.swift`），沿用上游的做法。
  - 只新增注释行：主文件的中文文件地图、每个新文件的头部注释、`// MARK:` 分隔注释。
  - 代码的先后顺序可以变化，例如上游把只有扩展文件用到的存储属性移到类型主体的末尾。

  以下改动不允许：
  - 复制有状态的文件级全局变量，例如 `ContentView.swift:849–850` 的 `rowHeightSeenLock` 和 `rowHeightSeen`。这类变量只能留在一个文件中。
  - 把协议遵循从类型的主声明移到扩展上。这会改变 MainActor 隔离的推断。

  C1 与 C3 冲突时，C1 优先：代码保持不变，文件位置可以与上游不同，并在文件地图中注明。
- **C2 存储属性留在类型主体中。** Swift 的扩展不能声明存储属性。
- **C3 文件位置对照上游 1.15 的文件地图。**

  | 情况 | 做法 |
  | --- | --- |
  | 上游文件地图中有对应的职责 | 放进上游的同名文件 |
  | 上游有这个文件，MinisX 没有对应代码（1.14 和 1.15 的新功能） | 不建这个文件 |
  | MinisX 独有的代码（例如 `web_read`、DeepSeek 费用、语音草稿） | 放进职责最接近的上游文件；没有合适的文件时，新建 `类型+职责.swift`，并在文件地图中标“MinisX” |

- **C4 新目录使用 Xcode 同步文件夹。** `AIChatView`、`ContentView`、`Markdown`、`CollectionViewMessageListV3` 4 个目录设为同步文件夹（`PBXFileSystemSynchronizedRootGroup`），与上游相同。理由：约 140 个新文件不用逐个写进工程文件，以后新增文件也不用改工程。设置时，必须删掉原文件的 `PBXFileReference` 和 `PBXBuildFile`，否则会重复编译。`Agent/Chat/` 和 `Views/Settings/` 下的新文件逐个加入工程。
- **C5 按路径引用这些文件的地方一起更新。**
  - `scripts/register_locale.py:26` 改为指向 `src/ios/Views/Settings/AppearanceSettingsView.swift`。`supportedLanguages` 保持 `private`，因为脚本第 108 行的正则匹配 `private let supportedLanguages`。
  - Spec 的“代码入口”链接，改为指向链接说明的代码实际所在的文件。例：`ios-agent-run-lifecycle.md:106` 说明的“发送、重试、Agent 循环”移到 `AIChatViewModel+Send.swift` 等文件后，链接也改过去。

### 为什么运行效率不变

本节只针对手机上安装的 Release 构建。

- Swift 的 `extension` 写在其他文件中，编译后仍是同一个类型的同一批方法。
- MinisX 的 Release 配置使用整模块优化（`SWIFT_COMPILATION_MODE = wholemodule`，`src/ios/Minis.xcodeproj/project.pbxproj:3600`），并且没有开启 `ENABLE_TESTABILITY`。编译器把所有 Swift 文件当作一个整体优化。去掉 `private` 后，编译器仍能确认一个方法没有被覆盖，仍可以直接调用或内联。
- C1 限定了允许的差异，没有一项改变执行的指令。V2 的检查脚本和 V3 的警告比较用来证明这一点。

Debug 构建（`-Onone`，开启 `ENABLE_TESTABILITY`）的方法派发方式可能有少量变化。这只影响开发时的模拟器构建，不影响手机。所以模拟器上的冒烟检查（V6）只证明功能正常，不证明流畅度。

本任务不涉及模块协作、数据流或状态变化，所以不画关系图和场景图。

## 验收（有证据才打勾，注明证据位置）

开始批次 1 之前，先完成 V0。每一批都必须满足 V1–V4。全部 6 批完成后，再检查 V5–V9。

- [x] V0 在 `main` 上记录基线：
  - 按 V6 的 5 步，在模拟器上截图。
  - 记录模拟器 Debug 构建和 Release 构建的编译警告列表。

  （evidence/baseline/，verification.md）
- [ ] V1 每批：原文件只剩主文件内容，拆出的文件与文件地图一致；满足 C2、C3、C4。（verification.md 中各批的文件清单）
- [ ] V2 每批：检查脚本比较拆分前后的代码，输出“无其他差异”。（verification.md 中各批的脚本输出）脚本的规则：
  1. 比较的对象是拆分前的原文件，和拆分后本批涉及的全部文件。
  2. 比较方式是行的多重集合，不比较行的先后顺序。
  3. 每行保留行首空白，逐字比较。多行字符串的缩进变化必须能查出来。
  4. 比较前，只从每行删去 `private ` 和 `fileprivate ` 两个修饰符。`private(set)` 不删。
  5. 新文件中多出来的行，只允许是：`import` 行、日志声明行、注释行、空行、`extension <类型> {` 行和对应的 `}` 行。
  6. C2 由编译器保证：扩展中不能声明实例存储属性，违反时 V3 的构建失败。脚本不检查 C2。
  7. 反向测试：在拆分后的文件中故意改动一行，脚本必须报出这一行。
- [ ] V3 每批：
  - 模拟器 Debug 构建成功，命令 `bash scripts/build_ios_simulator.sh --skip-deps`。
  - 不签名的 Release 构建成功。
  - 两种构建的编译警告列表与 V0 的基线相同。

  （verification.md）
- [ ] V4 每批：`MinisTests` 用 `build-for-testing` 全部编译通过。（verification.md）
- [ ] V5 全部完成后：完整运行一次 `MinisTests`，全部通过。（verification.md）
- [ ] V6 全部完成后，在模拟器上做冒烟检查：用 debug-server 依次执行下面的操作，每步截图，结果与 V0 的基线一致。（evidence/）
  1. 启动 App，首页会话列表正常显示。
  2. 打开一个长对话，滚动到顶部，再滚动回底部。
  3. 发送一条消息，回复正常流式显示。
  4. 显示含代码块、表格和数学公式的回复。
  5. 打开设置 → 外观，语言列表正常显示。
- [ ] V7 用户在手机上安装本分支的 Release 构建，打开长对话、滚动、发送消息，确认与拆分前一样流畅。（用户确认，记入 verification.md）
- [ ] V8 满足 C5：
  - 在仓库的临时副本上，用一个不存在的语言运行 `register_locale.py`，脚本成功写入 `AppearanceSettingsView.swift`。
  - Spec 中每个“代码入口”链接指向的文件，确实包含链接说明的代码。
  - `git diff --check` 通过。

  （verification.md）
- [ ] V9 独立代码审查完成，审查意见逐条处置，资源结论由审查给出。（verification.md）

## 决定

- 6 个文件全部拆分，分 6 批做，每批一个文件。（用户，2026-10-26）
- 在新分支 `refactor/split-large-files` 上做，全部完成并验证后再合入 `main`。（用户，2026-10-26）
- 每批验证通过后，在分支上提交一次。（用户，2026-10-26）
- 用户关心的验收是手机上的运行效率与原来一致或更好；具体实现方式由 Agent 决定。（用户，2026-10-26）
- 文件名和边界对齐上游 1.15。（Agent 决定，理由见“方案”）
- ✗ 不移植 AOJIT：用户不运行重的 Python 或 Node 任务，收益很小。（用户，2026-10-26）
- ✗ 暂不移植定时任务和“后台继续处理”。（用户，2026-10-26）
- G1 写入 `docs/project-guide.md`，不写进 Spec，因为本任务不改产品行为。（2026-10-26）
- 方案审查（reviewer 子代理，2026-10-26）的处置：全部采纳。

  | 意见 | 处置 |
  | --- | --- |
  | 上游拆分时有 C1 未列出的改动，C1 与 C3 冲突 | C1 增加“只新增注释行”“沿用上游共享日志文件”“顺序可以变化”；写明 C1 优先 |
  | 漏了 `Views/Settings/` 的两个文件和 `LLMProviderError.swift` | 写入批次表、C4、C5 |
  | Ask User 不改 `AIChatView` | 批次顺序改为 MessageListV3、AIChatViewModel、ChatStore、AIChatView、ContentView、Markdown |
  | Spec 链接“有效”证明不了目标 | V8 改为检查链接指向的文件确实包含说明的代码 |
  | 更新旧文件名注释与 C1 冲突 | 不改这些注释，写进“不做” |
  | V9 预先写死资源结论 | 改为由审查给出 |
  | V6 没有基线 | 新增 V0 |
  | `register_locale.py` 用已有语言运行测不到正则 | V8 改为用不存在的语言在临时副本上运行 |
  | V2 定义不够明确 | V2 写明 7 条脚本规则 |
  | 文本相同时，编译器的处理仍可能不同 | V3 增加编译警告比较 |
  | Debug 与 Release 的派发方式不同 | “为什么运行效率不变”写明只针对 Release；V6 只证明功能 |
  | Release 才编译的代码到最后才检查 | V3 每批增加不签名的 Release 构建 |
  | 协议遵循移到扩展会改变隔离推断 | C1 写明不允许 |
  | 可简化：合并 G1 和 G2 | 只保留 G1 |
  | 可简化：C4 的理由 | 改为“新文件不用逐个写进工程文件” |
  | 可简化：V4 的相关测试类清单 | 每批只做 `build-for-testing`，最后完整运行一次（V5） |

## 执行边界

- 分支：从本地 `main` 新建 `refactor/split-large-files`（用户已同意）。
- 提交：每批验证通过后，在本分支上提交一次（用户已同意，2026-10-26）。合入 `main` 和推送都需要用户另行明确要求。
- 设备：模拟器用 iPhone 17 Pro（iOS 26.4）。V7 由用户在自己的手机上完成。
- 部署目标保持 iOS 26.0。
- 不修改 `src/android` 及任何 Android 文件。

## 下一步

1. 做批次 2 `AIChatViewModel`：交给 implementer，说明同批次 1，另加 MinisX 已有的 21 个 `AIChatViewModel+*.swift` 和 `LLMProviderError.swift`。

批次 1 已完成并提交（见 verification.md）。

已完成：V0（见 verification.md）；分支已建；检查脚本 `tools/check_split.py` 和警告比较脚本 `tools/build_warnings.sh` 已写好。
