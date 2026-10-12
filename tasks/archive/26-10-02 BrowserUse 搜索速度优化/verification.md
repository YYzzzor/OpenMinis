# BrowserUse 搜索速度优化验证记录

匿名`web_search`已经接入，当前没有保留的确定代码缺陷。
新版本构建成功；86项相关回归均已覆盖通过。
真实服务及完整Agent已执行，S5完整身份场景、S7持续质量与提速仍只部分验收。
全部原始记录位于本任务本地`evidence/anonymous-search-20261002/`，认证缓存未纳入。

## 逐项验收

| 规则 | 状态 | 证据与边界 |
| --- | --- | --- |
| S0：有效信息保全 | 通过。 | 实际Lite页面fixture、完整标题/摘要/来源、超大单条分片和尾部续读通过；真实流程取得并阅读两家官方来源。 |
| S1：当前文档就绪 | 通过。 | 等待HTTP正文并核对结构；截断空页、非2xx及真实WK当前文档用例通过。 |
| S2：来源及续读 | 通过。 | 完整长URL、Unicode分片、固定归档、作用域/类型拒绝、分页POST参数通过。 |
| S3：直接文字路线 | 通过。 | 有效HTTP路径不调用renderer；真实搜索仅1次HTTP尝试即返回，原browser_use导航及提取另有实际对照。 |
| S4：准确状态 | 通过。 | 明确无结果、空壳、验证码、部分来源及HTTP500用例通过；真实验证码返回verification_required。 |
| S5：身份与原浏览器状态 | 部分通过。 | 共享HTTP/渲染的真实合成Cookie与原登录标签回归通过；搜索模式真实WK无法读取default Cookie，结束后Cookie不变。完整Search、登录浏览器与用户接管的组合尚未实测。 |
| S6：预算及生命周期 | 通过。 | 2活动/4排队、截止、单项/批次/会话/删除、作用域与内存压力回归通过；删除目标后兄弟调用和归档继续。超时不保存本次新归档，借用归档按所有权保留。 |
| S7：质量与性能对照 | 部分通过。 | 同引擎同查询取得有效对照；原问句新旧各3轮；失败样本保留。配对样本有限，身份/UA及模型记忆有差异，持续稳定性和全面质量等价仍未证明。 |
| S8：两个独立搜索并发 | 通过。 | 三组双RPC查询实际重叠；完整Agent同一批两个web_search成功、结果分别配对，取消兄弟隔离回归通过。 |
| S9：有界回退 | 通过。 | 真实Lite验证码后一次HTML回退成功；仍受验证的查询准确失败。截止保留已取得完整条目及限制；Google/Bing模型补检策略已接入，未宣称此次真实失败均完成了浏览器补检。 |

## 构建和回归

设备为iPhone 18 Pro（479131C9-8187-44E7-8510-A499D7AC3034）/ iOS 27.0，最低部署版本保持iOS 26。
`WebReadServiceTests`共74项，`OffloadPermissionBypassTests`共12项。
完整执行86项、没有跳过，84项通过；两处新测试错误预期分别比较了尾部空白和直接results数组。
只修正测试预期，继续严格比较规范化全文及分片重建的完整摘要/URL；产品源码未变。
定向重跑两项均通过，没有重复已通过的84项。
记录见[test-summary.json](evidence/anonymous-search-20261002/test-summary.json)、[完整日志](evidence/anonymous-search-20261002/xctest-final.log)、[定向日志](evidence/anonymous-search-20261002/xctest-two.log)。

覆盖真实URLSession、WebKit、合成Cookie、原登录标签状态、动态正文、资源限制及旧WebRead行为。
测试使用本机受限fixture，不等同于真机、真实账户或完整搜索身份组合验收。

## 原问句完整Agent对照

源码基线为`611dbfeba9ba7eab18065b3487a2b681459f9645`。
旧安装构建时间为2026-10-02T09:56:04Z，新安装为2026-10-02T16:44:48Z。
两组均使用上述设备、DeepSeek-V4.1-Flash、high及正常工具集合，原问句保持相同。

| 样本 | 旧版本整轮 | 新版本整轮 | 新版本搜索选择 |
| --- | --- | --- | --- |
| 1 | 56.788秒 | 40.319秒 | 直接阅读已有来源。 |
| 2 | 66.196秒 | 48.910秒 | web_search检索Jev定价，1.783秒，找到官方模型文档。 |
| 3 | 44.953秒 | 26.409秒 | 直接阅读已有来源。 |
| 均值 | 55.979秒 | 38.546秒 | 仅为描述性结果。 |

旧组模型请求8/12/9次，新组6/8/5次；工具调用分别12/16/10与10/13/7次。
两组保留正常记忆和工具选择；旧组已出现memory_write，后续轮次可以复用来源。
因此整轮差异不能全部归因于搜索，不据此声称固定比例的提速或token节省。
原始记录见[before](evidence/anonymous-search-20261002/before/summary.json)、[after](evidence/anonymous-search-20261002/after/summary.json)。

另以正常工具集合明确要求两个web_search在同一批执行，进行单独功能验证。
两项工具耗时1.781/1.528秒，内部搜索1.455/1.372秒，均仅一次HTTP读取取得结果。
随后阅读TypeSafe官方文档/发布文及Cloudflare博客/模型文档；整轮52.955秒，10次模型请求、17次工具调用，无消息错误。
该问句增加了明确检索要求，不纳入原问句均值。
记录见[search-flow](evidence/anonymous-search-20261002/search-flow/summary.json)，原批次与调用标识保存在其run.log及messages.json。

## 真实搜索和同引擎对照

三组双查询共6次，4次返回有效结果：10、9、10、10条，每条都有标题、摘要及完整URL。
工具耗时1.835、1.771、1.347、2.975秒；前三项为HTTP直接成功，第四项在Lite验证后HTML回退成功。
另2次返回verification_required，没有来源；失败不计入提速收益。
双RPC重叠时间为1.779、1.352、0.902秒。
Cloudflare官方博客和模型文档可直接取得；宽泛中文Jev查询第一页未出现TypeSafe主域，模型定向查询取得了官方文档。
记录见[ios-direct](evidence/anonymous-search-20261002/ios-direct/summary.json)。

补充同一DuckDuckGo Lite、同一组查询的浏览器及HTTP对照：

| 查询 | 浏览器导航 | 随后提取 | HTTP工具 | 浏览器/HTTP条目 |
| --- | --- | --- | --- | --- |
| Jev + TypeSafe + System One | 6.679秒 | 0.970秒 | 1.366秒 | 9 / 9。 |
| Clef + Cloudflare + decision models | 6.106秒 | 0.510秒 | 1.364秒 | 6 / 6。 |

HTTP双查询同批墙钟为1.375秒。并发查询的时间不相加；浏览器整轮包含模型派发，不能与纯RPC墙钟直接相比。
Clef来源集合完全相同；Jev共有8条来源，另1条发生来源变化，两边均保留官方主要来源。
所有共同来源标题一致，摘要全部非空白字符一致；HTTP提取在强调标签周围增加了部分空白。
浏览器脚本输出的转义及附加元数据在分析时还原；模型回答曾将Clef误计为7条，验收采用原始工具的6条。
身份/UA不同、请求顺序不同，配对只有每主题一组，不能宣称排名完全等价或长期稳定。
记录见[matched-browser](evidence/anonymous-search-20261002/matched-browser/summary.json)、[matched-native](evidence/anonymous-search-20261002/matched-native/summary.json)、[质量核对](evidence/anonymous-search-20261002/matched-quality.json)。

此前三次DDG浏览器查询及macOS重复HTTP探测的验证码样本仍保留；Brave在macOS取得结果而iOS原WebRead返回429，未接入产品。
汇总见[comparison-summary.json](evidence/anonymous-search-20261002/comparison-summary.json)。

## 独立审查及处置

[初轮审查](reviews/01%20匿名搜索实现/report.md)的R1–R8全部采纳并修复。
[末轮复审](reviews/02%20匿名搜索复审/report.md)确认超长分片、挑战判断、缺口提示、分页参数、完整URL、离主线程编码及有界错误输出均已解决。
续读登记、兄弟借用归档及全局并发槽位三个缺口也已修复，取消、作用域结束和Stop不会提交迟到内容。
新增Search截止丢失已取得来源、超时缓存残留、明确取消与截止竞态、截断无结果及非2xx状态均已修复并验证。
删除公共路径清理已有VM，并在删除前清空排队提示；临时Store iOS测试确认目标取消及兄弟继续。
旧WebRead截止竞态在HEAD基线也已独立复现，属于既有故障顺带修复，未放宽原断言。
源码SHA、独立CLI及日志归因保存在本地证据目录，不以CLI或静态审查替代真实iOS执行。

资源规范已经独立复审；下载、归档、输出、队列、活动数、重定向、尝试及诊断有界。
真机峰值内存、能耗、锁屏与完整身份组合仍未验证，不作资源收益或完整验收声明。

## 文档检查

任务及新旧相关Spec的52个本地引用均可解析，`git diff --check`通过。
本任务涉及的WebRead W4、W5、R6按对应证据更新，未将其他WebRead拟议规则一并标记完成。
匿名搜索提交（`2a5461d`）只纳入匿名搜索及配套改动；当时七份Harness修改和工程构建号调整留在工作区。该次提交未执行推送或发布。
本机fixture服务已经停止，目标模拟器及新版本保留。

## 提示词与风险核对（2026-10-03）

本轮只补充系统提示词及核对既有实现，没有改变搜索、渲染和浏览器执行代码。
提示词明确DuckDuckGo为web_search的默认引擎，搜索质量和来源覆盖优先于速度。
两个互不依赖的查询可以同批执行；同一查询不同时使用web_search与browser_use。
Google及Bing规则只用于浏览器搜索回退，工具说明与提示词没有相反的引擎要求。
本轮8项提示词静态核对、Swift语法解析及git diff --check均通过，未重新构建、安装或执行模型查询。
此前86项回归及模拟器结果对应本轮提示词调整前的版本。
S0–S4、S6、S8、S9保持原验收结论，S5及S7保持部分验收。

匿名HTTP使用临时URLSession，禁用Cookie、凭据存储及响应缓存；匿名渲染使用nonPersistent网站存储。
匿名渲染与普通浏览器共用全局WebView数量预算，不能取得槽位时报告资源受限，不抢占原标签。
browser_use使用default网站存储，因此模型转入该路线后不能继续声称整个检索过程均为匿名身份。
匿名身份不隐藏查询或网络IP，也不自动过滤查询中的私人文字；搜索结果仍属于外部内容。

搜索的初始入口固定为DuckDuckGo HTTPS地址，但通用HTTP重定向及渲染导航只检查HTTP(S)、无URL凭据和次数上限。
当前未增加搜索专用的HTTPS及域名限制；本轮没有观察到由此造成的信息泄露。
这是风险核对发现的边界，不将既有Cookie隔离测试扩大解释为所有网络边界均已验证。
DuckDuckGo官方说明HTML及Lite是非JavaScript搜索版本，并指出它们缺少主站的部分功能；不宣称搜索质量全面等价。
参考：[非JavaScript搜索说明](https://duckduckgo.com/duckduckgo-help-pages/features/non-javascript)、[隐私政策](https://duckduckgo.com/privacy)。

## 本地提交核对（2026-10-03）

本轮范围为22份源码、工程及测试文件，3份相关Spec及索引，以及7份本任务记录，共32份文件。
18份源码及测试与已验证清单的SHA256一致；提示文件只增加已静态核对的质量、DuckDuckGo与并发规则。
两份真实搜索样本仅清理空白行缩进；现有Swift提取器对清理前后输出的9条和10条结果逐字段相等，所有分页字段也一致。
工程文件仅纳入搜索源码引用，八处CURRENT_PROJECT_VERSION调整不纳入，工作区内容保持原值。
共享读取组件的修改包含搜索归档类型隔离，以及超时后保留已取得匿名HTTP正文的修复。
既有86项回归和模拟器证据沿用上述源码清单，本轮没有重新执行模型查询、iOS构建或发布。
另以现有提取器运行样本格式等价核对；最终git diff --cached --check通过。
S0–S4、S6、S8、S9保持通过，S5及S7保持部分验收；维护者计划自行Archive和内部试用。

当前实现只有并发及单次回退上限，没有跨调用请求频率控制、验证码冷却或专门的Retry-After处理。
实测验证码不等同于已证实IP封禁；本轮不增加反自动化规避或代理轮换功能。

## 构建号与任务状态核对（2026-10-03）

主应用及ShareExtension、FileProvider、AgentWidget三个扩展的Debug和Release构建号均为10。
工程文件本轮只修改八处CURRENT_PROJECT_VERSION，搜索实现没有变化。
工程格式检查和git diff --check通过；本轮没有重新构建、运行搜索测试、Archive或发布。
当前任务继续保留在tasks/active/，S5及S7保持部分验收，后续仍等待维护者使用反馈。
