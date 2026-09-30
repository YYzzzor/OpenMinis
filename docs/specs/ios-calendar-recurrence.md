---
description: apple-calendar 重复事件创建、两套参数兼容、结束条件、回读验证以及年度周次的已知限制。
---

# MinisX 日历重复创建接口

导航：[Spec 索引](index.md)。

状态：现行规范。本文描述 `apple-calendar create` 的重复创建契约、兼容参数和已接受限制；最低 iOS 26.0。参数表和示例说明调用约定，不等于当前分支、模拟器或真机已经运行验证。每次实现变更必须单独记录实际验证范围。

`--recur` 是 OpenMinis v1.13 的兼容参数族，`--recurrence` 是 MinisX 保留的高级参数族；两者的长期兼容关系见下文。本文不改变开发流程或审批规则。

## 年度周次的现行限制

本节刻意区分需要继续遵守的产品约定、当前源码中可见的实现状态和历史运行证据。后两者不能自动提升为设备行为保证。

### 现行约定

- `--recurrence-weeks-of-year` 及其组合保留为可表达的年度规则，但不视为已经验证可用。维护者此前接受将它作为低频已知限制暂缓修复；这项范围取舍的原始依据保存在[验收记录](<../../tasks/archive/26-09-20 支持完整日历重复创建/acceptance.md>)，不代表以后可以普遍忽略低频缺陷。
- create 或 list 返回年度周次 warning 时，Agent 必须向用户说明限制，并用 list 查询实际后续发生日期。规则保存成功、`recurrenceRules` 存在或字段能够回读，都不能单独证明重复已经生效。
- 未取得新的运行证据前，不得宣称限制已经修复，也不得把相关失败断言跳过、改成预期失败或用 warning 检查替代日期断言。

### 当前实现状态

当前源码静态核对显示，[CalendarOffload.m](../../src/ios/NativeOffloads/CalendarOffload.m) 会保存和回读 `weeksOfTheYear`，并在 create/list 结果中附加已测模拟器无法展开后续日期、真机未验证的 warning。[CalendarRecurrenceTests.m](../../src/ios/CalendarTests/CalendarRecurrenceTests.m) 仍保留正周次、正负周次组合、setPositions 组合、直接 EventKit 对照和 warning 透传检查。本段只说明这些实现与测试入口当前存在；本轮文档整理没有运行测试，不能据此声称当前 `main` 的行为已经复测。

### 历史验证证据

[2026-09-20 验证记录](<../../tasks/archive/26-09-20 支持完整日历重复创建/verification.md>)记载：当时的 `feat/minisx-branding` 实现在 iOS 26.4 与 27.0 模拟器各完整运行 26 项测试，结果均为 22 项通过、4 个年度周次相关失败，整体退出码 65。年度周次规则可以保存和回读，但查询只得到首次发生；绕过 MinisX 的直接 EventKit 对照也复现。正周次、负周次、有无 count、额外月份或年度日期筛选均未消除问题。

这些结果只适用于当时记录的代码、模拟器版本和测试环境。没有真实 iPhone、iCloud/Exchange/CalDAV 日历服务或当前 `main` 分支的新增运行证据，因此不能推断所有真实设备都会失败，也不能用旧结果证明当前实现通过或失败。

## 使用方式

```sh
apple-calendar create --title "组会" \
  --start 2027-01-01T15:00:00+08:00 --end 2027-01-01T16:00:00+08:00 \
  --time-zone Asia/Shanghai --recurrence weekly --recurrence-interval 2
```

这会保存一个系统原生重复系列。查询指定时间窗口可以得到各次发生；不需要 App 后台逐次创建。
`--start` / `--end` 定义第一次发生，开始日期应符合筛选条件；后续每次保留事件时区的本地时间。
重复系列的 `--time-zone` 默认设备当地时区；普通单次事件不指定该参数时不主动设置时区，沿用 EventKit 默认行为；指定其他时区时，起止时间应同时使用明确 UTC 偏移，避免无时区时间的歧义。

create 要求结束时间晚于开始时间。指定 `--calendar` 后若找不到该日历会返回 invalid_args，不再静默写入默认日历；调用者应列出日历后使用实际名称。

## v1.13 参数与结果兼容

上游 `--recur`、`--recur-interval`、`--recur-days`、`--recur-count`、`--recur-until` 继续可用。频率还支持 day/week/month/year/annually，星期可用 mon、monday 或 MO 等写法；基础规则仍由 v1.13 的日历/提醒事项共用构造器处理。

一次 create 必须选用完整的一套重复参数，不能混用 `--recur-*` 和 `--recurrence-*`；混用、重复选项、缺值或没有主频率的辅助选项会返回 invalid_args。需要月份筛选、星期序号、年度日期、setPositions 等高级规则时，使用下表的 `--recurrence` 系列。

两套结束日期语义分别保留：`--recurrence-until YYYY-MM-DD` 包含事件时区的整个当天，带时区时间可以等于首次开始；上游 `--recur-until` 继续按通用日期解析器解释，必须严格晚于首次开始，纯日期不扩展到当日结束。为了避免边界歧义，`--recur-until` 应传入带偏移的明确时间。`--time-zone` 可与任一参数族配合使用。

create/list 同时返回上游 `recurrence` 摘要和 MinisX `recurrence_rules` 完整规则；上游字段名称和基础星期写法保持不变。复杂规则应读取 `recurrence_rules`，它包含 ordinal、各日期筛选与结束条件；单次事件仍省略 `recurrence`，但有空的 `recurrence_rules` 数组。

提醒事项继续使用上游 `--recur` 系列与 `--clear-recur`，并保留位置提醒；`--recurrence` 高级参数只用于日历 create，没有扩展到提醒事项。`apple-reminders create/update` 及 `apple-calendar remind/update-reminder` 都会在保存或修改前拒绝这些选项并返回 invalid_args，不会静默创建单次提醒；标题、备注等文本取值中包含 `--recurrence` 字样仍作为原文处理。保存重复日历系列沿用 v1.13 的 `EKSpanFutureEvents`。

## Apple 公开接口覆盖

| EventKit 能力 | 命令参数 | 值与适用范围 |
| --- | --- | --- |
| 简单 / 完整 EKRecurrenceRule 构造器 | `--recurrence` | daily / weekly / monthly / yearly |
| interval | `--recurrence-interval` | 正整数，默认 1 |
| daysOfTheWeek | `--recurrence-days-of-week` | MO,TU,WE,TH,FR,SA,SU；周/月/年规则 |
| EKRecurrenceDayOfWeek weekNumber | 同上，如 `2TU,-1FR` | 月/年支持 ±1…±53；省略序号表示每个该星期；系统进一步校验周期适用性 |
| daysOfTheMonth | `--recurrence-days-of-month` | ±1…±31；仅月规则 |
| monthsOfTheYear | `--recurrence-months-of-year` | 1…12；仅年规则 |
| weeksOfTheYear | `--recurrence-weeks-of-year` | ±1…±53；仅年规则；接口保留但不视为已验证可用，见[现行限制](#年度周次的现行限制) |
| daysOfTheYear | `--recurrence-days-of-year` | ±1…±366；仅年规则 |
| setPositions | `--recurrence-set-positions` | ±1…±366；至少一个前述日期筛选参数 |
| recurrenceEnd = nil | 不传 count/until | 无限重复 |
| recurrenceEndWithOccurrenceCount | `--recurrence-count` | 正整数，包含首次 |
| recurrenceEndWithEndDate | `--recurrence-until` | YYYY-MM-DD 包含事件时区的整个当天；或带偏移的 ISO 8601 时间，包含该时间点 |
| addRecurrenceRule / recurrenceRules | create 内部接入 | 保存一条原生规则；Apple 只支持一条，即使属性类型是数组 |

所有列表用逗号分隔；负数表示倒数，0 不合法。星期序号 0 的语义用不带序号的星期表示。
`count` 和 `until` 互斥。间隔、结束条件和高级参数必须与 `--recurrence` 一起使用。
`--recurrence` 参数超范围、缺值、重复选项、拼错的选项及系统会忽略的频率/参数组合返回 `invalid_args`，不保存事件。
合法筛选组合可能没有匹配日期；本接口不自动调整用户的日期条件。

Apple 没有公开设置 `firstDayOfTheWeek` 或 `calendarIdentifier` 的接口；两者仅回读。
每两周等多周规则的周起点由系统处理。没有小时/分钟重复、任意 RRULE 字符串或多规则并集创建接口。
`--recurrence` 高级接口用于日历事件创建。既有系列修改/删除继续使用 `--occurrence-date`、`--span`；不提供修改重复规则的参数。

## 复杂示例

在相应的 create 命令后增加：

| 目标 | 重复参数 |
| --- | --- |
| 每周二、周五，共 10 次 | `--recurrence weekly --recurrence-days-of-week TU,FR --recurrence-count 10` |
| 每月第二个周二 | `--recurrence monthly --recurrence-days-of-week 2TU` |
| 每月最后一个周五 | `--recurrence monthly --recurrence-days-of-week -1FR` |
| 每月第一天与最后一天 | `--recurrence monthly --recurrence-days-of-month 1,-1` |
| 每月最后一个工作日 | `--recurrence monthly --recurrence-days-of-week MO,TU,WE,TH,FR --recurrence-set-positions -1` |
| 每年 2 月、3 月的第二个周二 | `--recurrence yearly --recurrence-months-of-year 2,3 --recurrence-days-of-week 2TU` |
| 每年第 2 周与倒数第 2 周的周三（限制场景，必须查询后续日期） | `--recurrence yearly --recurrence-weeks-of-year 2,-2 --recurrence-days-of-week WE` |
| 每年第一天和最后一天 | `--recurrence yearly --recurrence-days-of-year 1,-1` |
| 每天重复到指定日期 | `--recurrence daily --recurrence-until 2027-06-30` |

## 回读结果

create 与 list 结果包含 `is_recurring`、`time_zone`、`recurrence_rules`。
每条规则包含 frequency、interval、days_of_week、days_of_month、months_of_year、weeks_of_year、days_of_year、set_positions、end、calendar_identifier、first_day_of_week。
`end.type` 为 never/count/until；另附 count 或 date。单次事件的 recurrence_rules 为空数组。
通过 list 的实际发生日期确认规则效果；复杂规则及日期边界不能只看构造对象判断成功。

## 官方依据

- [创建重复事件](https://developer.apple.com/documentation/eventkit/creating-a-recurring-event)
- [EKRecurrenceRule](https://developer.apple.com/documentation/eventkit/ekrecurrencerule)
- [EKRecurrenceDayOfWeek](https://developer.apple.com/documentation/eventkit/ekrecurrencedayofweek)
- [EKRecurrenceEnd](https://developer.apple.com/documentation/eventkit/ekrecurrenceend)
- [单规则限制](https://developer.apple.com/documentation/eventkit/ekcalendaritem/recurrencerules)

## 维护验收场景

| 场景 | 验收条件与证据 |
| --- | --- |
| 创建每月第二个周二等复杂重复事件 | 按参数表创建后 list 查询后续发生日期；对象构造或规则回读不能代替发生日期验证。 |
| 混用两套重复参数、参数越界或无效结束条件 | 按 v1.13 兼容及公开接口覆盖中的约定检查错误和无保存副作用。 |
| 使用年度周次 | 保留[年度周次的现行限制](#年度周次的现行限制)与 warnings，核查后续日期；未取得新证据前不得宣称该限制已经修复。 |

相关手机权限与能力边界见[能力清单](ios-device-data-capabilities.md)。维护时保留[年度周次的现行限制](#年度周次的现行限制)和[回读结果](#回读结果)作为必要上下文。
