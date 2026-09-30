---
description: MinisX iOS browser_use 的会话与标签页、导航和脚本、Cookie、下载、超时、资源回收、安全和验收边界。
---

# MinisX iOS 浏览器自动化

导航：[Spec 索引](index.md)；`minis://` 本地资源解析见 [Minis URL Scheme](minis-url-scheme.md)；工具许可和副作用分级见 [工具权限与副作用](ios-tool-permissions-and-side-effects.md)。

范围：`browser_use` / `minis-browser-use` 驱动 App 内 WKWebView 的全部动作：导航、截图、点击、输入、滚动、读取页面、查找元素、执行 JavaScript、fetch、标签页、viewport 与 UA、Cookie 读写、等待 DOM 稳定等。

## 副作用与 scheme

- **X1** 读取网页、截图、Cookie 可能暴露账号和私人内容；点击、输入、脚本、fetch、写 Cookie 可能提交表单、改变远端状态或登录身份。浏览器动作遵守工具许可与操作确认规范，不因运行在 WKWebView 内而降低副作用等级。
- **X2** 导航只允许 `http`、`https`、`minis`；WebKit delegate 另外允许内部的 `about` 和 `blob`。其他 scheme 被拒绝或交给明确的外部打开流程，网页不能静默调用任意系统 URL。

## 会话与标签页

- **T1** 每个聊天会话有一个 `BrowserTabPool`。Agent 界面与同一会话的 shell CLI 优先共用它；ViewModel 不在缓存中时，CLI 可以为仍存在的会话建立 fallback pool。删除会话时释放 fallback pool 和持久化的标签状态。
- **T2** 每个 pool 最多 3 个活动标签，进程内所有 pool 合计最多 8 个。
- **T3** Agent 路径：标签忙或刚完成导航（15 秒宽限期内）时，新的隐式导航分配到新标签。CLI 使用单标签模式，让连续的 `navigate → read / execute_js` 默认作用在刚导航的页面上。需要稳定目标时传入返回的 `tab_id`，不依赖全局“当前选中标签”。
- **T4** 标签 URL 和会话 viewport 可以持久化；WKWebView 内存、页面 DOM、正在执行的 JS 不会持久化。
- **T5** 空闲 15 分钟、内存警告或达到全局上限时回收标签：优先回收空闲标签，必要时可以抢占其他会话中最久未活动的使用中标签。被抢占的动作下一次收到 “tab reclaimed, retry”，可以用保存的 URL 恢复；这不算动作成功。

## 用户接管与停止

- **U1** Agent 控制浏览器时，覆盖层阻止用户与 Agent 同时操作，并提供“接管”。用户接管后，Agent 在当前浏览器动作完成时或轮次边界暂停。
- **U2** 用户结束接管时 Agent 恢复运行，并截取新的页面截图写入会话 browser 目录，让模型看到手动操作后的结果，而不是按接管前的 DOM 继续猜测。
- **U3** 动作进行中的接管有 5 分钟超时；轮次之间的接管没有独立超时，只能由用户结束、Stop 或其他清理路径恢复（见“待决定”）。
- **U4** Stop 同时：恢复接管和后台等待、取消 Agent 任务、对所有正在加载的标签调用 `stopLoading()`，让挂起的导航返回。
- **U5** 停止加载或取消任务不撤销网页已提交的表单、脚本副作用或已完成的下载；结果标为 cancelled / incomplete，而不是“已回滚”。

## 时限

- **L1** 分层时限：导航 30 秒；固定的读取脚本 10 秒；`execute_js` 45 秒；单个标签的串行槽位等待 60 秒；CLI 外层 90 秒。内层先超时并释放资源，避免一个不结束的 Promise 卡住整个会话。
- **L2** 导航 30 秒超时后，返回“未完成，页面可能部分加载或渲染进程卡住”，而 WKWebView 可能仍在工作。看到这个文案时，不论结果中的 `success` 字段是什么，都不声称页面已加载完成；应读取当前 URL / DOM、重试或新建标签。
- **L3** JavaScript 超时只解除 App 这边的等待，脚本可能仍在 WebKit 中运行。在同一标签继续操作前，先检查 DOM / URL 或重建标签。
- **L4** DOM 稳定只表示连续采样无变化，不代表网络、动画或业务异步都已结束。
- **L5** 整页截图高度上限为 32,768 像素，超出时明确标记截断。截图成功只证明捕获了当前 WebView 状态，不证明页面语义完整。

## Cookie 与登录

- **C1** 所有标签使用 `WKWebsiteDataStore.default()` 和共享的 `WKProcessPool`，以支持跨标签登录和 OAuth。因此 Cookie 和网站存储在 App 浏览器范围内共享，**不按聊天会话隔离**：一个会话的登录或退出可能影响另一个会话。退出登录或写入、修改 Cookie 时，向用户说明这可能影响其他聊天会话的登录状态。
- **C2** Cookie 备份用于缓解 ITP 在无真实用户手势时清除登录 Cookie：按可注册域名保存 Netscape 格式的本地文件，保留 domain / path / expires / secure / HttpOnly。现有 Cookie 优先；只有缺失且未过期的备份才重新注入。
- **C3** 备份文件使用 `completeUntilFirstUserAuthentication` 保护，排除在系统备份之外；域名 30 天未访问即清理；以 1000 个域名为淘汰目标，超出时从没有活跃 Cookie 的域名中淘汰最久未访问的，有活跃 Cookie 的域名不参与淘汰，因此活跃域名超过 1000 个时不能降到 1000（见“待决定”）。它不是 Keychain，不跨设备同步，不保证永久登录。
- **C4** `get_cookies` 把原始值写入受控的 env 文件，结果中只给路径。日志、任务记录、错误信息不复制 Cookie 或 Authorization；`set_cookies` 接收敏感输入时优先用文件而不是 shell 参数。

## 下载与 fetch

- **D1** 原生 WKDownload 保存到会话的 `/var/minis/workspace/` 对应目录，并向 Agent 报告 started / completed / failed / cancelled。Agent 看到 “browser is handling download natively” 后，不再用 curl / wget 重复下载。取消时删除部分文件；只有 completed 才表示文件完整。
- **D2** `fetch` 在当前页面的 JavaScript 上下文中执行，继承该网站的网络和 Cookie 条件；返回的二进制保存到会话的 `/var/minis/browser/`，引用为 `minis://browser/<文件名>`，与原生下载的落点不同。跨域、认证、Content-Disposition、WebKit 限制都可能导致失败。
- **D3** `fetched_bytes` 或返回了 URL 不代表已写盘成功；写入失败和之后不可读都要可观察。
- **D4** `minis://` 只映射 MinisX 已允许的本地路径，不扩大 iOS 沙盒。

## 后台与诊断

- **B1** WKWebView 的 WebContent 是独立进程，App 自身的内存或 CPU 正常不代表浏览器进程健康。
- **B2** 动作超过 30 秒且 App 在后台时，记录一次卡住快照；URL 与标题同时消失作为渲染进程可能已终止的间接证据，不是确定的系统诊断。
- **B3** iOS 可能在后台暂停 WebContent，使导航或 JS 无法按时返回；浏览器自动化不承诺可以无限期后台运行。

## 待决定

- [待决定] 轮次之间的接管没有独立超时，存在卡住的风险（U3）。
- [待决定] 浏览器 Cookie 是长期保持 App 全局共享，还是为敏感场景提供隔离的 data store（C1）。
- [待决定] Cookie 备份是否需要严格的域名上限；当前 1000 只是淘汰目标，活跃 Cookie 涉及的域名全部保留（C3）。
- [待决定] 导航超时结果的 `success` 字段是否应改为 false（L2）。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 两个 Agent 并发导航 | 不覆盖仍在使用或宽限期内的标签；必要时分配新标签并各自返回 `tab_id`；之后按 id 读取得到对应页面，不串页（T3） |
| 达到全局标签上限 | 优先回收其他 pool 的空闲标签；没有空闲时，被抢占的使用中标签下次收到明确的 retry，并可恢复最后的 URL；不把动作转到别的页面，不伪报成功（T2、T5） |
| 脚本的 Promise 永不结束 | 约 45 秒给出明确超时，在 60 秒串行等待前释放调用方；后续操作先检查标签是否健康，必要时重建（L1、L3） |
| 一个会话登录，另一个会话打开同一网站；之后退出登录或修改 Cookie | 两者可能共享登录 Cookie，不声称会话隔离；退出或修改 Cookie 时告知用户可能影响其他会话的登录状态；敏感值不进入普通日志（C1、C4） |
| 网站触发原生下载 | 状态从 started 到 completed / failed / cancelled 可观察；completed 的文件在该会话的 workspace 中，cancelled 的部分文件已删除；Agent 不重复下载（D1） |
| 在后台执行导航 | 被系统暂停或 WebContent 终止时，返回超时、reclaimed、渲染进程错误，或回到前台后可诊断的状态；没有证据时不声称页面加载和远端动作成功（B2、B3） |
| 用户接管后按 Stop | 覆盖层解除，等待被恢复，所有加载停止，工具标记为 cancelled / incomplete，已发生的网页副作用保留并告知用户（U4、U5） |
| 用户正常结束接管 | 新截图进入后续上下文，Agent 不按接管前的 DOM 继续（U2） |

## 代码入口

- 动作与管理：[BrowserUseActions](../../src/ios/Agent/BrowserUse/BrowserUseActions.swift)、[BrowserUseManager](../../src/ios/Agent/BrowserUse/BrowserUseManager.swift)
- 标签池与回收：[BrowserTabPool](../../src/ios/Agent/BrowserUse/BrowserTabPool.swift)
- Cookie 备份：[CookieBackupStore](../../src/ios/Agent/BrowserUse/CookieBackupStore.swift)
- CLI：[BrowserUseOffload.m](../../src/ios/NativeOffloads/BrowserUseOffload.m)、[BrowserUseOffloadBridge](../../src/ios/NativeOffloads/BrowserUseOffloadBridge.swift)
- 接管超时：[BackgroundTask](../../src/ios/Agent/Chat/AIChatViewModel+BackgroundTask.swift)
- 诊断：[BrowserResourceMonitor](../../src/ios/Diagnostics/BrowserResourceMonitor.swift)
