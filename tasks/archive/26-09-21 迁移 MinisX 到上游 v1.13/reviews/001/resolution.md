# 第一轮 Pi 审查处理

快照：1ba360fa2bbd1f9a9d0888199e0568e03639bce21cb620de31c91c3da287a059；Pi0.85.1 / deepseek-flash。用户已明确授权本次迁移材料发送至DeepSeek；先前自动审批拒绝已由该授权解除。原始报告保持不变。

Pi结论：nonblocking，R1/R2均low。主Agent不直接以该结论验收。

## R1：接受，已修复并验证
实际检查确认apple-reminders入口直接调用calendar_cmd_remind/update_reminder，绕过calendar_offload_handle的高级参数拒绝。这会令不支持的--recurrence参数被忽略。修正共用提醒事项入口的参数验证，避免静默产生错误语义；不扩展高级提醒事项能力，也不改上游正常--recur和地理围栏。已新增 testReminderEntrypointsRejectCalendarRecurrenceWithoutMutation 与 testReminderRecurrenceOptionLikeTextRemainsLiteral，在 iOS26.4/27.0 均通过：六类非法参数走calendar入口与shared直达路径均拒绝，独立store验证无新增且原提醒内容/weekly/count未变；字面标题/备注与正常--recur创建更新通过。两个系统最终各34项30通过、4项原有年度周次限制失败。

## R2：不采纳改动，保持已批准的兼容规则
已核对旧定制提交6cc5ea9的SoulStore.swift第26-28行：原本就是 name.isEmpty || name == "Minis" ? "MinisX" : name。新实现保留同一表达式，符合本任务“默认Minis名称按现有规则显示MinisX”和用户将界面Minis改为MinisX的要求。
没有存储字段能区分用户故意设为Minis与旧默认值；本轮没有新增该信息，也不推测或重写SOUL.md。恰好为Minis的显示被映射是既定品牌规则的边界；其他非空自定义名称及新版自定义头像/图标保持原样。为区分该特殊值而引入新的身份/迁移字段超出此次保持现有品牌规则的范围。

## 审查覆盖补充
Pi称record-formats与review-task技能未提供，但这两个文件实际均在snapshot中；它没有读取它们。第二轮将把它们列为显式必读要求，并提供本轮原始构建/测试日志和身份、品牌、Harness校验摘要，便于核对而非只依赖任务叙述。历史archive正文仍不纳入，归档完整性以主Agent和独立子Agent的字节校验为证据。

## 额外运行证据
首轮快照固定后，专用iOS26.4模拟器终端已用内置回车键执行uname，输出Linux；截图terminal-uname-26.4.png。此前系统输入法/HID回车未完成执行不能算通过，此次为实际命令结果。没有因此修改产品代码。
