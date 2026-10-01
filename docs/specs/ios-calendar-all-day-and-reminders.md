---
description: apple-calendar / apple-reminders 的全天事件、全天提醒、到点通知、日历与清单名精确匹配及返回的归属字段。
---

# MinisX 日历全天、提醒通知与名称匹配

导航：[Spec 索引](index.md)。重复规则见 [日历重复创建](ios-calendar-recurrence.md)。

范围：事件的全天创建与切换、提醒的全天截止与到点通知、写入目标日历或清单的名称匹配，以及 create / update / list 等结果中对应的字段。参考上游 OpenMinis 1.14，两处有意不同（D3、D4）。最低 iOS 26.0。

## 基本用法

```sh
apple-calendar create --title "年假" --start 2026-12-01 --end 2026-12-03
apple-calendar update --id <event_id> --start 2026-12-01T14:00 --end 2026-12-01T15:00
apple-reminders create --title "给银行打电话" --due 2026-10-02T18:00 --list Work
apple-reminders create --title "续签护照" --due 2026-10-20
```

## 全天事件

- **D1** create 在两种情况下创建全天事件：传了 `--all-day`；或者 `--start` 和 `--end` 都是纯日期（`YYYY-MM-DD`）。
- **D2** 全天事件按设备当地日历，从开始日 00:00:00 到结束日 23:59:59，包含结束日；单天事件的开始和结束写同一天；带 `--all-day` 时，参数里给的时刻被忽略。
- **D3** 全天事件的结束日不能早于开始日，否则返回 `invalid_args`，不保存。上游会改成单天，MinisX 按参数错误处理。
- **D4** 全天事件不绑定时区；同时传 `--time-zone` 返回 `invalid_args`。全天重复系列按设备当地日历展开，`--recurrence-until YYYY-MM-DD` 取当地的整天。
- **D5** 全天事件可以跟任一套重复参数组合；[F2](ios-calendar-recurrence.md#两套参数) 的“不能混用”仍然适用。
- **D6** update 的全天切换：
  - 转为全天：传了 `--all-day`，或者传入的起止参数全是纯日期；按日期取整，没传的一端用事件原来的日期；
  - 转为定时：传了带时刻的 `--start` 或 `--end`，且没有 `--all-day`；回读的起止时间等于传入的时刻；
  - 只改其他字段时，全天状态不变；
  - `--start` 或 `--end` 无法解析（包括不存在的日期）时返回 `invalid_args`，事件保持不变。
- **D7** 事件的 create、update、list 返回 `is_all_day`，取自保存后的事件。

## 全天提醒与到点通知

“到点通知”指提醒上的时间型 `EKAlarm`：由提醒事项 App 弹出通知横幅，不是时钟 App 的闹钟。

- **R1** `--due YYYY-MM-DD` 创建全天提醒：截止只有日期，没有时刻。带时刻的截止保持原格式。update 的 `--due` 可以在全天和定时之间双向切换。
- **R2** create 时，带时刻的截止（包括 `-2h` 这类相对时间）自动加一个到点通知；纯日期不加。`--notify on|off` 覆盖默认；`on` 需要截止时间；取值无效或 `on` 缺少截止时间时返回 `invalid_args`，不保存。
- **R3** update 时：
  - `--notify off` 去掉时间通知；`--notify on` 在当前截止时间加一个通知；
  - 只改 `--due`：已有的时间通知移到新时间；原来没有通知，就按 R2 的默认处理；
  - 改成纯日期时去掉时间通知，除非同时传了 `--notify on`。
- **R4** 通知规则只增删时间通知，位置提醒保持不变。
- **R5** 截止时间变化时，提醒隐藏的开始时间（`startDateComponents`）同步为相同的值。
- **R6** 提醒的 create、update、list 在有截止时间时返回 `is_all_day`；全天提醒的 `due` 写成 `YYYY-MM-DD`，定时提醒保持 ISO 8601。
- **R7** 提醒的 create 在有截止时间时返回 `notify`，有通知时再附 `notify_at`；update 总是返回 `notify`。

## 名称匹配与归属

- **M1** 写入目标 `--calendar`（事件 create / update）和 `--list`（提醒 create / update）按名称完全一致匹配，忽略大小写。找不到时返回 `invalid_args`，错误信息列出所有候选名称；不写入默认日历或清单，也不保留旧的归属。名称有歧义时，由调用方从候选中选择后重试。
- **M2** 事件的 create / update / delete 返回 `calendar_id`、`calendar_source`；提醒的 create / update / complete / delete 返回 `list_id`、`list_source`。

## 不在范围内

- 提醒的 `--url` 字段（上游 1.14 有，暂不引入）。
- list 查询中的 `--calendar` / `--list` 过滤条件，仍按原有方式匹配。
- 通知横幅是否真正弹出：模拟器只能回读 `EKAlarm`，弹出效果需在真机确认。

## 验收场景

| 场景 | 期望 |
| --- | --- |
| `--all-day` 单天；纯日期跨 3 天 | 当天 00:00 到结束日 23:59:59，`is_all_day=true`（D1、D2、D7） |
| 结束日早于开始日；全天加 `--time-zone` | `invalid_args`，不保存（D3、D4） |
| 全天加每周重复 | list 查到的后续发生都是全天，日期正确（D5） |
| 定时 → 全天、全天 → 定时、只改标题 | 符合 D6 |
| 提醒：纯日期 / 带时刻 / 相对时间截止 | 全天无通知 / 定时有通知 / 有通知（R1、R2、R6、R7） |
| `--notify on` 无截止；`--notify maybe` | `invalid_args`，不保存（R2） |
| 提醒 update：改时刻、改成纯日期、`--notify off`；带位置提醒 | 通知随之移动或去掉，位置提醒保留，开始时间同步（R3–R5） |
| `--calendar Work` 但只有 “Workout”；提醒 `--list` 找不到 | `invalid_args` 并列出候选，没有写入（M1） |
| 结果字段 | 含 ID 与来源（M2） |

## 代码与依据

- 实现：[CalendarOffload.m](../../src/ios/NativeOffloads/CalendarOffload.m)、[NativeOffloadUtils.m](../../src/ios/NativeOffloads/NativeOffloadUtils.m)；`apple-reminders` 入口与帮助：[RemindersOffload.m](../../src/ios/NativeOffloads/RemindersOffload.m)
- 测试：[CalendarRecurrenceTests.m](../../src/ios/CalendarTests/CalendarRecurrenceTests.m)（`MinisCalendarTests` scheme）
- 上游参考：OpenMinis tag `1.14` 的 `CalendarOffload.m`、`NativeOffloadUtils.m`
- Apple 文档：[EKEvent.isAllDay](https://developer.apple.com/documentation/eventkit/ekevent/isallday)、[EKReminder.dueDateComponents](https://developer.apple.com/documentation/eventkit/ekreminder/duedatecomponents)、[Setting an alarm](https://developer.apple.com/documentation/eventkit/setting-an-alarm)
