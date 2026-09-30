# 独立审阅意见处置

请求：missing-specs-2026-09-30-001。原始报告report.md保持原字节；后续修订身份见../002 章节前提与用量定义修复复审/manifest.json，补丁和静态结果同目录保存。

Reviewer建议：三项中等、两项低等级文档问题需要修订，无阻断/高等级问题。主Agent对照原始源码确认五项均成立并全部接受，不扩展为产品行为修复。

| 编号 | 处置 | 当前修订位置、依据与验证 |
| --- | --- | --- |
| R1（中） | 已修复，002复核确认 | ios-memory-lifecycle.md:52、62明确memoryEnabled门禁和重新启用入口；第52行区分tool_title/content schema与执行函数解析。MemoryTools/ToolDefinitions静态依据成立。专用写入、GLOBAL子节和检索完整抽取均保留门禁与范围。 |
| R2（中） | 已修复，002复核确认 | ios-memory-lifecycle.md:78、场景表，ios-sync-and-conflict-resolution.md:62补30日cutoff、可解析非空标记条目、无标记文本和备份/入站区别。依据buildMemoryDaily/parseMemoryEntries/serialiseMemoryEntries；没有声称接收端也过滤或历史已删除。 |
| R3（中） | 已修复，002复核确认 | ios-usage-cost-and-balance.md:32明确原始总输入、cached和归一化inputTokens；与parse和分项计价一致。第24行同时避免误将完整合法零值排除。未计价仍未知。 |
| R4（低） | 已修复，002复核确认 | 四份新Spec第9行将总体范围、静态核对及无新增运行证据移至文档引言，在其他章节抽取时作为祖先正文保留。未改变description或增设阅读账本。 |
| R5（低） | 已修复，002复核确认 | ios-mcp-integrations.md:61收窄非法值回落保证，明确NaN/Infinity可能在int转换抛出未捕获异常。以resolve_startup_timeout的异常覆盖范围为据，未修改CLI。 |

修复后静态核验：5份outline、9处完整小节含总体范围及来源SHA、默认预算内；index --check通过；12份本轮文档191处本地链接有效；5份再次whitespace核验通过。前一轮7份未变文档的验证仍适用。报告之外的小表述澄清仅涉及原始总输入和完整零值，不创造产品保证。

主Agent验收：002全新独立上下文已确认R1—R5充分解决，主Agent对照用户目标、源码和静态检查接受；有界文档验收完成。MCP、Memory、Skill和费用产品缺口/运行验证不因文档修复关闭。
