# v1.13 迁移验证

基线：官方 v1.13 `7414c0d6e8ec52e51d158f622e4379654872e7b5`。分支 `feat/minisx-v1.13`，全部实现尚未提交；来源旧分支 `feat/minisx-branding @ 00300d5` 的代码和历史保持原样。

## 构建与实际运行
- Xcode 27.0（27A266a）；SDK 27，最低 iOS 26.0；完整应用、三个扩展、日历测试目标构建成功。证据：build-for-testing-002.log、built-app-identity.json。
- 新版 ContentView 的长 SwiftUI 表达式无法由 Xcode27 在合理时间内推断；按原顺序拆为计算属性，并原文提取首次加载方法。没有新增 View 容器或改变业务条件；完整构建通过。
- 主应用、分享/文件/活动扩展版本均 1.13、minimumOS 均26.0、Bundle ID沿用上游。未修改 App Group、iCloud、Keychain、URL scheme 或数据标识。没有签名身份迁移、Archive、真机或 TestFlight 验证。
- iSH 按 v1.13 的固定子模块重建；Rclone设备/模拟器双slice已构建。FFmpeg来源及补丁树与旧工作区一致后复用已验证模拟器产物。LAME完整重建脚本保留，本轮没有再重建相同依赖。
- Go1.27.1官方工具链校验SHA后放在外部证据目录；Xcode只通过当前进程DEVELOPER_DIR选择，没有改系统设置。MCP UI工具因全局选择为CommandLineTools无法运行，改用其自带AXe程序并给当前进程指定Xcode。
- iOS26.4实际启动：首页显示MinisX、设置入口为“关于 MinisX”、关于页显示当前Logo及版本1.13。截图：launch-26.4.png、about-26.4.png。本地iSH终端已启动到root提示符（terminal-26.4.png）；首次HID输入未完成命令执行；随后使用终端内置回车按钮执行uname，实际返回Linux，见terminal-uname-26.4.png。
- 六份Logo与旧分支逐字节一致；品牌检查见branding-validation.json。九种语言及本地化占位符检查通过。默认Soul显示名映射，存储身份和用户自定义名称/图标不变；未做真实用户数据升级测试。

## 日历与提醒事项
最终含首轮审查修正的同一测试源在 iOS26.4、iOS27.0 各执行34项：每个平台30通过、4失败。详见calendar-results.json及calendar-26.4-r1.log / calendar-27.0-r1.log；修正前32项结果另存calendar-results-before-r1.json。新增两项验证非法提醒参数不会创建/修改数据，字面标题/备注不受影响。
通过项包括日/周/月/年、间隔、多星期、月份/年度日期/ordinal/setPositions、count/until、夏令时与时区、非法参数不保存、普通事件回归、上游--recur别名和完整--recurrence参数、两套until边界、混用拒绝、create/list规则回读及提醒事项创建/更新/清除重复。
四个失败是 testWeeksOfYear、testPositiveWeeksOfYear、testSetPositionsAcrossSelectors中的年度周次组合、testNativeWeekNumberReference。年度周次仍仅查询到首次日期，直接EventKit对照同样失败；保留原失败断言与产品warnings，没有跳过或改为预期失败。这是用户之前接受、迁移计划明确保留的限制，不宣称全套测试通过，也不推断真机行为。
iOS27首次还发生一个fixture失败：提醒事项用例后，旧夹具从所有sources中盲选Local，创建的事件日历对产品不可见。先改5秒有界可见性等待仍明确失败（002原日志保留），再改为reset后从支持事件的本地来源选取，复跑两平台均恢复上述28/4。未重试create、重排测试、放宽日期断言或修改生产代码。
测试仅使用本任务新建模拟器，按唯一命名创建并清理临时日历/提醒列表，未读取个人设备数据。

## Harness
247份材料复制并校验；245份仍在原相对路径且SHA相同，迁移任务正文因进展更新并移为目录；原任务checkpoint改名initial.checkpoint.json后SHA相同。四项共享技能、六个脚本/测试、67份文档、归档证据和旧本地checkpoint均保留。
42项测试中41通过、1项因macOS文件系统不支持非UTF8文件名按原逻辑跳过；恢复、Spec小节、prepare/check/export、归档隔离等16步CLI验证通过。详见harness-validation.md与相关附件。该报告为独立验证当时的状态，其待办由本轮任务后续验收补齐，不改写原报告。
真实Pi首轮已完成（nonblocking），R1参数拒绝遗漏已修正并完成两平台34项测试，R2沿用旧品牌规则不改；第二轮已完成（nonblocking），主Agent逐项核实后接受迁移，见reviews/002/resolution.md。审查原文和resolution分别保留，不将Pi结论直接等同于验收。

## 两项旧Bug与验证边界
详见upstream-bug-comparison.md和原样提取的Swift探针/日志。v1.13存在基础处理，但未完整覆盖旧补丁：fallback提示插入后未同步提交边界；数学fallback仍有转义/text字面量/脚本前空格边界。按批准的路线不重放旧补丁，也不把新发现的独立Bug修复默认为迁移范围。
没有导入真实模型账号或API Key，未运行真实provider聊天、完整旧Bug UI重现、真实iCloud升级/同步、真机或发布签名流程；以上不可由构建和模拟器结果代替。

## 大型原始证据
完整xcresult、工具链和依赖构建材料位于工作树根的 ../../migration-evidence；当前目录保留关键原文日志、摘要和截图。未提交、未推送、未发布。

## 首轮审查修正
CalendarOffload 共用提醒事项 create/update 在授权和对象读取/修改前拒绝真实选项位置的 --recurrence*，两个入口一致；支持的 --recur、地理围栏未改。提醒事项高级重复仍不是本次新增能力。详见 reviews/001/resolution.md。最终重新构建成功（build-r1.log）。

## 最终验收
两轮Pi原报告、固定快照位置及逐项处理已保留。应用/规范代码与第二轮快照逐文件SHA一致，见final-source-integrity.json。原有完整Harness除本次任务正文/检查点的正常进展变化外保持原字节。任务完成并归档；未提交、未推送。
