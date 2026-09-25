# 26-09-22 实测 AI 创建重复日历事件
状态：done
更新：2026-09-22

## 恢复信息
分支：main；最近核验 HEAD：10a0955。
下一步：无；测试系列和聊天保留供用户查看。
待审批：无。用户已在模拟器配置 API，要求实际验证能否创建重复事件。

## 目标与验收
- [x] 使用已验证的 1.13 MinisX 及用户原有 API 配置。
- [x] 由自然语言聊天创建一个原生重复系列，而非3个单次事件。
- [x] 回读每月最后一个工作日 2026-09-30 / 10-30 / 11-30，Asia/Shanghai 15:00–15:30，共3次；12月无第4次。
- [x] 保留测试结果供用户查看；不修改无关事件，不输出 API 密钥。

## 上下文与决定
用户当前使用 iPhone 18 Pro / iOS 27.0，UDID 479131C9-8187-44E7-8510-A499D7AC3034。初查安装的仍是1.11，因此将已构建验证的1.13原位安装并启动。simctl 更新会改变数据容器路径；不能以路径相同判断数据保留。升级后已核实原 DeepSeek provider 仍存在且 hasCredential=true，默认组仍使用 DeepSeek Flash；未读取密钥。
本轮只做运行验证，不修改应用源码，不重新打开旧 Bug。
测试标题：MinisX 测试：每月最后一个工作日 0922。无邀请、无提醒。
测试聊天：C1B2506F-3209-4B2F-A852-35E12C17F01C。

## Spec 阅读清单
- docs/specs/ios-calendar-recurrence.md 全文：规则、回读与已知年度周次限制。
- docs/specs/debug-server-api.md 的连接/协议、应用信息、提供方列表、模型列表、聊天发送/消息/状态各完整节；另核查当前 DebugAuth.swift 配对及加密实现、DebugMethodRegistry.swift 的 shellExecute 参数。

## 验证证据
测试请求和返回值临时保存在当前 Codex 任务目录 migration-evidence/recurrence-live-2026-09-22；结束时仅归档本次测试证据，不含 API 密钥或本地调试 token。

## 最终验收
- 通过。DeepSeek Flash 根据自然语言选择 `--recurrence monthly --recurrence-days-of-week MO,TU,WE,TH,FR --recurrence-set-positions -1 --recurrence-count 3`，只成功执行一次 create。
- 主 Agent 独立发起全新 apple-calendar list 查询，筛选精确测试标题后保存结果，不依赖模型文字声明。查询窗口 2026-09-01 至 2027-01-01，无结果截断。
- 发生日期正好为 2026-09-30、2026-10-30、2026-11-30，均为 Asia/Shanghai 15:00–15:30；12月没有第4次。三条记录 id 相同、is_recurring=true，回读唯一原生规则 monthly / interval=1 / MO–FR / set_positions=[-1] / count=3。无 alarms 和 attendees。
- 运行中首次日历请求因系统弹窗未响应而超时并返回 authorization_denied；第一次模拟 tap 报告完成但未真正关闭系统弹窗。改用 physical 触摸点击允许完全访问后，系统弹窗关闭，原会话继续完成创建和验证。不得把这一环境阻塞误报为重复规则失败。
- 首轮应用内模型自动写入了一条当日权限失败记忆；第二轮已明确禁止 memory_write，未再次写入。本轮没有修改 Codex 全局记忆或 API 密钥。
- debug.shellExecute 的第一次权限检查在15秒内超时；最终独立查询使用 stdinScript=true / 同一测试 sessionId，exitCode=0 且未超时。
- 应用源码无改动，不重新执行构建、Pi 或全量回归；本次证据仅证明上述实际聊天与规则在 iOS27 模拟器通过，不能替代所有规则或真机验证。
- 测试事件保留在模拟器默认「日历」，未删除；本次调试配对 token 完成后单独撤销。

## 证据文件
- prompt.json / dispatch.json / dispatch-after-permission.json：本次请求与会话。
- chat.messages.list.json：本次测试聊天和工具返回；接口对单个工具结果截取前2000字符，完整断言以独立回读为准。
- independent-readback.json：独立回读的三个测试事件（已过滤其他标题）。
- assertions.json：对实际日期、相同系列ID、时区、重复规则、结束次数、无提醒/邀请及无截断的断言通过。
