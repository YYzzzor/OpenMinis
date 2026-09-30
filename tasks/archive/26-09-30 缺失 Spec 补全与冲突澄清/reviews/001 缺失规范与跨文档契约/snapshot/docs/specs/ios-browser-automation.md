---
description: MinisX iOS browser_use 的会话与标签页、导航和脚本、Cookie、下载、超时、资源回收、安全和验收边界。
---

# MinisX iOS 浏览器自动化

导航：[Spec 索引](index.md)；`minis://` 本地资源解析见 [Minis URL Scheme](minis-url-scheme.md)；工具许可和副作用分级见 [iOS 工具权限与副作用](ios-tool-permissions-and-side-effects.md)。

状态：现行浏览器契约与 2026-09-29 当前实现并列记录。证据来自 [BrowserUseActions.swift](../../src/ios/Agent/BrowserUse/BrowserUseActions.swift)、[BrowserUseManager.swift](../../src/ios/Agent/BrowserUse/BrowserUseManager.swift)、[BrowserTabPool.swift](../../src/ios/Agent/BrowserUse/BrowserTabPool.swift)、[CookieBackupStore.swift](../../src/ios/Agent/BrowserUse/CookieBackupStore.swift)、[BrowserUseOffloadBridge.swift](../../src/ios/NativeOffloads/BrowserUseOffloadBridge.swift) 和 [BrowserResourceMonitor.swift](../../src/ios/Diagnostics/BrowserResourceMonitor.swift)。本轮没有访问网页或运行自动化。

## 能力和副作用

`browser_use`/`minis-browser-use` 驱动 App 内 WKWebView，支持导航、截图、点击、输入、滚动、读取页面、查找元素、执行 JavaScript、fetch、标签页、viewport/UA、Cookie 读写和等待 DOM 稳定等动作。

读取网页、截图和 Cookie 可能暴露账号与私人内容；点击、输入、脚本、fetch 和 Cookie 写入可能提交表单、改变远端状态或登录身份。浏览器动作仍受工具许可与操作确认规范约束，不能因运行在 WKWebView 内就降级其副作用。

普通导航只允许 `http`、`https` 和 `minis`；WebKit delegate 还允许内部 `about`/`blob`。其他 scheme 必须拒绝或交给明确的外部打开流程，不能让网页静默调用任意系统 URL。

## 会话和标签页

每个聊天 session 拥有一个 `BrowserTabPool`。Agent UI 与同一 session 的 shell CLI 优先共用这个 pool；当 ViewModel 不在缓存中，CLI 可以为仍存在的 session 建立 fallback pool。删除 session 时应释放 fallback pool 和持久化标签状态。

当前每个 pool 最多 3 个 live tabs，进程内所有 pool 合计最多 8 个。Agent 路径允许并发 implicit navigate 在 tab 忙或 15 秒完成后 grace 内 fan-out 到新 tab；CLI 使用 single-tab 模式，使连续 `navigate → read/execute_js` 默认作用于刚导航的页。调用方需要稳定目标时应传返回的 `tab_id`，不能依赖全局 selected tab。

标签 URL 和 session viewport 可以持久化，但 WKWebView 内存、页面 DOM 和执行中 JS 不会被完整持久化。空闲约 15 分钟、memory warning 或全局 cap 会回收 tab：优先空闲 tab，必要时可抢占其他 session 最旧的 in-use tab。被抢占动作下次收到“tab reclaimed, retry”，保存的 URL 可用于恢复；不得把它当作动作已经成功。

## 用户 takeover 与取消

Agent 控制浏览器时，页面覆盖层阻止用户与 Agent 同时操作，并提供 Takeover。用户接管后，Agent loop 在浏览器动作完成点或轮次边界暂停；用户结束接管时恢复，并截取新的页面截图写入 session browser 目录，作为后续模型看到手动操作结果的证据。

mid-action takeover 当前有 5 分钟超时；轮次间 takeover continuation 没有独立超时，只依赖用户结束、Stop 或其他清理路径恢复。这是已核实的卡住风险，不能把 takeover 宣称为无限安全等待。

Stop 必须同时恢复 takeover/background continuation、取消 Agent task，并对所有正在加载的 tabs 调用 `stopLoading()`，使挂起的导航 continuation 返回。停止加载或 Task 取消不撤销网页已经提交的表单、脚本副作用或已完成下载；结果必须标为 cancelled/incomplete，而不是回滚成功。

## 导航、读取和脚本时限

当前分层时限是实现护栏：导航 30 秒，固定读取脚本 10 秒，`execute_js` 45 秒，单 tab serial slot 等待 60 秒，CLI 外层约 90 秒。内层应先超时释放资源，避免一个不结束的 Promise 阻塞整条 session。

导航 30 秒后可能返回“未完成、页面可能部分加载或 renderer 卡住”的结果，同时 WKWebView 仍可能继续工作。无论结果对象的 success 字段如何，调用方看到该文案都不能声称页面完成加载；应读取当前 URL/DOM、重试或新建 tab。

JavaScript 超时只解除 App 的 await，WebKit 中脚本可能仍继续运行。超时后在同一 tab 继续操作前应检查 DOM/URL 或重建 tab，不能假定脚本已取消。DOM stable 只是连续采样无变化，不证明网络、动画或业务异步全部结束。

全页截图当前将高度限制为 32,768 CSS/渲染像素并明确标记截断；截图成功证明捕获到当前 WebView 状态，不证明页面语义完整。

## 页面状态、Cookie 与登录

所有 tabs 使用 `WKWebsiteDataStore.default()` 和共享 `WKProcessPool`，以支持跨 tab 登录/OAuth。结果是 Cookie 和网站存储在 App 浏览器范围共享，**不是按聊天 session 隔离**。一个 session 的登录/退出可能影响另一个 session，安全提示和测试必须据此设计。

Cookie backup 用于缓解 ITP 在无真实用户手势的 agent 浏览中清理登录 Cookie：按 registrable domain 保存 Netscape 格式的本地文件，保留 domain/path/expires/secure/HttpOnly；live Cookie 优先，只有缺失且未过期的备份才重新注入。

备份文件使用 `completeUntilFirstUserAuthentication` 保护并排除系统备份；域约 30 天未访问后清理，最多 1000 个域，超出时淘汰最久未访问者。它不是 Keychain，不跨设备同步，也不构成永久登录保证。

`get_cookies` 返回前应尽量避免把原始值写进普通文本结果；当前实现把原值写入受控 env 文件并在结果中给出路径。日志、任务记录和错误不得复制 Cookie/Authorization；`set_cookies` 接收敏感输入时优先用文件而不是 shell 参数。

## 下载、fetch 与本地文件

原生 WKDownload 保存到 session 的 `/var/minis/workspace/` 对应目录，并向 Agent 报告 started/completed/failed/cancelled。Agent 看到“browser is handling download natively”后不得再用 curl/wget 重复下载；取消会移除部分文件，completed 才证明目标文件完整存在。

`fetch` 在当前页面 JavaScript 上下文执行，继承该网站的网络/Cookie条件；CLI bridge 和 Agent 路径把返回二进制保存到 session 的 `/var/minis/browser/`，引用为 `minis://browser/<文件名>`。它与原生 WKDownload 的 workspace 落点不同。跨域、认证、Content-Disposition 和 WebKit 限制都可能失败。`minis://` 只映射 MinisX 已允许的本地路径，不扩大 iOS 沙盒。

验收时分别检查 fetch 返回的路径/URL 与实际 browser 文件，以及原生下载 completed 的 workspace 文件；`fetched_bytes` 或返回了 URL 不等于写盘成功。写入失败和后续不可读必须保持可观察，本轮未执行下载或写盘验证。

## 后台与资源证据

WKWebView 的 WebContent 是独立进程，App 自身 memory/CPU 不能证明浏览器进程健康。当前诊断在 action 超过 30 秒且 App 位于后台时记录 stuck snapshot，并以 URL/title 同时消失作为 renderer 可能已终止的间接证据；这不是系统级确定诊断。

iOS 后台可能暂停 WebContent，使导航或 JS 无法按时返回。浏览器自动化没有可靠无限后台承诺；前台成功、旧运行日志或主 App 内存余量不能替代目标场景验证。

## 场景与验收

### 场景 A：两个 Agent 并发导航

implicit navigate 不覆盖仍 in-use/grace 的 tab；必要时分配新 tab并在结果中返回各自 `tab_id`。后续读取显式指定 id 后得到对应 URL 内容，不串页。

### 场景 B：达到全局标签上限

优先回收其他 pool 的空闲 tab；无空闲时被抢占的 in-use tab 下次得到明确 retry，且最后 URL 可恢复。不能静默把动作转到另一页或伪报成功。

### 场景 C：脚本 Promise 永不结束

约 45 秒给出明确 timeout，并在 60 秒 serial wait 前释放调用方；后续操作先核对 tab 是否健康，必要时重建，不让整个 browser pool 永久卡死。

### 场景 D：一个 session 登录、另一个 session 打开同站点

二者可能共享登录 Cookie；UI/Agent 不宣称 session 隔离。退出或写 Cookie 的影响范围被告知，敏感值不进入普通日志。

### 场景 E：网站触发原生下载

状态从 started 到 completed/failed/cancelled 可观察；completed 文件存在于该 session workspace，cancelled 的部分文件已删除；Agent 不重复下载。

### 场景 F：后台执行导航

若被系统暂停或 WebContent 终止，返回 timeout/reclaimed/renderer error 或下次前台可诊断状态；没有证据时不声称页面加载和远端动作成功。

### 场景 G：用户接管后 Stop

Takeover 覆盖层解除，等待 continuation 被恢复，所有进行中的页面加载停止，Agent tool 标记 cancelled/incomplete；已发生的网页副作用保留且明确告知。正常结束接管时，新的截图进入后续上下文，Agent 不按接管前 DOM 继续猜测。

## 待验证与待确认

- 待验证：iOS 26 真机多 session tab 回收、memory warning、后台 WebContent、OAuth/Cookie 恢复、原生下载、JS timeout 后 tab 健康及长页面截图。
- 待验证：正常/mid-action takeover、5 分钟超时、用户 Stop 和 sheet 异常消失时所有 continuation 都能恢复。
- 待确认：浏览器 Cookie 是否长期维持 App 全局共享，还是需要为敏感场景提供隔离 data store；当前行为明确不隔离。
- 待确认：导航 timeout 结果的 `success` 字段是否应改为 false；当前文案已表明未完成，调用方必须以文案/状态谨慎处理。
