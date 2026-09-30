# 主 Agent 审查处置

原始 Pi 报告与代码快照 8323d6b8acc20a2c4f5f2447a19fa53e2ea4a2e157a2a363bb220cf2740631c2 保持不变。模型为 deepseek/deepseek-flash；报告 nonblocking；导出前 freshness check 通过。该判断不是手机实际验收通过。

## R1：不完整费用隐藏整体合计
处置：保留现有实现。用户要求的是会话累计费用，不是“已知 DeepSeek 请求小计”；任务明确要求不完整用量不能伪装为完整合计。混用未计价 Provider、取消或缺失最终 usage 会留下不完整标记，UI 显示“—”，已知金额仍保存在账本。SessionCostLedgerTests.testInterruptedOrUnsupportedRequestDoesNotBecomeFree 验证此规则，页面脚注明确说明不完整即不可用。这是已记录的保守口径，并非丢失已知金额。未来如要展示部分合计需另定标题和范围，当前不扩展需求。

## R2：缺失缓存字段
处置：不将缺失当零。没有缓存用量就不能选定两种输入单价；按零缓存估算会将未知输入全部以较高单价计算。DeepSeekRequestUsage 的严格校验符合任务要求。补充了 Chat Completions / Responses 两种缺失缓存字段的回归断言，24 项 XCTest 复验通过。没有声称真实服务必定缺字段，只保证缺字段时不伪造费用。

## R3：地址前后空白识别不一致
处置：已修复并复核。AIChatViewModel+Billing 使用 ProviderInstance.effectiveCustomBaseURL，与 AIChatViewModel+ProviderFactory:67 和 LLMProviderFactory:135 的 OpenAI 实例创建使用同一个归一化属性。该属性只去掉前后空白。OpenAIAgentProvider 持有的是工厂已经归一化后的 OpenAIProvider，因此其 usage 解析无需再次改动。严格官方 HTTPS 域名/路径/端口/模型约束保持不变。

修复后主 Agent 针对性复审了上述调用链，24 项逻辑测试及最终 iOS 构建通过。仅此一行生产逻辑及 R2 回归断言在 Pi 快照之后变化；没有再次重复整轮 Pi 审查。原报告适用未改动范围，新增变化由本处置记录和最终 source-sha256.json 绑定，不声称 Pi 审过修复后的字节。

## R4：运行验收证据不足
处置：接受证据边界，不冒充已运行真实应用。逻辑测试覆盖真实 Foundation/SQLite/Combine 生产源码副本；iOS 构建覆盖主应用代码编译与链接。主 Agent 静态复核原胶囊仍展示同一个 TokenUsageSheet、分区顺序、旧会话无账本隐藏费用、ChatStore 新建登记与原生产连接 PRAGMA foreign_keys=ON。测试未调用生产 ChatStore 或完整 SSE 流/UI；真实账户、手机点击和运行资源测量保持未验证。不存在用户授权的特定部署设备，因此不扩大到设备安装或取真实 Key 的网络测试。任务保留 active，待用户实际验收。

## R5：账本随真实请求增长
处置：接受为合理的持久化业务数据。每条已消费请求保存价格快照和唯一 ID，随会话删除级联清理；不会随流式字片段增长，也不后台扫描。累计读取 O(1)。提前清理会失去历史价格归属，当前不新增 TTL/后台清理机制。没有设备性能实测，不能从编译或静态检查推断能耗。

## 审查覆盖补充
Pi 已完整阅读任务和资源规范，但未完整阅读任务列出的流程参考 plan-task / record-formats。主 Agent 本轮已阅读这些流程资料；它们约束计划与记录操作，不引入本功能额外运行合同。官方价格常量/模型别名/峰谷规则由主 Agent 再次核对 2026-09-29 DeepSeek 价格页：https://api-docs.deepseek.com/zh-cn/quick_start/pricing/ 。独立 reviewer 没有联网核验，因此不把这部分称为独立外部事实验证。截止本次交付，无已核实而未处理的范围内代码缺陷；完整产品运行验收仍开放。
