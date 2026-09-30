# 26-09-29 P1 Spec 文档补全

状态：done
更新：2026-09-29 18:16 CST

## 恢复信息

分支：`main`
最近核验 HEAD：`272da5d9bb8051c82075513df9a395344d4e7f6b`
工作区：存在大量既有未提交修改和未跟踪/搬迁中的任务记录；本任务保留全部无关工作，不切分支、不建 worktree。
下一步：无；六个 P1 主题已补齐并完成静态文档校验，任务已按 Harness 归档。
待审批：无；用户已明确要求创建任务并解决此前评估中的 P1 文档问题，且允许创建新文档。

## 任务确认与执行边界

确认状态：已确认
确认稿版本：2026-09-29 当前对话，承接上一轮《Spec 文档质量与 iOS 规范覆盖评估》及已归档 P0 文档任务的暂缓清单。
用户依据：“下面创建一个任务, 解决之前提到 P1 级别问题涉及的文档, 可以创建新文档.”
真实使用目标：维护者和开发模型能从 Spec 索引准确找到 iOS 设备能力、同步冲突、Provider 路由、语音输入、系统入口和浏览器自动化的稳定契约、当前限制与可验证场景，减少跨模块改动时的遗漏和错误假设。
授权范围：创建/维护本任务；修改 `docs/specs/ios-device-data-capabilities.md`；按需在 `docs/specs/` 新增 P1 Spec；更新生成索引；进行静态源码和现有测试核对及文档校验。
明确排除：产品代码、测试代码、P0 Spec 的重复重写、P2 日历历史状态整理、构建、单元/UI 测试、模拟器、真机、远端操作、提交和推送。
执行位置：当前对话；`/Users/huyuanzhao/Coding/Projects/OpenMinis`；`main` 当前脏工作区。
首轮验证与停止条件：每个主题先确认用户可见行为、状态和跨模块边界；无法从源码判断产品意图时写为待维护者确认，不把现状自动提升为规范。若主题只能形成类清单而没有可复用契约，则不新增 Spec。

## 目标与验收

- [x] 修订 `ios-device-data-capabilities.md`，以当前注册命令、读写能力、系统权限、App 许可和操作确认核实能力矩阵，移除过时数量与未证实结论。
- [x] 新增 `ios-sync-and-conflict-resolution.md`，覆盖同步开关、记录与文件生命周期、合并/删除/tombstone、冲突语义、离线与可观察恢复。
- [x] 新增 `ios-provider-model-routing.md`，覆盖 Provider 实例、模型条目、会话绑定、模型组/fallback、凭证与用量身份，以及路由变更边界。
- [x] 新增 `ios-voice-input-lifecycle.md`，覆盖录音、转写、草稿编辑、停止/继续/发送、权限、会话代际和错误恢复。
- [x] 新增 `ios-system-entry-points.md`，覆盖 App Intents、Shortcuts、Widget、Share/File Provider、深链等跨入口的一致性、权限和降级边界。
- [x] 新增 `ios-browser-automation.md`，覆盖 browser session、动作、快照/文件、takeover、取消/超时、安全和资源边界。
- [x] 六个主题均包含准确 description、状态、适用场景、前提、例外、可观察验收、源码/测试证据和待验证事项；生成索引一致。
- [x] P0 文档仅在必要时被引用，不重复改写；P2 日历历史状态和其他低优先级建议保持未实施。

## 上下文与决定

- P1 范围依据上一任务明确暂缓项：设备能力清单刷新、同步冲突、Provider/模型路由、语音输入、跨入口/System Surfaces、浏览器自动化。日历历史状态整理归入 P2。
- 本任务记录既有产品行为，不拟议新的运行架构，因此不创建“拟议功能关系图/运行图”；必要关系通过文档内状态表和场景流程表达。
- 新文档按用户可见契约和跨模块复用价值划分，不按 Swift 文件或 target 数量划分。
- P0 中已建立的工具权限、Agent 生命周期、`minis://`、iSH runtime 等边界作为关联规范引用，避免重复和矛盾。

## Spec 阅读清单

必读：

- `docs/harness/spec-authoring.md`：文档质量、状态、场景和证据规则。
- `docs/harness/spec-context.md`：受控章节读取与完整上下文边界。
- `docs/specs/resource-efficiency.md`：持续资源和有界验证约束。
- `docs/specs/ios-device-data-capabilities.md`：唯一需要全面修订的现有 P1 Spec。
- `docs/specs/ios-tool-permissions-and-side-effects.md`：系统权限、App 许可和操作确认的既有 P0 边界。
- `docs/specs/ios-agent-run-lifecycle.md`：工具循环、Stop/Retry/Resume 和持久化边界。

按主题读取：

- 同步：`ChatStore`、Cloud sync engine、tombstone、共享文件和相关 tests。
- 路由：`ProviderConfigStore`、model binding/group/fallback、Provider factory、usage identity 和相关 tests。
- 语音：输入栏、`SpeechRecognitionManager`、实时 Provider/VAD、草稿代际和相关 tests。
- 系统入口：App Intents、Widget、ShareExtension、FileProvider、deep link 及对应 target/entitlements。
- 浏览器：browser offload/bridge/session、WebView、takeover、snapshot、取消与相关 tests。

## 实现计划

- [x] 使用生成索引和章节工具读取现有规范，并为六个 P1 主题建立定向源码/测试入口。
- [x] 先修订设备能力矩阵，确认命令注册和权限分层的共同词汇。
- [x] 新增同步、Provider 路由、语音输入、系统入口、浏览器自动化五份独立 Spec。
- [x] 交叉检查六份文档与 P0 Spec 是否重复或冲突，标注当前实现偏差和待维护者确认语义。
- [x] 重新生成索引；验证 description、章节路线、代表性小节抽取、相对链接和 whitespace。
- [x] 保存最终检查点；达到验收后按 Harness 归档任务。

## 进展与验证

完成静态源码定向核对并交付 6 个 P1 主题：重写设备能力清单；新增同步冲突、Provider 路由、语音生命周期、系统入口、浏览器自动化 Spec。

已核实并明确写入的重要当前限制：

- 同步 full fetch 后的“云端缺失即本地删除”对账当前禁用，避免部分 CloudKit batch 误删；LAN transport 仍未实现。
- Provider load balance 使用 Swift `hashValue`，不能承诺跨进程永久稳定；凭证可用性按设备判断。
- 语音输入用 generation 拒绝迟到回调，capture/转写收尾完成前阻止编辑发送；真机权限和音频中断仍待验证。
- AppIntent 无界面运行、Share/FileProvider/Widget 均受扩展进程和系统时限限制，入口发起不等于任务完成。
- 浏览器 Cookie/网站存储在 App 内共享而非按聊天 session 隔离；tab 有每 session 与全局上限；takeover、JS、导航和后台均有明确超时/取消边界。

文档校验：

- `python3 -B scripts/harness/spec_context.py index` 已重新生成 `docs/specs/index.md`；`index --check` 通过。
- 六份文档的 `context --outline` 均成功，description 与标题路由可解析。
- 定向抽取同步删除、Provider 初始路由、语音流式、系统 App Intents、浏览器 Cookie 小节，均返回完整目标子树和所需祖先引言。
- 本地 Markdown 链接检查通过（6/6 文档）；目标文件均存在。
- `git diff --check` 对本任务文档和索引通过。
- 按任务边界未运行构建、单元/UI 测试、模拟器或真机。

## Spec 同步

已同步：

- `docs/specs/ios-device-data-capabilities.md`
- `docs/specs/ios-sync-and-conflict-resolution.md`
- `docs/specs/ios-provider-model-routing.md`
- `docs/specs/ios-voice-input-lifecycle.md`
- `docs/specs/ios-system-entry-points.md`
- `docs/specs/ios-browser-automation.md`
- `docs/specs/index.md`（生成文件）

未修改：P0 Spec 正文、`ios-calendar-recurrence.md` 的 P2 历史状态、产品/测试代码。

## 阻塞与纠偏

无。

## 审查

本任务只改规范文档，不启动代码审查。交付前由主 Agent 根据实际源码和现有测试名称做静态一致性复核；源码不能证明的运行行为必须保留为待验证。
