---
description: minis:// 资源地址与应用导航的双重契约，覆盖会话隔离、全局目录、外部挂载、渲染、深链和路径安全。
---

# Minis URL Contract

导航：[Spec 索引](index.md)。

状态：现行安全契约与当前实现并列记录。`minis://` 同时承载资源引用和应用导航，两类 URL 共享 scheme，但不得用同一解析规则处理。

## 适用范围与来源

适用于聊天渲染、工具结果、文件读写、iSH 路径映射、外部挂载、App 内深链及跨平台链接。主要源码来源：

- [MinisMediaViews.swift](../../src/ios/Views/Chat/MinisMediaViews.swift)：聊天资源解析和媒体类型。
- [AIChatViewModel+FileTools.swift](../../src/ios/Agent/Chat/AIChatViewModel+FileTools.swift)：Agent 文件工具解析。
- [AIChatViewModel+RequestBudget.swift](../../src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift)：请求预算中的 URL 内容解析及已知偏差。
- [MinisFsRouter.swift](../../src/ios/Agent/ISH/MinisFsRouter.swift)：会话目录到 iSH 的路由。
- [DeepLinkRouter.swift](../../src/ios/Shared/DeepLinkRouter.swift)：导航路由。

本文不把“文件存在”当成“允许访问”，也不把当前某个解析器的宽松行为提升为规范。

## 两类 URL

### 资源 URL

形式为 `minis://<resource-host>/<relative-path>`，用于定位文件或内容。例如：

```text
minis://attachments/photo.jpg
minis://workspace/report.csv
minis://skills/example/SKILL.md
minis://mounts/MyDrive/folder/file.pdf
```

资源解析需要明确的会话或全局上下文，结果是受约束的本地/挂载文件 URL。

### 导航 URL

形式仍是 `minis://<route-host>/<path>?<query>`，用于触发 App 导航或动作。例如：

```text
minis://sessions/SESSION_ID
minis://settings/permissions
minis://open_terminal?init_command=pwd
```

导航路由不得退化为文件解析；资源 host 也不得因为与某个页面同名而触发页面动作。

## 资源作用域

### 会话资源

以下四个 host 绑定调用方/消息所属会话：

| Host | iSH 路径 | 语义 |
|---|---|---|
| `attachments` | `/var/minis/attachments` | 输入附件和可展示媒体 |
| `offloads` | `/var/minis/offloads` | 超长工具输出或原生 offload 文件 |
| `workspace` | `/var/minis/workspace` | 会话工作文件 |
| `browser` | `/var/minis/browser` | 浏览器截图、文本及相关产物 |

同一个 URL 字符串在不同会话中可以指向不同文件。资源 URL 不携带 session id；解析方必须从执行上下文、活动会话或消息归属取得 session id。

规范要求：会话资源只能在其所属会话目录内解析。找不到时返回不可解析，不得扫描其他会话并返回第一个同名文件。

当前并非所有消费者已满足这一要求：[请求预算解析仍会跨会话扫描](#请求预算解析仍会跨会话扫描)记录已知违约路径。将资源加入模型请求或独立读取本小节时必须一并核对该偏差，不能把隔离要求当成实现已全面通过验证。

### 全局资源

`skills`、`memory`、`shared` 由当前实现映射到 App 的全局持久目录，可跨会话访问。它们不是会话目录的 fallback：只有 host 明确为这些值时才使用全局根目录。

全局资源地址不表达Agent功能开关或删除传播：Skill启停与会话覆盖见[Skill生命周期](ios-skills-lifecycle.md#关闭不等于禁止文件访问)，Memory注入、专用工具与全局文件访问的区别见[Memory生命周期](ios-memory-lifecycle.md#默认值会话开关与生效时点)。不得从URL可解析推导正文已注入、已获得操作授权或删除已跨设备完成。

### 用户挂载资源

`minis://mounts/<mount-name>/<path>` 先通过挂载名解析用户授权的外部目录，再解析相对路径。读取依赖安全作用域授权和外部 Provider 可用性；写入还必须检查挂载是否只读。

主线程聊天渲染当前可能为了避免 FileProvider 或网络挂载阻塞而返回一个尚未验证存在的候选 URL，随后由异步加载显示成功或占位失败。维护者不能据此把“已生成 URL”当成“文件已存在或可读”。

## iSH 与 Host 路由

会话目录通过 `MinisFsRouter` 的 `fs_context` 路由到：

```text
Library/MinisChat/minis/<session-id>/<bucket>/<relative-path>
```

每次 shell 执行带所属会话的 context；子进程继承该 context。`memory`、`skills`、`shared` 和外部挂载走静态挂载层，不属于四个会话 bucket。

这不是“切换会话时清空并原子复制一份 `/var/minis` 工作副本”的契约。并发会话可通过各自 context 同时访问各自目录。

## 路径安全契约

所有把 URL 路径转为文件系统路径的消费者必须：

1. 解码出相对路径，拒绝空 host、绝对路径、NUL、非法组件和意图逃逸的 `..`；
2. 标准化候选 URL（包括符号链接影响适用时）；
3. 验证结果仍是授权根目录的后代，而不是只检查字符串前缀；
4. 外部挂载写入前检查授权存续和只读状态；
5. 失败时返回不可解析，不得尝试其他会话。

当前各解析器的完整路径穿越覆盖尚未通过统一测试证明；因此这是必须满足的安全要求，也是待补验证项，而不是对现状的无条件认证。

## 工具结果与聊天渲染

- 工具产生需要后续引用的持久资源时，应返回可复制的 `minis://` URL；同时保留必要的人类可读说明。
- UI 解析必须使用消息所属会话。只依赖全局“当前活动会话”时，历史消息异步渲染或会话切换可能产生竞态；新增调用点应显式携带 session id。
- 当前聊天媒体分类中，位图图片为 `png/jpg/jpeg/gif/webp/bmp/tiff`；`svg` 走 HTML 内容类型，而不是原生图片类型。
- 当前内联类型还包括常见音频、视频、文本、Markdown、HTML 和文档；未知扩展名应提供文件链接/通用图标，而不是猜测可执行或可预览。
- 外部挂载或远端 Provider 加载失败时，应显示可观察的失败/占位状态，不能悄然显示另一个会话的同名文件。

## 导航路由

[DeepLinkRouter.swift](../../src/ios/Shared/DeepLinkRouter.swift) 是当前路由表来源。稳定的路由族为：

| Host | 行为 |
|---|---|
| `share` | 唤起待处理分享界面 |
| `views/alarm` | 打开闹钟列表 |
| `open_terminal` | 打开终端；可携带 `init_command` |
| `open` | 处理 Web App launcher 返回参数 |
| `session` / `sessions` | 按路径中的 id 打开会话；复数为规范写法，单数为兼容别名 |
| `settings` | 打开设置或设置子页 |

未知顶层 host 当前会被记录并忽略；缺少会话 id 也会忽略。未知 settings 子路径当前回退到设置首页，以避免生成式链接把用户留在无响应状态。具体设置子路由与别名易变，调用方应以源码和目标版本验证，不应在本 Spec 复制完整清单。

## 已知实现偏差

### 请求预算解析仍会跨会话扫描

已核实：[AIChatViewModel+RequestBudget.swift](../../src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift) 的静态 `resolveMinisURL` 在活动会话和全局目录失败后，仍会扫描全部会话目录。

这违反本 Spec 的会话隔离契约，属于实现缺陷，不是兼容行为。本文不修改代码；在修复并验证前：

- 不得用该路径证明 `minis://` 已完整隔离；
- 涉及把资源内容加入模型请求的改动必须审查是否经过此解析器；
- 找不到活动会话资源时，正确结果应是不可解析，而不是借用其他会话同名文件。

## 场景与验收

### 场景 A：两个会话有同名附件

前提：会话 A、B 都存在 `attachments/result.png`，内容不同。

可观察验收：在 A 渲染只得到 A 的文件，在 B 渲染只得到 B 的文件；任一会话删除自己的文件后显示找不到，绝不显示另一会话的版本。

### 场景 B：全局 skill 在多个会话引用

前提：`skills/example/SKILL.md` 存在。

可观察验收：A、B 都能解析同一全局文件；把 host 改成 `workspace` 后必须回到各自会话目录。

### 场景 C：外部只读挂载

前提：用户授权一个只读挂载。

可观察验收：允许读取存在的文件；写入被明确拒绝；授权失效或远端不可用时显示失败，不阻塞主线程，也不 fallback 到内部同名路径。

### 场景 D：导航与资源不混淆

可观察验收：`minis://settings/permissions` 打开设置权限页；`minis://attachments/settings/permissions` 只尝试解析会话文件，不触发导航。

### 场景 E：路径逃逸

可观察验收：编码或多重编码后的 `..`、绝对路径及符号链接逃逸均不能越过授权根目录；失败不触发跨会话搜索。当前需要新增定向测试后才能把这一项标为运行已验证。
