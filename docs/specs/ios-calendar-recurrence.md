---
description: apple-calendar 重复事件创建、两套参数兼容、结束条件、回读验证以及年度周次的已知限制。
---

# MinisX 日历重复创建接口

导航：[Spec 索引](index.md)。全天事件、提醒通知与名称匹配见 [日历全天与提醒通知](ios-calendar-all-day-and-reminders.md)。

范围：`apple-calendar create` 创建重复事件的参数、兼容规则、结束条件与回读。`--recur` 是 OpenMinis v1.13 的兼容参数族，`--recurrence` 是 MinisX 的高级参数族。最低 iOS 26.0。

## 基本用法

```sh
apple-calendar create --title "组会" \
  --start 2027-01-01T15:00:00+08:00 --end 2027-01-01T16:00:00+08:00 \
  --time-zone Asia/Shanghai --recurrence weekly --recurrence-interval 2
```

- **B1** 保存的是系统原生的重复系列；查询某个时间窗口即可得到各次发生，不需要 App 在后台逐次创建。
- **B2** `--start` / `--end` 定义第一次发生，开始日期应符合筛选条件；之后每次保持事件时区中的本地时间。
- **B3** 重复系列的 `--time-zone` 默认为设备当地时区；普通单次事件不指定时不设置时区，沿用 EventKit 默认。指定其他时区时，起止时间都应带明确的 UTC 偏移。
- **B4** 定时事件的结束时间必须晚于开始时间；全天事件按 [D3](ios-calendar-all-day-and-reminders.md#全天事件)。
- **B5** `--calendar` 按 [M1](ios-calendar-all-day-and-reminders.md#名称匹配与归属) 做完全一致的名称匹配；找不到时返回 `invalid_args` 并列出候选，不写入默认日历。
- **B6** 保存重复系列时使用 `EKSpanFutureEvents`（沿用 v1.13）。

## 两套参数

- **F1** v1.13 的 `--recur`、`--recur-interval`、`--recur-days`、`--recur-count`、`--recur-until` 继续可用。频率支持 day / week / month / year / annually，星期可写 mon、monday 或 MO；基础规则由日历与提醒事项共用的构造器处理。
- **F2** 一次 create 只能使用一套参数，不能混用 `--recur-*` 与 `--recurrence-*`。混用、重复选项、缺值、没有主频率的辅助选项都返回 `invalid_args`。
- **F3** 月份筛选、星期序号、年度日期、setPositions 等高级规则只能用 `--recurrence` 系列（见下表）。
- **F4** 两套参数的截止日期语义不同：
  - `--recurrence-until YYYY-MM-DD` 包含事件时区的整个当天；带时区的时间可以等于首次开始时间；
  - `--recur-until` 按通用日期解析，必须严格晚于首次开始，纯日期不扩展到当天结束。为避免歧义，应传带偏移的明确时间。
- **F5** `--time-zone` 可以与任一参数族一起使用。
- **F6** 提醒事项只使用 `--recur` 系列和 `--clear-recur`，保留位置提醒。`apple-reminders create / update` 和 `apple-calendar remind / update-reminder` 在保存或修改之前拒绝 `--recurrence` 选项并返回 `invalid_args`，不静默创建单次提醒；标题、备注等文本中出现 “--recurrence” 字样时按原文处理。

## 高级参数（EventKit 映射）

| EventKit 能力 | 命令参数 | 取值与适用范围 |
| --- | --- | --- |
| EKRecurrenceRule 构造器 | `--recurrence` | daily / weekly / monthly / yearly |
| interval | `--recurrence-interval` | 正整数，默认 1 |
| daysOfTheWeek | `--recurrence-days-of-week` | MO,TU,WE,TH,FR,SA,SU；周、月、年规则 |
| EKRecurrenceDayOfWeek weekNumber | 同上，如 `2TU,-1FR` | 月、年规则支持 ±1…±53；不带序号表示每个该星期；系统会进一步校验是否适用 |
| daysOfTheMonth | `--recurrence-days-of-month` | ±1…±31；仅月规则 |
| monthsOfTheYear | `--recurrence-months-of-year` | 1…12；仅年规则 |
| weeksOfTheYear | `--recurrence-weeks-of-year` | ±1…±53；仅年规则；见 [年度周次的现行限制](#年度周次的现行限制) |
| daysOfTheYear | `--recurrence-days-of-year` | ±1…±366；仅年规则 |
| setPositions | `--recurrence-set-positions` | ±1…±366；需要至少一个上述日期筛选参数 |
| 无结束 | 不传 count / until | 无限重复 |
| 按次数结束 | `--recurrence-count` | 正整数，包含首次 |
| 按日期结束 | `--recurrence-until` | 见 F4 |
| recurrenceRules | create 内部使用 | 保存一条原生规则；Apple 只支持一条，尽管属性类型是数组 |

- **A1** 列表用逗号分隔；负数表示倒数，0 不合法；星期序号 0 的含义用不带序号的星期表示。
- **A2** `count` 与 `until` 互斥；间隔、结束条件和高级参数都必须与 `--recurrence` 一起使用。
- **A3** 超出范围、缺值、重复选项、拼错的选项、系统会忽略的频率与参数组合，都返回 `invalid_args`，不保存事件。
- **A4** 合法的筛选组合可能没有匹配的日期；接口不自动调整用户的日期条件。
- **A5** Apple 没有公开设置 `firstDayOfTheWeek` 和 `calendarIdentifier` 的接口，两者只能回读；多周规则的周起点由系统决定。没有按小时或分钟重复、任意 RRULE 字符串、多规则并集的创建接口。
- **A6** 修改或删除已有系列继续使用 `--occurrence-date` 和 `--span`；没有修改重复规则的参数。

## 回读结果

- **O1** create 和 list 的结果包含 `is_recurring`、`time_zone`、`recurrence_rules`。每条规则包含 frequency、interval、days_of_week、days_of_month、months_of_year、weeks_of_year、days_of_year、set_positions、end、calendar_identifier、first_day_of_week。`end.type` 为 never / count / until，并附带 count 或 date。单次事件的 `recurrence_rules` 为空数组。
- **O2** 同时返回 v1.13 的 `recurrence` 摘要（字段名和基础星期写法不变）；复杂规则读取 `recurrence_rules`。单次事件省略 `recurrence`。
- **O3** 规则是否生效，通过 list 查询实际发生的日期来确认；不能只看构造出的对象或回读的规则。

## 年度周次的现行限制

- **W1** `--recurrence-weeks-of-year` 及其组合可以表达、保存和回读，但不视为已验证可用。维护者接受把它作为低频的已知限制暂缓修复（依据见 [验收记录](<../../tasks/archive/26-09-20 支持完整日历重复创建/acceptance.md>)）；这不代表以后可以普遍忽略低频缺陷。
- **W2** 包含年度周次的规则，create 和 list 结果中附带 warning（模拟器无法展开后续日期，真机未验证）。看到该 warning 时，Agent 向用户说明限制，并用 list 查询实际的后续日期。
- **W3** 取得新的运行证据之前，不宣称限制已修复；也不把相关的失败断言跳过、改为预期失败，或用检查 warning 代替日期断言。
- **W4** 历史证据：2026-09-20 在 iOS 26.4 和 27.0 模拟器上各运行 26 项测试，均为 22 项通过、4 项年度周次相关失败；规则可以保存和回读，但查询只得到首次发生，直接调用 EventKit 也复现（见 [验证记录](<../../tasks/archive/26-09-20 支持完整日历重复创建/verification.md>)）。该结果只适用于当时的代码和模拟器，不能推断真机行为。

## 复杂示例

在 create 命令后加上：

| 目标 | 重复参数 |
| --- | --- |
| 每周二、周五，共 10 次 | `--recurrence weekly --recurrence-days-of-week TU,FR --recurrence-count 10` |
| 每月第二个周二 | `--recurrence monthly --recurrence-days-of-week 2TU` |
| 每月最后一个周五 | `--recurrence monthly --recurrence-days-of-week -1FR` |
| 每月第一天与最后一天 | `--recurrence monthly --recurrence-days-of-month 1,-1` |
| 每月最后一个工作日 | `--recurrence monthly --recurrence-days-of-week MO,TU,WE,TH,FR --recurrence-set-positions -1` |
| 每年 2 月、3 月的第二个周二 | `--recurrence yearly --recurrence-months-of-year 2,3 --recurrence-days-of-week 2TU` |
| 每年第 2 周与倒数第 2 周的周三（受 W1 限制，必须查询后续日期） | `--recurrence yearly --recurrence-weeks-of-year 2,-2 --recurrence-days-of-week WE` |
| 每年第一天和最后一天 | `--recurrence yearly --recurrence-days-of-year 1,-1` |
| 每天重复到指定日期 | `--recurrence daily --recurrence-until 2027-06-30` |

## 验收场景

| 场景 | 期望 |
| --- | --- |
| 创建“每月第二个周二”等复杂重复事件 | 按参数表创建后，用 list 查询后续发生日期确认（O3） |
| 混用两套参数、参数越界、无效的结束条件 | 返回 `invalid_args`，不保存事件（F2、A2、A3） |
| 在提醒事项命令中使用 `--recurrence` | 返回 `invalid_args`，不创建单次提醒（F6） |
| 使用年度周次 | 结果带 warning；核查后续日期；不宣称限制已修复（W1–W3） |

## 代码与依据

- 实现：[CalendarOffload.m](../../src/ios/NativeOffloads/CalendarOffload.m)（`apple-reminders` 的创建与更新也委托给其中的函数）
- 测试：[CalendarRecurrenceTests.m](../../src/ios/CalendarTests/CalendarRecurrenceTests.m)（`MinisCalendarTests` scheme）
- 权限与能力边界：[设备能力清单](ios-device-data-capabilities.md)
- Apple 文档：[创建重复事件](https://developer.apple.com/documentation/eventkit/creating-a-recurring-event)、[EKRecurrenceRule](https://developer.apple.com/documentation/eventkit/ekrecurrencerule)、[EKRecurrenceDayOfWeek](https://developer.apple.com/documentation/eventkit/ekrecurrencedayofweek)、[EKRecurrenceEnd](https://developer.apple.com/documentation/eventkit/ekrecurrenceend)、[单规则限制](https://developer.apple.com/documentation/eventkit/ekcalendaritem/recurrencerules)
