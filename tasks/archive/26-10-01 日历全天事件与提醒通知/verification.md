# 验证记录

## App 内实际执行（2026-10-01）

设备：iPhone 18 Pro 模拟器，iOS 27.0，`479131C9-8187-44E7-8510-A499D7AC3034`。先用 `debug.appInfo` 确认数据路径属于该设备，并确认已安装构建的 `Minis.debug.dylib` 含新代码。通过 `debug.shellExecute` 在 iSH 中执行，不经过模型。

| 操作 | 结果 | 规则 |
| --- | --- | --- |
| `apple-calendar --help`、`apple-reminders --help` | 列出 `--all-day`、`--notify`、精确匹配说明 | — |
| `create --start 2026-12-01 --end 2026-12-03` | 12-01 00:00 至 12-03 23:59:59，`is_all_day=true`，`time_zone=null`，含 `calendar_id` / `calendar_source` | D1、D2、D7、M2 |
| `create ... --calendar NoSuchCal` | `invalid_args`，列出 'Calendar'、'Birthdays'、'US Holidays' | M1 |
| 全天 + `--time-zone Asia/Tokyo` | `invalid_args` | D4 |
| 东京时区每周定时事件 `update --all-day --span all` | **缺陷**：变成 11-02 至 11-03 两天。已修复，见下 | D4、D6 |
| 上述全天事件改回定时 | 起止等于传入值，EventKit 自动绑定当地时区（Asia/Taipei），与新建普通定时事件一致 | D6、B3 |
| 提醒 `--due 2026-10-20` | `due=2026-10-20`，`is_all_day=true`，`notify=false` | R1、R2、R6、R7 |
| 提醒 `--due 2026-10-02T18:00` | `notify=true`，`notify_at=18:00` | R2、R7 |
| 提醒 `--list NoSuchList` | `invalid_args`，列出 'Reminders' | M1 |
| `apple-reminders list` | 两条提醒的 `is_all_day` 与 `due` 格式正确 | R6 |
| 清理 | 3 个事件、2 个提醒全部删除，回查为 0 | — |

## 审查意见处置（reviewer，静态审查）

| 意见 | 处置 |
| --- | --- |
| 缺陷：update 的日期无法解析时，全天事件被悄悄转为定时 | 已修：无法解析的 `--start` / `--end` 在改动前返回 `invalid_args`；测试覆盖 `foo`、`2027-02-30` |
| 缺陷：事件 create 不再拒绝 `--notify` | 不改：`--due`、`--list` 原本就有同类问题，影响小 |
| 疑点：全天 / 定时互转的时区 | 定时 → 全天在 App 内复现多跨一天，已修（转全天前清除 `timeZone`），新增 `testAllDayUpdateClearsEventTimeZone`；全天 → 定时实测正常 |
| 疑点：提醒 update 在位置校验失败前已改动通知 | 已知限制：对象未保存，标题、截止原本就有同样顺序 |
| 疑点：完全同名的日历或清单取第一个 | 已知限制，待用户决定 |
| 疑点：全天事件只传一端带时刻的日期 | 符合 D6 字面规定，待用户决定是否细化 |
| 疑点：`relativeOffset` 类型的提醒通知不计入 | 已知限制：本命令只创建绝对时间通知 |

## XCTest

见任务记录中的验收项；日志保存在本地，不入库。
