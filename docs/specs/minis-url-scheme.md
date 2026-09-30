---
description: minis:// 资源地址与应用导航的双重契约，覆盖会话隔离、全局目录、外部挂载、渲染、深链和路径安全。
---

# Minis URL Contract

导航：[Spec 索引](index.md)。

范围：`minis://` 在聊天渲染、工具结果、文件读写、iSH 路径映射、外部挂载、App 内深链中的用法。`minis://` 同时用于资源引用和应用导航，两者共用 scheme，但解析规则不同。

## 两类 URL

- **K1** 资源 URL：`minis://<resource-host>/<relative-path>`，定位文件或内容，例如 `minis://attachments/photo.jpg`、`minis://workspace/report.csv`、`minis://skills/example/SKILL.md`、`minis://mounts/MyDrive/folder/file.pdf`。解析结果是受约束的本地或挂载文件 URL。
- **K2** 导航 URL：`minis://<route-host>/<path>?<query>`，触发 App 导航或动作，例如 `minis://sessions/SESSION_ID`、`minis://settings/permissions`、`minis://open_terminal?init_command=pwd`。
- **K3** 导航路由不退化为文件解析；资源 host 也不因与某个页面同名而触发页面动作。

## 会话资源

| Host | iSH 路径 | 内容 |
| --- | --- | --- |
| `attachments` | `/var/minis/attachments` | 输入附件和可展示的媒体 |
| `offloads` | `/var/minis/offloads` | 超长工具输出、原生 offload 文件 |
| `workspace` | `/var/minis/workspace` | 会话工作文件 |
| `browser` | `/var/minis/browser` | 浏览器截图、文本等产物 |

- **R1** 这四个 host 绑定到会话：同一个 URL 在不同会话中指向不同文件。URL 不携带 session id，解析方从执行上下文、活动会话或消息归属取得。
- **R2** 会话资源只在所属会话的目录内解析；找不到时返回“不可解析”，不扫描其他会话并返回同名文件（现状见“待决定”）。
- **R3** Host 上的位置为 `Library/MinisChat/minis/<session-id>/<bucket>/<relative-path>`，由 `MinisFsRouter` 的 `fs_context` 路由；每次 shell 执行带所属会话的 context，子进程继承。并发会话各自访问自己的目录，不存在“切换会话时复制工作副本”的机制。

## 全局资源

- **G1** `skills`、`memory`、`shared` 映射到 App 的全局持久目录，跨会话可访问。只有 host 明确是这三者时才使用全局目录，它们不是会话资源找不到时的兜底。
- **G2** URL 可以解析，不代表对应功能已启用、正文已注入、已获得操作授权或删除已跨设备完成。Skill 启停见 [Skill 生命周期](ios-skills-lifecycle.md)，Memory 注入与文件访问的区别见 [Memory 生命周期](ios-memory-lifecycle.md)。

## 用户挂载资源

- **M1** `minis://mounts/<mount-name>/<path>` 先按挂载名找到用户授权的外部目录，再解析相对路径。读取依赖 security-scoped 授权和外部 Provider 的可用性；写入还要检查挂载是否只读。
- **M2** 主线程聊天渲染为避免被 File Provider 或网络挂载阻塞，可以先返回一个尚未确认存在的候选 URL，再由异步加载显示成功或失败占位。生成了 URL 不代表文件存在或可读。

## 路径安全

- **S1** 所有把 URL 路径转为文件系统路径的消费者都要：
  1. 解码出相对路径，拒绝空 host、绝对路径、NUL、非法组件和试图逃逸的 `..`；
  2. 规范化候选路径（适用时考虑符号链接）；
  3. 确认结果仍在授权根目录之内，用目录包含关系判断，而不是字符串前缀；
  4. 写入外部挂载前，检查授权仍有效且不是只读；
  5. 失败时返回“不可解析”，不去尝试其他会话。

## 工具结果与聊天渲染

- **C1** 工具产生需要后续引用的持久资源时，返回可复制的 `minis://` URL，并附必要的人类可读说明。
- **C2** 界面按消息所属的会话解析资源；新增调用点显式携带 session id，不只依赖全局“当前活动会话”，以免历史消息异步渲染或切换会话时出现竞态。
- **C3** 位图图片类型为 `png`、`jpg`、`jpeg`、`gif`、`webp`、`bmp`、`tiff`；`svg` 按 HTML 内容处理。内联类型还包括常见的音频、视频、文本、Markdown、HTML 和文档；未知扩展名显示文件链接和通用图标，不猜测为可执行或可预览。
- **C4** 外部挂载或远端 Provider 加载失败时，显示可观察的失败或占位状态，不显示其他会话的同名文件。

## 导航路由

[DeepLinkRouter](../../src/ios/Shared/DeepLinkRouter.swift) 是路由表的来源。稳定的路由族：

| Host | 行为 |
| --- | --- |
| `share` | 打开待处理的分享界面 |
| `views/alarm` | 打开闹钟列表 |
| `open_terminal` | 打开终端，可带 `init_command` |
| `open` | 处理 Web App launcher 返回的参数 |
| `sessions`（兼容 `session`） | 按路径中的 id 打开会话 |
| `settings` | 打开设置首页或子页 |

- **N1** 未知的顶层 host 记录日志后忽略；缺少会话 id 时忽略。
- **N2** 未知的 settings 子路径回退到设置首页，避免生成的链接把用户留在无响应状态。设置子路由和别名变化较快，以源码为准，本文不复制完整清单。

## 待决定

- [待决定] R2 的现状缺口：[RequestBudget](../../src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift) 中的 `resolveMinisURL` 在活动会话和全局目录都找不到时，会扫描所有会话目录。这违反会话隔离，是实现缺陷而不是兼容行为。修复前，涉及把资源内容加入模型请求的改动都要检查是否经过这个解析器。
- [待决定] S1 各解析器是否完整覆盖路径穿越，尚无统一测试。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 会话 A、B 都有内容不同的 `attachments/result.png` | 在 A 中只显示 A 的文件，在 B 中只显示 B 的；一方删除自己的文件后显示“找不到”，不显示另一方的版本（R1、R2） |
| 多个会话引用 `skills/example/SKILL.md` | 都解析到同一全局文件；把 host 改成 `workspace` 后回到各自的会话目录（G1） |
| 用户授权了一个只读外部挂载 | 可以读取存在的文件；写入被明确拒绝；授权失效或远端不可用时显示失败，不阻塞主线程，也不回退到内部同名路径（M1、M2、C4） |
| `minis://settings/permissions` 与 `minis://attachments/settings/permissions` | 前者打开设置中的权限页；后者只尝试解析会话文件，不触发导航（K3） |
| 编码或多重编码的 `..`、绝对路径、符号链接逃逸 | 都不能越过授权根目录；失败时不做跨会话搜索（S1） |

## 代码入口

- 聊天资源解析与媒体类型：[MinisMediaViews](../../src/ios/Views/Chat/MinisMediaViews.swift)
- Agent 文件工具：[FileTools](../../src/ios/Agent/Chat/AIChatViewModel+FileTools.swift)
- 请求预算中的 URL 解析：[RequestBudget](../../src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift)
- 会话目录路由：[MinisFsRouter](../../src/ios/Agent/ISH/MinisFsRouter.swift)
- 导航：[DeepLinkRouter](../../src/ios/Shared/DeepLinkRouter.swift)
