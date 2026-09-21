# MinisX 日历重复创建接口

本文描述 apple-calendar create 的重复创建能力，不改变开发流程或审批规则。最低 iOS 26.0。
验证状态见任务 `tasks/archive/26-09-20 支持完整日历重复创建/verification.md`，不能将参数表等同于真机测试通过。

## 当前验收限制

全部公开参数已接入。用户已明确同意将年度周次及其组合列为本次个人使用交付的已知限制，暂缓修复、不阻塞其他功能交付；决定见任务 acceptance.md。原“所有接口均可用”的目标尚未全部实现：iOS 26.4 与 27.0 模拟器中，年度周次 `weeksOfTheYear` 能保存/回读规则，却只查询到首次发生。绕过 MinisX 的直接 EventKit 对照也复现；正周次、负周次、有无 count、额外月份/年度日期筛选均未解决。尚无真机证据，不能推断所有真实 iPhone 都失败。

涉及年度周次的 create/list 返回 warnings，Agent 必须向用户说明并核查后续日期。不得把规则保存成功或存在 recurrenceRules 当作重复生效。测试保留此项失败断言；未跳过、未改成预期失败。按用户确认的范围，本次交付验收完成；该决定不等于年度周次已可用或整套测试全通过。

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

## Apple 公开接口覆盖

| EventKit 能力 | 命令参数 | 值与适用范围 |
| --- | --- | --- |
| 简单 / 完整 EKRecurrenceRule 构造器 | `--recurrence` | daily / weekly / monthly / yearly |
| interval | `--recurrence-interval` | 正整数，默认 1 |
| daysOfTheWeek | `--recurrence-days-of-week` | MO,TU,WE,TH,FR,SA,SU；周/月/年规则 |
| EKRecurrenceDayOfWeek weekNumber | 同上，如 `2TU,-1FR` | 月/年支持 ±1…±53；省略序号表示每个该星期；系统进一步校验周期适用性 |
| daysOfTheMonth | `--recurrence-days-of-month` | ±1…±31；仅月规则 |
| monthsOfTheYear | `--recurrence-months-of-year` | 1…12；仅年规则 |
| weeksOfTheYear | `--recurrence-weeks-of-year` | ±1…±53；仅年规则；已知限制，本次暂缓 |
| daysOfTheYear | `--recurrence-days-of-year` | ±1…±366；仅年规则 |
| setPositions | `--recurrence-set-positions` | ±1…±366；至少一个前述日期筛选参数 |
| recurrenceEnd = nil | 不传 count/until | 无限重复 |
| recurrenceEndWithOccurrenceCount | `--recurrence-count` | 正整数，包含首次 |
| recurrenceEndWithEndDate | `--recurrence-until` | YYYY-MM-DD 包含事件时区的整个当天；或带偏移的 ISO 8601 时间，包含该时间点 |
| addRecurrenceRule / recurrenceRules | create 内部接入 | 保存一条原生规则；Apple 只支持一条，即使属性类型是数组 |

所有列表用逗号分隔；负数表示倒数，0 不合法。星期序号 0 的语义用不带序号的星期表示。
`count` 和 `until` 互斥。间隔、结束条件和高级参数必须与 `--recurrence` 一起使用。
参数超范围、缺值、重复选项、拼错的 recurrence 选项及系统会忽略的频率/参数组合返回 `invalid_args`，不保存事件。
合法筛选组合可能没有匹配日期；本接口不自动调整用户的日期条件。

Apple 没有公开设置 `firstDayOfTheWeek` 或 `calendarIdentifier` 的接口；两者仅回读。
每两周等多周规则的周起点由系统处理。没有小时/分钟重复、任意 RRULE 字符串或多规则并集创建接口。
本次接口用于日历事件创建。既有系列修改/删除继续使用 `--occurrence-date`、`--span`；不新增修改重复规则参数。

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
| 每年第 2 周与倒数第 2 周的周三（已知限制，暂缓） | `--recurrence yearly --recurrence-weeks-of-year 2,-2 --recurrence-days-of-week WE` |
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
