# 26-09-29 DeepSeek 会话费用与账户余额

状态：完成（2026-09-30）　｜　Spec：`docs/specs/ios-usage-cost-and-balance.md`（任务完成后补写，无 `[拟议]` 规则）

## 目标

点击输入框的上下文胶囊，在“会话 Token 用量”页查看当前会话的 DeepSeek 估算费用和账户余额。其他 OpenAI 兼容模型显示“—”。不显示本轮费用，旧会话不显示费用分区，只用人民币。

## 验收

证据位于 `evidence/`；测试名来自 `logic-tests.log`（24 项全部通过）。

- [x] 点击胶囊进入用量页（模拟器截图 `simulator-2026-09-29/`）
- [x] 顺序：上下文 → Token → 缓存 → 费用与余额 → 速度 → 深度思考 → Agent 循环（模拟器截图与控件）
- [x] Token、缓存按全部已记录请求累计，不用最后一次上下文值（U1；模拟器单请求；`testToolLoopSumsEachRequestOnceAndUsesSavedAmounts`）
- [x] 缓存命中、未命中、输出分别计价；流式只结算一次；多次请求分别累加（P3、L2；10 项计价测试；模拟器精确金额 ¥0.0193496）
- [x] 只显示会话累计估算费用和账户余额，人民币（模拟器截图）
- [x] 其他兼容模型金额显示“—”、不查余额、不显示旧值（D2、B3；`testCacheFailureAndUnsupportedAccountStates`、`testLateResponseCannotOverwriteSwitchedAccount`；仅逻辑测试，界面未实测，用户接受）
- [x] 余额取 `total_balance`，不叠加赠金，不从费用倒扣（B2；`testBalanceSelectsCNYAndUsesTotalBalanceOnly`）
- [x] 余额失败显示“—”和状态，成功显示更新时间（B4；`testCacheFailureAndUnsupportedAccountStates`、`testDismissalCancellationDoesNotPublishLateBalance`）
- [x] 无可靠价格的历史费用显示未知：旧会话隐藏分区，未计价显示“—”（D1、D3；`testLegacySessionsAreNeverEnrolledByReadingOrRequesting`、`testInterruptedOrUnsupportedRequestDoesNotBecomeFree`；旧会话界面未实测，用户接受）
- [x] 只使用当前账号凭据，只接受 CNY，不做汇率换算（B1、B2；`testBalanceRequestUsesOnlyTheOfficialEndpoint`、`testBalanceRejectsMissingDuplicateAndMalformedCNY`）

## 决定

- 只显示会话累计估算费用和余额；默认人民币；旧会话不补算、隐藏费用分区；新建会话才登记本地账本（用户 9/29）。
- 会话中出现一次未计价请求后，费用持续显示“—”，维持现状（用户 9/30）。
- 两处界面行为（切换其他模型、旧会话）以逻辑测试为证据，不做模拟器实测（用户 9/30）。
- ✗ 不显示本轮费用；✗ 不用余额差推算支出；✗ 不做汇率换算。

## 证据与历史

- `evidence/logic-tests.log`、`ios-build.log`、`source-sha256.json`（验证时的 17 个源文件摘要，9/30 核对与当前一致）
- `evidence/simulator-2026-09-29/`：真实新会话请求、账本记录与截图
- `reviews/001 会话计价与余额查询/`：Pi 审查及处置
- 原先的执行边界、设计图和过程记录见提交 `1acd686` 中本文件的旧版本。

## 未覆盖范围

手机实测、真机能耗、各类实网错误场景未验证，不作为本任务的必做项。
