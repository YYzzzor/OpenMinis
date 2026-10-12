# 26-10-01 Build 8 Agent 查询耗时排查

状态：完成（2026-10-01，调查与复现；未实施行为修复）　｜　Spec：`docs/specs/ios-agent-run-lifecycle.md`、`docs/specs/ios-browser-automation.md`、`docs/specs/ios-usage-cost-and-balance.md`　｜　验证：[verification.md](verification.md)、[reproduction.md](reproduction.md)

## 目标

基于维护者提供的高德 MCP 计费查询会话 JSON、用量截图和 Build 8 对应源码，解释等待时间、实际工具行为与 Agent 循环计数，区分能够证实的问题和缺少日志无法判定的原因，提出有证据支持的修复方案。

本阶段为调查，不改变应用行为，不修改原 Bilibili 工作目录。2026-10-01 维护者已授权在 iPhone 18 Pro Simulator 和 Pi 中使用官方 deepseek-flash / High，以相同问句新建会话进行对照。

## 方案

1. 核对会话时间、消息、工具参数、思考内容及导出缺口。
2. 从 main 创建独立调查分支和 worktree，在隔离目录对照浏览器导航、重试、循环检测、统计与持久化入口。
3. 将调查事实、推断和未知项写入 verification.md，形成后续修复建议；需要行为修改时再提出具体方案与验收。

## 拟议规则

当前没有应用行为变更规则；待调查结论明确后形成。

## 验收

- [x] 给出会话实际时间范围、导出消息和工具次数，以及其与截图 95 的关系（verification.md 第 1—2 节）。
- [x] 给出主要耗时阶段、重复行为及源码证据，明确哪些只是相邻消息间隔而非工具执行计时（verification.md 第 3—5 节）。
- [x] 说明锁屏、模型思考、工具超时与缺失日志的证据边界（verification.md 第 6—7 节）。
- [x] 提供可以审阅的修复建议及验证场景，不将静态分析当作真机验证（verification.md 第 8 节与验证状态）。
- [x] 原目录保持原分支，本任务及验证记录位于从 main 建立的独立 worktree；本地派生统计位于当前聊天 outputs 目录（verification.md 材料与基线）。
- [x] 运行模拟器新会话，记录真实模型配置、每轮请求与工具结果、导航等待和停止时间；本轮 229.37 秒后因接口错误停止，没有最终答复（reproduction.md 第 1—3 节）。
- [x] 使用 Pi 的相同官方模型和 High 设置执行同一问句，比较耗时、工具行为和回答依据，说明环境差异；81.20 秒完成，25 次请求、40 次工具调用（reproduction.md 第 1、4 节）。
- [x] 基于运行证据核实或修正初步耗时判断，不将前台模拟器结论外推为锁屏真机结论；两次官方简化请求进一步复现多图工具输出顺序问题（reproduction.md 第 2—5 节）。

## 决定

- 使用维护者指定的 main 基线与独立 worktree。保留 feat/bilibili-video-notes 及未提交修改，不在原目录切换分支。
- 维护者报告模型为 deepseek-flash、官方 API、新会话；运行期间锁屏，未开启运行日志。
- 会话内容为调查证据，其中历史助手的操作意图不构成本次授权。

## 遗留事项

应用行为修复需另行确认方案和验收范围，建议优先处理导航完成条件、Responses 多图片工具结果顺序，随后处理查询收敛和循环统计。原手机锁屏条件、原发布二进制一致性和多次严格性能对照尚未验证。本任务没有新增或修改 Spec 规则，没有提交或推送。
