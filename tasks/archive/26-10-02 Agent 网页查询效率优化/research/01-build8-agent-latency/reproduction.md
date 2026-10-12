# Build 8 高德查询：模拟器复现与 Pi 对照

调查日期：2026-10-01，Asia/Taipei。调查完成，未修改应用行为。原会话的记录分析见 [verification.md](verification.md)。

## 结论

前台模拟器复现了反复等待网页导航超时：5 次高德网页导航合计 162.03 秒，占本次运行约 70.6%。本次未产生最终答复，在 229.37 秒后因 Responses API 工具输出配对错误停止。简化请求进一步证明：在两份工具输出之间插入图片会返回相同类型的 400；将两份工具输出放在图片之前则返回 200。

Pi 使用同一官方 `deepseek-flash` 模型、High 思考设置和相同问句，81.20 秒完成答复。该结果支持优先调查工具等待和请求组织方式；两套环境的协议、工具及系统提示不同，不能据此直接推断框架的通用速度差异。

## 1. 测试条件与统计口径

问句逐字使用原文：

> 我可能希望给当前的 APP 接一下高德的 MCP，然后可能来负责做行程规划这方面的东西吧。我想让你帮我查一下大概的接入这个 API 的价格和收费情况。

| 项目 | 原手机会话 | 新模拟器会话 | Pi 对照 |
| --- | --- | --- | --- |
| 结果 | 已生成最终答复 | 接口错误停止，未生成最终答复 | 已生成最终答复 |
| 时间 | 17:17:17—17:30:43，806 秒 | 19:21:33.506—19:25:22.878，229.37 秒 | 19:28:10.085—19:29:31.288，81.20 秒 |
| 模型 | deepseek-flash，用户确认官方 API | DeepSeek-V4.1-Flash，deepseek-flash | deepseek-flash，官方 provider |
| 思考设置 | 截图显示 high，历史全过程无法确认 | 新会话设置 high；构造器将其映射到 reasoning.effort | 实际请求观察到 thinking.enabled 和 reasoning_effort=high |
| 主 Agent 模型请求 | JSON 有 59 条助手记录，缺少 HTTP 计数 | 23 次 DISPATCH，其中 22 次成功进入工具轮次，最后 1 次报错 | 25 次请求，响应状态均为 200 |
| 工具调用 | 59 次，58 个工具批次 | 26 次，22 个工具批次 | 40 次 bash 调用 |
| 锁屏/后台 | 用户确认等待期间锁屏 | 26 次工具派发均记录 appState=fg、suspended=false | macOS 命令行进程 |
| 传输与网页工具 | 历史导出缺少实际 API 路径及工具结果 | 官方 /v1/responses；WKWebView、iSH、read_image | openai-completions；原生 bash/curl |

原截图“95”不等于 95 次模型请求：其统计把工具块和思考块一起计入，原会话 59 个工具块 + 36 个思考块正好为 95。不同列中的“请求”“助手记录”“工具调用”不可相互替代。

模拟器使用维护者已经启动的 iPhone 18 Pro，设备 UUID `479131C9-8187-44E7-8510-A499D7AC3034`，iOS 27，应用版本 1.13 / Build 8，构建时间 `2026-10-01T10:08:07Z`。没有重新构建或安装应用，也没有改变全局 Xcode 路径。它是本次现有 DEBUG 二进制，不据此认定与原手机上的归档二进制完全相同。

测试会话 ID `1910F8AF-E6B0-4C54-B597-B9AAFEA4F586`。通过运行时发现的 `chat.prompt` 创建新应用会话，指定现有 DeepSeek 模型条目并设置 high，调用正常的 `AIChatViewModel.send()` 路径。Provider 配置为 `openAIResponses`，基础地址 `https://api.deepseek.com`，请求记录实际地址为 `https://api.deepseek.com/v1/responses`。没有启用替代模型回退。

Pi 在空目录 `/private/tmp/minisx-pi-amap-comparison` 中运行，保留原生工具，排除无关项目上下文、技能和提示模板。观察扩展只记录请求模型、思考字段和状态，不改变请求，不增加工具。Pi 使用自己的现有官方 DeepSeek 凭据；未导出或记录凭据。模型相同不代表账号、协议、系统提示、网络路径和工具实现相同。

## 2. 已确认：导航等待占据主要时间

下表是工具结果快照中的实际执行耗时；不是相邻消息时间差。

| 高德页面 | 工具耗时 | 导航等待结果 |
| --- | ---: | --- |
| /api/mcp-server/summary | 32.587 秒 | 30 秒超时，没有 didFinish/didFail |
| /api/mcp-server/billing | 32.496 秒 | 30 秒超时，没有 didFinish/didFail |
| /upgrade#price | 32.165 秒 | 30 秒超时，没有 didFinish/didFail |
| /upgrade | 32.295 秒 | 30 秒超时，没有 didFinish/didFail |
| /api/mcp-server/gettingstarted | 32.486 秒 | 30 秒超时，没有 didFinish/didFail |
| 合计 | **162.029 秒** | 其中固定导航等待约 **150 秒** |

这些导航依次执行，因此上述 162 秒可以与整轮 229 秒比较。多出的约 2.2—2.6 秒包含导航后的工具处理。此前 Google 搜索导航为 11.135 秒，正常完成。

页面并非完全不可读取：超时后，正文、链接和截图工具仍取得内容；运行中读取 `gettingstarted` 页面时，`document.readyState` 为 `loading`，应用的 `isLoading` 已为 false，页面标题、尺寸和内容可以取得。证据证明加载完成回调没有到达而工具一直等待超时；尚不能确定具体哪个资源或 WebKit 内部机制阻止了加载完成，也没有测量正文首次可用的精确时刻。

`BrowserUseManager.swift:69` 将导航上限设为 30 秒；`:780` 等待 navigationContinuation；`:795` 记录没有完成/失败回调；`:818` 在超时后返回当前页面信息。`BrowserUseActions.swift:202` 的 success 默认 true，所以这 5 份结果在结构上均为成功，仅文字说明超时。部分加载可用是有效状态，但目前没有独立的结构字段区分“导航完成”“超时后内容可用”“页面不可用”。

26 次工具派发均为前台，没有 suspended 标记。**锁屏不是本次等待的必要触发条件**。原手机锁屏是否产生额外暂停，仍需要真机日志，不能由此次前台模拟器测试排除。

22 次成功请求的 STREAM-OPEN 延迟为 0.18—0.49 秒，平均约 0.25 秒；这只是建立响应流的时间，不等于完整生成时间。本次存在明确的 150 秒工具等待，不能将主要等待笼统归因于 High 思考或模型 API 首次响应。

## 3. 已复现：多张图片的工具输出顺序错误

最后一个成功模型响应同时发起 2 次 read_image。两个工具结果均已成功保存，26 次工具调用均有匹配的工具结果。随后第 23 次请求被拒绝：

```text
[400] No tool output found for tool call call_01_ET_wDDfQdW36XjCtoXheEUg0322.
request_id: 87f2fda8-a5da-4446-8ac9-57890b9660d5
```

`OpenAIAgentProvider.swift:1733` 的 Responses 转换器逐个处理工具结果，先附加 function_call_output，再立即把该工具产生的图片附加为合成 user 消息。因此，同一批次两张图片会形成如下顺序：

```text
function_call A
function_call B
function_call_output A
user(image A)
function_call_output B
user(image B)
```

对官方同一模型发送两个简化请求，仅改变这部分顺序，结果为：

| 顺序 | HTTP 结果 | 响应 |
| --- | --- | --- |
| output A → image A → output B → image B | **400** | No tool output found for tool call call_probe_b |
| output A → output B → image A → image B | **200** | OK |

探针使用 64×64 PNG、相同 reasoning.effort=high、两个相同工具定义及结果；凭据仅在进程内读取，没有写入请求证据。两个诊断请求不计入上表的主 Agent 请求数。

因此，该序列化方式与本次报错具有直接的对照实验支持。需要修复为先提交该批次全部 function_call_output，再附加图片，并验证单图、多图和混合工具批次。工具已成功执行、结果已入库，仅重试同样请求不能解决顺序问题。

证据边界：应用自身的请求捕获约 512 KiB 截断，先前图片使最后一批数据超出截断位置；没有声称已取得完整失败请求。数据库配对、相同源码转换器和官方简化请求对照共同支持此结论。原手机导出没有图片工具结果和实际 API 路径，不能把此次 400 当作原会话 13 分 26 秒的原因。

## 4. Pi 对照的含义

Pi 25 次模型请求均返回 200，40 次 bash 工具调用中有 30 次命令包含 curl。两次早期命令使用了 macOS 不存在的 timeout 程序，随后模型改用 curl 的 --max-time 继续查询；所以工具包装层未标记错误并不代表每条命令都完全成功。

最终答复涵盖免费额度、超额费用、QPS、商业许可和行程规划估算，列出官方定价页、MCP 概述、创建 Key 和流量限制页。原文保存在 [pi-answer.md](evidence/reproduction/pi-answer.md)。该文件是测试模型的答复，不是本调查对所有价格、许可适用范围及 MCP 配额映射的独立业务核验。

Pi 没有等待 WKWebView 全页加载完成，而是获取 HTML 并提取文本。即使工具调用次数多于本次 MinisX，仍在约 81 秒完成。由此可见，单纯降低工具调用次数不足以解释或解决耗时；每次工具的等待语义和信息获取方式更值得优先处理。

原手机总时长约为此次 Pi 的 9.9 倍，但只有各一次运行，且测试环境、协议、上下文和工具不同。模拟器本轮报错停止，不能把 229 秒当作其成功答复时间计算速度比。未进行真机锁屏对照或严格的多次基准测试。

## 5. 对原分析的修正与建议

原 JSON 中多次 32—34 秒的消息间隔，与此次实际 30 秒导航等待加工具处理的模式一致，明显增强了“导航等待累积”这一判断。原运行具体有多少次超时仍无法从缺少工具结果的 JSON 确定。

建议后续修复顺序：

1. **浏览器导航完成条件与返回状态。** 区分全页加载、内容可读和真正失败；在确认属于当前目标页面后允许正文可用时继续查询，保留明确的时间上限。不能只缩短所有页面的固定超时，也不能把部分加载一律标成完全失败。验收应覆盖高德动态页面、正常页面、未成功跳转和锁屏恢复。
2. **Responses 多图片工具结果顺序。** 先输出同批全部工具结果，再附加图片；覆盖并行 2 张图片、单张图片、图片与文本混合输出，以及取消/恢复后历史重放。本次官方探针已经提供直接失败与通过的对照。
3. **查询收敛与循环统计。** 以实际模型请求/工具轮次计数，单独显示工具次数和思考块；以已获得的信息、连续无新信息和导航重试来约束研究过程。原同参数循环检测不能识别换标签页、换脚本的反复查询，相关静态分析见 verification.md。

本阶段只完成调查和实验。没有修改以上行为，没有运行针对修复的构建或回归测试，也没有提交、合并或推送。

## 6. 可复查材料

证据目录：[evidence/reproduction](evidence/reproduction)。关键文件：

- `simulator-start.json`、`simulator-session-config.json`、`app-info.json`：新会话、模型、思考设置及二进制信息。
- `simulator-running.log`：完整实验时段日志，包含 23 次请求派发、26 次工具派发、导航超时及 400 错误。
- `simulator-db-final.json`：仅本次测试会话的 45 条数据库消息，保留工具结果和配对 ID。
- `browser-info-midrun.json`：页面 readyState、标题和尺寸。
- `llm-requests-final.json`：实际 Responses 路径及截断请求；敏感认证头已脱敏。
- `responses_order_probe.py`、`responses-order-probe.json`：顺序问题探针和官方接口返回结果。
- `pi-start.json`、`pi-finish.json`、`pi-provider-observations.jsonl`：启动参数、耗时、实际模型/思考字段和 25 个 HTTP 200。
- `pi-events.jsonl`、`pi-sessions/`、`pi-answer.md`：Pi 工具事件、会话和完整答复。

模拟器结束状态轮询在 19:25:33 才观察到停止，`simulator-finish.json` 的 240.38 秒包含轮询滞后。本文按日志 19:25:22.878 的 isProcessing=false 计算 229.37 秒。agentTrace 的 inProgress 标记在接口失败后残留，因此未用它判定运行仍在继续。

本次相关 Responses 转换器和 BrowserUseActions 与原工作目录源码相同；BrowserUseManager 的差异仅为 Bilibili 本地文件隐私检查，不位于网页导航路径。上述源码核对不代替归档二进制一致性证明。
