# 日历重复创建验证记录

> 最新交付状态：用户已明确接受年度周次作为低频已知限制，暂缓修复且不阻塞本次交付；按修订范围验收完成，决定见 acceptance.md。下文保留各阶段原始验证事实，早期“完整验收未通过”是对原全接口要求的判断。最新完整运行仍为两平台各 26 组、22 通过、4 个年度周次失败（退出码 65），未改写为全通过。


日期：2026-09-20。分支：feat/minisx-branding；基线：0f1ba5f；代码尚未提交。

## 结论

完整公开参数已接入，但“所有重复创建接口均可用”的验收未通过。
最终产品代码在 iOS 26.4 与 iOS 27.0 模拟器上各运行 24 组集成测试：每个版本 20 组通过、4 组失败。失败均涉及年度周次 weeksOfTheYear，包含绕过 MinisX 的直接 EventKit 对照。

## 验证方式

- 使用 Xcode 27 / iPhoneSimulator SDK 27，最低部署版本仍为 iOS 26.0。
- 独立 MinisCalendarTests scheme 构建实际 MinisX App 与 Objective-C XCTest bundle。
- 测试从产品 calendar_offload_handle 统一命令入口执行真实参数解析、权限检查、EventKit 保存；独立 EventStore 回读规则并查询实际发生日期。
- 检查每个发生日期、持续时长、结束边界及指定日历归属；不是仅检查规则对象构造成功。
- 测试日历使用独立随机标题；正常 tearDown 删除自身精确日历。
- 模拟器日历授权通过 simctl 预授予；没有验证首次系统授权弹窗流程。

## 覆盖矩阵

| 能力 | 真实保存/回读与日期检查 | 结果 |
| --- | --- | --- |
| daily / weekly / monthly / yearly | 各频率、间隔、计数结束 | 两个版本通过 |
| 每两周组会 | 2027-01-01、01-15、01-29 | 两个版本通过 |
| 每两周周二/周五 | 01-01、01-12、01-15、01-26 | 两个版本通过 |
| 星期列表 | 七天全表、多星期 | 两个版本通过 |
| 星期正/负序号 | 月/年第二个与最后一个周二、年度第 53 个周四边界 | 两个版本通过 |
| 月内日期 | 1/-1、多日期、31 日跳过不存在月份 | 两个版本通过 |
| 年内月份 | 多月份；月份 + 星期序号 | 两个版本通过 |
| 年内日期 | 1/-1、第 60 日跨闰年、第 366 日边界 | 两个版本通过 |
| 年内周次 | 正周次、正负组合、BYSETPOS 组合 | 两个版本失败，原生对照也失败 |
| setPositions | 周/月/年；正负位置；与星期、月日期、月份、年度日期组合 | 两个版本通过；年度周次组合失败 |
| 结束方式 | 各频率无限/日期/次数；次数包含首次；日期包含当日；精确时间边界 | 两个版本通过 |
| 时区与夏令时 | America/New_York 跨春季 DST 保持 09:00 当地时间 | 两个版本通过 |
| 单次事件回归 | 单次、地点、备注、提前提醒 | 两个版本通过 |
| 非法输入 | 40 个缺失、错误、越界、溢出、互斥、无效日期组合；确认未写入 | 两个版本通过 |
| 指定日历不存在 | 明确报错，不写入默认日历 | 两个版本通过 |

## 年度周次未通过项

保留失败断言，不 skip、不使用 XCTExpectFailure。

1. testPositiveWeeksOfYear：年规则第 2 周周三，仅首次 2027-01-13；应还有 2028-01-12、2029-01-10。
2. testWeeksOfYear：第 2 周和倒数第 2 周周三，仅首次；后续三个日期未返回。
3. testSetPositionsAcrossSelectors：年度周次加 -1 位置仅首次；其余五类 setPositions 组合通过。
4. testNativeWeekNumberReference：完全直接 EventKit 构造/保存相同规则，也只返回首次。

进一步原生诊断：有无 count、正/负周次、额外所有月份或所有年度日期、去掉星期筛选、查询单独后续年份，均未解决。规则保存/回读仍含 BYWEEKNO。对 17:40 保存的测试系列在 18:00 再次只读查询，20 分钟后仍只有首次，排除了即时展开延迟。证据只适用于已测模拟器，尚不能断言真机也失败。

产品 create/list 针对此规则返回 warnings，AI 提示要求核查未来发生日期且披露限制。

## 验证边界

- 没有连接真实 iPhone；真机日历、iCloud/Exchange/CalDAV 日历服务、完整自然语言 AI 到 shell 的实际会话尚未验证。
- 普通 MinisTests 在既有 ToolPreflightTests.swift 处因 AgentToolDefinition 未在测试模块可见而编译失败，故新增独立日历测试目标；未修改无关测试。
- XcodeBuildMCP 受全局 CommandLineTools 选择影响无法找到 simctl；使用进程级 DEVELOPER_DIR。xcodebuild 自动故障诊断也提示找不到 simctl，但 XCTest 的用例结果、退出码和 xcresult 已产生。
- git diff --check 与 project.pbxproj 格式检查通过；两平台 XCTest 实际运行证明 App/测试目标构建和装载成功；未单独验证真机签名构建。
- 正常后续测试清理成功。早期测试清理失效遗留 9 个专用测试日历，以及首次 iOS 27 日历缓存问题产生的 3 个默认日历测试系列；精确清单已核对，清理待单独授权。

## 重现入口

在仓库使用进程级 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer，运行 MinisCalendarTests scheme，destination 指定 iOS Simulator。
最终日志：calendar-accepted-26.log / calendar-accepted-27.log（calendar-final-* 为审查前 21 组的记录）；早期原生对照：calendar-weeks.log / calendar-native-week.log。
最初版本年度周次失败到最终版本均一致；后续测试只因新增校验/修复/复核系统差异而重复。

## 审查调整后的验证

审查 R1/R2 的文档问题已补齐。R3 中“默认浮动时区”的推断被实际 SDK 行为否定，改用旧 EventKit 创建路径对照，保留原来不主动设置 timeZone 的行为。R4 补入 3 组测试，覆盖时区默认/非法值、时间顺序与非 create 参数拦截；总计 24 组，两平台均为 20 组通过、4 组年度周次失败；新增时区和非法输入用例均通过。

复现命令（从仓库根目录运行，选择已经启动的对应模拟器）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project src/ios/Minis.xcodeproj -scheme MinisCalendarTests -configuration Debug \
  -destination 'platform=iOS Simulator,id=A6D580D2-1D43-4307-BD75-8D7E3504E282,arch=arm64' \
  -derivedDataPath build/ios-simulator CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
  -disableAutomaticPackageResolution test
```

iOS 27 使用 simulator id `479131C9-8187-44E7-8510-A499D7AC3034`。日历权限预授予 `com.openminis.app`，真实应用首次授权仍待用户操作验证。

## 独立审查状态

旧快照首轮超时，第二轮返回 nonblocking 和 4 条意见，但缺少必填 certainty，故 Harness 状态仍为 incomplete。意见已修复并在两平台重新运行 24 组测试。修改后快照外发被自动审批拒绝（旧授权不覆盖新快照），已询问本任务后续必要复核的授权；正式 Pi 复核尚未完成。不能将 nonblocking 建议写成最终验收通过。

## 004 审查后时区解析修复验证

2026-09-20 20:44：两平台各 5 项针对性回归全部通过。修复仅改变 --time-zone 的按位置解析；当前共有 25 个测试方法，未重新运行整套 25 项，原两平台各 24 项（20 通过、4 个年度周次失败）仍作为完整回归的历史证据。

本次运行 testTimeZoneOptionLikeValuesAreLiteral、testDefaultTimeZoneCompatibility、testInvalidDatesAndTimeZonesDoNotSave、testSelectorLikeNotesAreLiteral、testTimeZoneAndDaylightSaving。新增用例真实保存并读取标题/备注/地点中的 --time-zone 字面量（前后位置共 6 种），另验证有效时区与同名文字并存。

复现：沿用上述 xcodebuild 命令，分别添加 -only-testing:MinisCalendarTests/CalendarRecurrenceTests/<上述每个方法名>。iOS 26.4 使用 test 构建并运行，iOS 27 使用同一构建 test-without-building。原始日志为 calendar-zone-fix-26.log、calendar-zone-fix-27.log，压缩副本保留于 evidence。

原始日志摘录：

```text
iOS 26
Test Case '-[CalendarRecurrenceTests testDefaultTimeZoneCompatibility]' passed (0.515 seconds).
Test Case '-[CalendarRecurrenceTests testInvalidDatesAndTimeZonesDoNotSave]' passed (0.656 seconds).
Test Case '-[CalendarRecurrenceTests testSelectorLikeNotesAreLiteral]' passed (0.394 seconds).
Test Case '-[CalendarRecurrenceTests testTimeZoneAndDaylightSaving]' passed (0.352 seconds).
Test Case '-[CalendarRecurrenceTests testTimeZoneOptionLikeValuesAreLiteral]' passed (0.486 seconds).
	 Executed 5 tests, with 0 failures (0 unexpected) in 2.403 (2.406) seconds
	 Executed 5 tests, with 0 failures (0 unexpected) in 2.403 (2.406) seconds
	 Executed 5 tests, with 0 failures (0 unexpected) in 2.403 (2.407) seconds
** TEST SUCCEEDED **
iOS 27
Test Case '-[CalendarRecurrenceTests testDefaultTimeZoneCompatibility]' passed (1.395 seconds).
Test Case '-[CalendarRecurrenceTests testInvalidDatesAndTimeZonesDoNotSave]' passed (0.372 seconds).
Test Case '-[CalendarRecurrenceTests testSelectorLikeNotesAreLiteral]' passed (0.475 seconds).
Test Case '-[CalendarRecurrenceTests testTimeZoneAndDaylightSaving]' passed (0.485 seconds).
Test Case '-[CalendarRecurrenceTests testTimeZoneOptionLikeValuesAreLiteral]' passed (0.637 seconds).
	 Executed 5 tests, with 0 failures (0 unexpected) in 3.364 (3.370) seconds
	 Executed 5 tests, with 0 failures (0 unexpected) in 3.364 (3.371) seconds
	 Executed 5 tests, with 0 failures (0 unexpected) in 3.364 (3.375) seconds
** TEST EXECUTE SUCCEEDED **
```

用户已授权更新后的 Pi 复核及复核通过后的精确残留清理。004 报告完整（reviewed / nonblocking）；已知限制 R1 保持开放，R2 实际修复并如上验证。新快照复核待完成。

## 005 审查后完整回归（当前版本）

创建命令按位置识别全部文字选项，共用帮助/输出开关跳过已消费的取值；未知创建选项（包括拼错 recurrence 前缀）明确失败。新增 66 种选项名称作为文字的真实保存回读，另有 --time-zone 的 7 种组合；两种前缀拼写错误验证不写入。测试共 26 组。

iOS 26.4 与 iOS 27.0 均完整运行：22 通过、4 失败。全部失败仍为 testNativeWeekNumberReference、testPositiveWeeksOfYear、testSetPositionsAcrossSelectors、testWeeksOfYear；无新增失败。整体测试退出码 65，不能写为全测试通过。其余普通日程、时区、结束条件及参数检查均通过。

使用原重现命令且不加 only-testing：iOS 26.4 test，iOS 27 test-without-building（同一构建）。原始日志 calendar-complete-26.log / calendar-complete-27.log，压缩副本在 evidence。

```text
iOS 26
Test Case '-[CalendarRecurrenceTests testNativeWeekNumberReference]' failed (1.073 seconds).
Test Case '-[CalendarRecurrenceTests testPositiveWeeksOfYear]' failed (0.356 seconds).
Test Case '-[CalendarRecurrenceTests testSetPositionsAcrossSelectors]' failed (0.458 seconds).
Test Case '-[CalendarRecurrenceTests testWeeksOfYear]' failed (0.346 seconds).
	 Executed 26 tests, with 4 failures (0 unexpected) in 12.446 (12.456) seconds
iOS 27
Test Case '-[CalendarRecurrenceTests testNativeWeekNumberReference]' failed (0.648 seconds).
Test Case '-[CalendarRecurrenceTests testPositiveWeeksOfYear]' failed (0.360 seconds).
Test Case '-[CalendarRecurrenceTests testSetPositionsAcrossSelectors]' failed (0.486 seconds).
Test Case '-[CalendarRecurrenceTests testWeeksOfYear]' failed (0.364 seconds).
	 Executed 26 tests, with 4 failures (0 unexpected) in 138.812 (138.827) seconds
```

当前最终复核待 006；005 原始报告及逐项处置保留在 reviews/005。历史报告位于 snapshot/tasks/.../reviews（不在 requirements 副本），供只读核对。

## 最终复核与残留清理

006 完整 Pi 报告为 reviewed / nonblocking，主 Agent 已逐条处置（reviews/006/resolution.md）。当前代码复核通过，年度周次完整功能验收仍开放。当前最终完整结果为两平台各 26 项，22 通过、4 失败；上方 24/25 项是历史阶段记录。

2026-09-20 21:03：通过 EventKit 精确删除 iOS 26.4 的 9 个测试日历（22 组日程）和 iOS 27 默认日历中的 3 组测试日程。只读数据库库存比对证明：两个模拟器其他日历及事件记录全部一致，默认日历未删。iOS 27 首次清理在删除前因月份回读断言停止；月频率不支持月份筛选，EventKit 回读为 nil，而数据库原始规则仍与清单完全一致。再次核对后成功清理，原日志保留。

证据：evidence/cleanup-before.json、cleanup-after.json、calendar-cleanup-26.log.gz、calendar-cleanup-27.log.gz、calendar-cleanup-27-retry.log.gz。临时测试源码恢复且全部 src 文件哈希与 006 已审查快照一致，无产品修改。
