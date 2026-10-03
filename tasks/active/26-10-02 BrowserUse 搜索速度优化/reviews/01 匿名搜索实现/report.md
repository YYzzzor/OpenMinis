# 匿名搜索实现初轮审查

审查范围为本任务的匿名 `web_search` 产品改动。审查者使用独立上下文，只读检查；七份既有 Harness 修改未纳入范围。行号对应初轮版本，修复后需要重新核对。

## 确认的问题

| 编号 | 程度 | 规则 | 位置与触发条件 | 结果与建议 |
| --- | --- | --- | --- | --- |
| R1 | P1 | S0、S2 | WebSearchService.swift:672–695；单条有效结果超过输出预算。 | 完整归档已经保存，返回结果却没有编号与续读入口，同时阻断后续条目。应提供固定归档分片及下一结果索引。 |
| R2 | P2 | S1、S3、S4 | WebSearchHTMLExtractor.swift:207–213；正常标题、摘要、网址或查询包含 captcha 等词。 | 全页子串判断把正常 CAPTCHA 技术主题误判为挑战，增加渲染。应根据挑战结构识别。 |
| R3 | P2 | S4、S9 | WebSearchService.swift:464–470；HTTP 挑战后 HTML 回退取得完整结果。 | 对所有候选取 any 挑战标记，最终仍是 verification_required。应以当前有效结果判断状态，保留早先尝试说明。 |
| R4 | P2 | S1、S4 | WebSearchHTMLExtractor.swift:45–47、64 与 WebSearchService.swift:516–520；有效条目与不可解析来源并存。 | 拒绝的来源条目被静默跳过，仍返回 results。应报告结构缺口，按预算回退并保留可用内容。 |
| R5 | P2 | S2 | WebReadRenderer.swift:669–672 与 WebSearchHTMLExtractor.swift:152–172；回退文档包含 next_form。 | 序列化未保留 action、method 和 hidden value，丢失后续页元数据。应提供有界搜索提取接口，保持普通 WebRead 行为。 |
| R6 | P2 | S0、S2 | WebReadRenderer.swift:759–767；来源 href 超过 2048 字符。 | 属性被截短后作为完整来源保存，归档也无法恢复。搜索提取应在整体预算内保留完整来源，无法取得时明确缺口。 |
| R7 | P2 | 资源 R3、I4 | WebSearchService.swift:649–670、596–603；大型归档缩小到输出预算。 | 主线程每减少一条就编码整个前缀。512 条、每条摘要 3500 字符的 1,827,736 字节归档，仅返回 7,365 字节即同步耗时约 1,321 毫秒。应减少重复编码，将大解码与编码移出主线程并保留取消检查。 |
| R8 | P2 | S6、资源 I3、I5 | WebSearchService.swift:250–252、793–809 与 ConcurrentTools.swift:1051；非法超长查询。 | 100,000 字符查询被拒绝网络后仍回显 100,231 字节，超过 10,240 字节上限。应限制非法输入回显并准确说明原长度。 |

## 复现证据与边界

独立 CLI 证据见 [review-reproduction.txt](../../evidence/anonymous-search-20261002/review-reproduction.txt)。临时入口为 `/private/tmp/review-websearch/Main.swift`。
审查者使用核心文件临时副本及传输、渲染、通知和日志替身，没有修改产品代码或读取浏览器凭据。
复现确认解析、状态合并、格式化和输入回显；不代替 iOS、真实 WebKit、身份隔离或真机性能验证。
渲染分页及长来源网址由接口双方的静态代码确认。

## 资源效率

活动搜索 2 项、等待 4 项、HTTP 正文 2 MiB、解析 512 条、归档 2 MiB、诊断 128 条、统一截止时间 40 秒与最多一次回退均有边界。
HTTP 成功不调用渲染或截图，解析位于主线程之外。临时传输隔离共享 Cookie、认证与缓存；渲染遵守共享实例预算，并有释放及取消入口。
确定资源缺陷为 R7、R8；R2、R3 也引入不必要的渲染或后续模型检索。
detached 解析尚未取得足以量化取消延迟的证据；取消会丢弃结果，但计算需完成，本轮不增加确定缺陷。
真实并发、Stop、WebKit 释放、前后台、真机内存、能耗及锁屏仍需独立验证。

## 主会话处置

主会话核对相关代码及独立复现后采纳 R1–R8，交实现代理修复。
修复及运行验证状态在 [verification.md](../../verification.md) 更新；初轮审查不代表验收通过。
