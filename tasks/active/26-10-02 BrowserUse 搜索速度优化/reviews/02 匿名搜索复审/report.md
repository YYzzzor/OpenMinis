# 匿名搜索末轮独立审查

本轮独立只读复审没有保留的确定正确性问题。初轮 R1–R8、随后发现的续读登记/共享归档/并发缺口，以及本轮截止、状态和删除生命周期问题，均已修复并完成下述范围内的验证。已查阅主会话实际 iOS 回归日志：86 项执行，84 项通过，2 项新测试因断言预期不符合规范化/分片接口而失败；修正断言后的定向回归、真实搜索及完整 Agent 对照仍需主会话完成。

审查对象为 `/Users/huyuanzhao/Coding/Projects/OpenMinis` 的 `investigate/build8-agent-latency` 工作区增量。完整规范已阅读：`ios-web-search.md`、`resource-efficiency.md`、`ios-web-read.md` 与相关 DEBUG RPC 规则；排除了七个既有 Harness 脏文件，未修改产品文件。最终范围包括 22 个 `src/ios` 修改或新增文件，覆盖 Search 三个新文件、共享 WebRead 接口与组件、派发/工具定义/提示/生命周期、SSE 消息类型、ChatStore 重建和删除、ViewModelCache 删除队列、DEBUG RPC、工程配置、两份搜索 fixture 与测试。

实现代理声明稳定后核对完整文件 SHA256，漂移为零。完整清单保存于 `/private/tmp/review-websearch-latest/product-sha256.txt`；WebSearchService SHA256 为 `198a0c83c7d2b0d75ff70552c0d8b7dbedda1d1f29f64cbe73bdf1a5f448beac`。各独立 CLI 目录另保存对应核心源码的 `source-sha256.txt`、临时桩、复现入口、构建日志与 evidence。

初轮事项的最终状态如下。原始触发、严重度和详细报告仍以任务 `reviews/01 匿名搜索实现/report.md` 为准，以下只记录修复结论。

| 原事项 | 结论与证据 | 相关规则 |
| --- | --- | --- |
| R1 超大单条阻断续读与后续条目 | 已解决。WebSearchService:916/956 的分页与 result_fragment 路径，7 个 Unicode 标量片段可重建完整含引号、中文、emoji、长 URL 的单条 JSON，随后可取得尾条，内容与保存输入相等。 | S0、S2 |
| R2 CAPTCHA 主题误判挑战 | 已解决。WebSearchHTMLExtractor:222 使用挑战结构/明确提示；普通 CAPTCHA 主题结果仍为 results，verification=false。 | S4、S9 |
| R3 初始挑战污染有效 HTML 回退状态 | 已解决。挑战→有效结果为 results；挑战→明确完整空页为 no_results，不再仅凭任一候选挑战标记覆盖最终有效状态。 | S4、S9 |
| R4 无效来源静默遗漏 | 已解决。解析记录 rejectedResultAnchors，WebSearchService:586 保留有效条目，输出 partial 与明确缺口。 | S0、S4 |
| R5 渲染丢失分页 form 参数 | 已解决。WebReadRenderer:772 保留 next_form action/method 与 hidden input name/value，提取器保留 q/s/nextParams/v/o/dc/api/vqd/kl；公开 fixture 得到 POST/start10。真实 WK 搜索模式用例又覆盖 q/s/vqd，运行结果待主会话。 | S1、S2 |
| R6 渲染截断长来源 URL | 已解决。搜索结构模式完整保留 href，仍受总快照/节点上限约束；CLI 的 3000 字符 URL 重建一致，真实 WK fixture 断言 >2048 的 URL 完全相等。 | S0、S1 |
| R7 主线程反复线性编码 | 已解决。解码/编码使用 detached 工作，分页采用二分；1,827,736-byte/512 条归档的独立 CLI 续读约 8.56ms，返回 7365 bytes。该数字是 Mac CLI 耗时，不是 iOS 主线程耗时或真机能耗测量。 | S6；资源 I3、I4 |
| R8 无效查询错误输出无界 | 已解决。100000 字符查询返回有效 JSON，545 bytes，低于 10240-byte 预算。 | S6；资源 I3 |

综合核心 CLI 证据为 `/private/tmp/review-websearch-latest/evidence.txt`。CLI 使用真实 Models/Store/Extractor/SearchService 源码，仅替换平台通知、日志、浏览器资源注册以及 HTTP/renderer 边界，不证明真实网络或 WK 行为。

续读的三个后续缺口均已解决：performContinuation:352 注册 ActiveCall 和统一截止任务，在 decode/encode 后复查调用、取消和作用域；借用归档不再计入当前调用拥有的新缓存，取消读者 A 后读者 B 仍返回结果且共享归档保留；续读也进入同一 permit pool，并受最大跟踪数约束。实测 endRequest、batch Stop、Task.cancel 都丢弃迟到内容；同批单项取消不影响兄弟；10 个并行续读最多跟踪 6 项、活动 2 项、排队 4 项，6 项完成、4 项资源拒绝。分页 best 与 fragment best 返回前也重新检查活动状态。跨 scope、错误 document kind 的失败路径已静态核对，不能绕过作用域边界。

截止和状态边界也已复核：

- 有效部分 HTTP 来源随后 HTML 回退超时，原实现丢失来源，违反 S9。本轮 deadlinePartialOutcome:658 返回预算内完整条目，status=partial，准确说明未完成回退和未返回范围；无 document_id/continuation，也没有写入新归档。12 条长摘要输入实测保留完整 1 条、7846 bytes，准确声明另有 11 条无法续读，缓存计数和字节均为零。用户明确取消仍返回 cancelled、空内容、无新缓存。证据 `/private/tmp/review-search-deadline/final/evidence.txt`；修复前证据为 `before/evidence.txt`，首次修复后仍创建缓存的证据为 `after/evidence-long.txt`。
- 续读异步解码期间，在截止前明确取消却跨过截止后返回，原尾部分类会将用户取消标为 failed；现 WebSearchService:399 优先明确取消，再判断超时。1.827MiB 归档、2ms deadline、0.5ms 取消的 5 次复现，均确认取消时 before-deadline=true、active1，最终为 cancelled。借用归档保留符合修订后 S6 的所有权边界。证据 `/private/tmp/review-search-continuation-cancel-deadline/evidence.txt`。
- 被截断的 HTTP200 no-results 提示不再直接宣称完整空页：初始快捷路径加入 !wasTruncated，最终明确空页判定要求完整 2xx；回退失败复现为 failed、仅一次回退。HTTP500 正文含有效来源且回退失败时保留完整来源为 partial，不再标为 results。证据 `/private/tmp/review-search-status-boundaries/evidence.txt`。

旧 WebRead 截止故障属于既有竞态，未发现是新共享接口默认语义导致。HEAD 旧实现亦能复现：render catch 先读取 timedOut=false，随后 isActive 检测到截止并改写状态，分支却返回空取消结果，外层再改为 failed；已有 uncached partial 路径未被执行。共享 Store 默认最大标量及原读取行为保持原值，WebReadRendering 旧重载继续传 preserveSearchStructure=false。修复通过直接检查截止时间再分类，当前 CLI 在 1000/2000-byte 两种预算下均保留 `HTTP-PARTIAL-BODY-3A4C`、status=partial、无 document_id/continuation。当前证据 `/private/tmp/review-webread-deadline/after/evidence.txt`，旧 HEAD/此前工作区复现分别在 `baseline/evidence.txt`、`current/evidence.txt`。旧断言没有放宽。

新增生命周期与消息接入已完成静态复核。SSEStream:465/709/834 统一 web_search 类型；ChatStore:4864 建立对应工具块，原工具结果重建路径继续恢复 JSON、显式状态与 pageURL。AIChatViewModel 的请求结束、请求锚点切换、Stop/清空及批次结束均接入搜索清理。UI 单项/批量删除经 ViewModelCache.remove→cancelSession；DEBUG 删除与远端 LocalOnly 删除现在也经 ChatStore 公共汇合点的 MainActor 清理任务执行同样清理。ViewModelCache.remove:445 在 cancel 前清空 promptQueue，避免普通 Stop 的恢复队列逻辑在删除后继续运行；普通 Stop 的队列行为保持原语义。

公共删除后取消收尾没有发现会话复活路径：ChatStore:582 开启 foreign_keys，messages:599 通过 REFERENCES sessions(id) 约束父会话，appendMessages 只 INSERT 消息，touchSession 只 UPDATE 会话，ensureSession 已有 sessionId 时不创建原 ID。LocalOnly 没有本地删除 tombstone，但外键仍阻止迟到消息写入；本地 deleteSession 的 tombstone 主要保护远端合并。新增临时 ChatStore 生命周期测试覆盖目标归档/活动调用清理、队列为空且 currentTask=nil、兄弟归档/调用继续。审查者未亲自运行 iOS 删除测试。已查阅临时 Store 的实际 LocalOnly 删除用例日志：删除/队列/缓存/目标取消/兄弟非取消断言没有失败，旧兄弟 URL 断言因分片接口而失败，完整用例通过仍待修正后重跑。UI/DEBUG/远端三个入口的覆盖目前依据静态调用链，不能写为三种真实删除场景均实测通过。

DEBUG debug.webSearch 的注册和实现符合接口边界。DebugJSONRPC:691 仅接受 query/experiment_call/experiment_scope；查询 1–512 标量，诊断标签受字符集与 48 字符上限约束，其他 key 拒绝。它沿用既有 DebugServer 的 DEBUG 编译和请求鉴权，不接受任意网址、头部、浏览器 Cookie 或凭据。诊断次数/字节受限，并在结束时释放临时请求作用域。审查者未另行调用真实 RPC。

S5 的静态隔离证据明确：URLSessionWebReadTransport:70 使用 ephemeral，cookie storage/credential storage/cache 为 nil，禁用 cookie 接收/设置；WebReadRenderer:116 使用 nonPersistent，不恢复 BrowserUse Cookie，搜索服务只传受限查询生成的固定 DuckDuckGo 地址。原真实合成 Cookie、登录浏览器私人标记及接管测试调用 WebRead，属于共享组件运行证据。新增真实 WK 搜索快照测试直接以 preserveSearchStructure=true 调用 renderer，在 default store 写随机合成 Cookie，断言匿名页面仅取得 PRIVATE_COOKIE_ISOLATED，结束后 default Cookie 原值仍在，同时保留长 URL 和 next_form。此用例仍是 renderer 的搜索模式证据；它没有运行完整 WebSearchService/真实 DuckDuckGo，因此搜索端到端私人标记、真实登录浏览器/接管状态保持不可宣称已实测。`/private/tmp/minisx-web-search-tests-final.log` 已显示该真实 WK 搜索 Cookie/长 URL/form 用例 passed；证据范围仍限 renderer 的搜索模式。

资源效率独立结论为：静态边界与有界 CLI 验证未发现保留的确定浪费或清理缺陷，真机资源验收仍未验证。

1. 新增工作是每项至多一次 HTTP 与一次同引擎渲染、离主线程解析/解码/编码及按需归档，服务明确约束 2 活动/4 排队、512 条、2MiB HTTP/归档、10KiB 输出、128 条诊断；renderer 延用共享实例预算和快照上限，HTTP 成功不建立 WebView。
2. 只在实际结果结构不足时顺序回退，续读复用已保存内容、不重复搜索，格式化二分选取输出范围，无新轮询、截图或无界日志；截止保留采用有限完整条目并准确说明遗漏。
3. 单项、批次、会话/删除、作用域结束、资源压力都有停止与释放路径；已验证无迟到提交、兄弟独立、permit 数量恢复。当前调用自己的超时新缓存不保留；借用归档按原作用域/TTL/预算清理。删除生命周期的实际 iOS 执行仍待验证。
4. 代表性大归档 CLI 约8.56ms，相比旧反复编码路径明显减少工作；两路同时渲染及大快照的真机峰值内存/CPU、能耗、锁屏与 UI 流畅度均未测。Mac CLI、代码检查和构建成功均不能替代这些测量。
5. 优化保持完整标题/摘要/来源、完整分片及尾条，错误、截断和超时有准确状态/限制；离线程工作的同时也减少编码次数并限制并发。没有以静默截断有效单条换取速度。

最终尚待验证范围：修正两项新测试断言后的定向 iOS 回归，以及主会话的真实服务/RPC与正常 Agent 工具集合对照。原版本完整 Agent 轮次已有 memory_write/用户记忆差异，整轮均值不能单独归因于搜索实现。上述未验证事项不是本轮新增的确定代码缺陷。

2026-10-03 两项测试断言修正的独立补充复核：

- 已从 `/private/tmp/minisx-web-search-tests-final.log:11509` 的实际 XCTAssertEqual 文本提取两份完整摘要。实际 2239 标量、期望 2240 标量，去除原期望最后一个空格后逐字相等，没有遗漏任何摘要正文。修改为比较原输入 `.trimmingCharacters(in: .whitespacesAndNewlines)` 后的完整值，仍断言完整摘要和 URL，不是缩短内容或放宽完整性要求。
- 删除用例 `/private/tmp/minisx-web-search-tests-final.log:11229` 的兄弟调用为 partial，HTTP 正文 4245 bytes，单次输出限制 900 bytes；完整单条不能直接进入 results。修正后断言 partial、document_id 与 result_fragment 存在，按 next_offset 读取并拼接所有片段，核对每片 start/result_index，解析完整 WebSearchEntry，最后逐字比较完整规范化摘要及原 URL；原目标/兄弟隔离和删除队列断言保留。独立真实核心 CLI 对同样 900-byte 输入取得 results=[]、fragment=true，12 个片段重建后 URL 和完整规范化摘要均相等。证据 `/private/tmp/review-search-test-boundaries/evidence.txt`。
- 日志汇总是 86 executed、2 failures、0 unexpected；真实 WK 搜索 Cookie fixture、旧 WebRead 截止、明确续读取消、截断 no-results 与 HTTP500 分类用例均显示 passed。该轮完整测试仍是失败状态，不能写为 86 项通过；两项修正后的真实 iOS 重跑尚待主会话。
- 产品冻结后仅 `src/ios/MinisTests/WebReadServiceTests.swift` 的 SHA 改变，从 `f31d9fef292abd8dd305700ddd29376d6b97f151b67ca995e75782f43e56d085` 更新为 `95feddd3998ca4b74830d8288b2fbba587e59816411bbef0935b7a7dd8129a49`。其余 21 个 src/ios 清单文件全部保持原 SHA，包括 WebSearchService 的 `198a0c83c7d2b0d75ff70552c0d8b7dbedda1d1f29f64cbe73bdf1a5f448beac`。更新清单仍为 `/private/tmp/review-websearch-latest/product-sha256.txt`，原清单另存为 `product-sha256-before-test-assertion-fix.txt`。失败归因、通过的实际用例和前后 SHA 摘要另存 `/private/tmp/review-search-test-boundaries/log-evidence.txt`。

本补充未扩大产品调查范围，未发现产品新问题，也没有修改产品或测试文件。


主会话补充：2026-10-03定向XCTest两项通过，0失败。与同一产品源码已通过的84项合并，86项相关回归全部覆盖通过。实际服务、完整Agent和同引擎对照见[验证记录](../../verification.md)，不以独立CLI代替这些证据。
