# 缺失规范与跨文档契约独立审查

请求编号：missing-specs-2026-09-30-001
固定版本：manifest.json的逐文件SHA256；main/272da5d9仅定位，不代表dirty快照。
用户授权：新增缺失Spec并修复相关冲突。本轮只改文档与本任务，产品缺口仅披露，不修复产品。

## 必读与阅读范围

全文必读snapshot下四份新Spec：ios-mcp-integrations.md、ios-usage-cost-and-balance.md、ios-skills-lifecycle.md、ios-memory-lifecycle.md。全文读取七份修改的既有Spec，路径以manifest.changed_documents为准（index也核对）。全文必读AGENTS.md、docs/harness/spec-authoring.md、docs/harness/spec-context.md、docs/specs/resource-efficiency.md及当前task.md。相关其余Spec在快照，仅按修改触及章节补读。current-task-only.patch才是本轮归因基线，不用整份HEAD diff归因。

受控读取14处章节的选择器、SHA与预算见checks/results.json，其输出附checks。检查单独读取是否保留前提例外，允许补读旁支定义。Snapshot保留原文，不能以工具的已展开标签替代实际阅读。

源码仅按上述文档所述符号检查，目录结构位于snapshot/src/ios。特别检查MCP门禁缓存/重试/凭证备份、Skill覆盖及附件完成、Memory关闭/GLOBAL授权/撤销和无delete handler、账本未计价/身份/价格版本/余额。单元测试文件仅是入口，不能视为运行证据；不运行构建、测试、模拟器、真机、联网或任何脚本服务。

## 审查标准与边界

只读固定快照，不读取其他归档任务，不修改任何文件。使用全新gpt-6.1-sol/high会话（根AGENTS优先于旧review-task中的Astra参数）。检视description、场景及可观察验收、状态区分、链接章节依赖、遗漏条件、矛盾和无法支持的现状断言。按用户行为契约审查，不按类型同名覆盖率评价。已明确披露的产品缺陷不要求扩大本轮修复；若文档把缺陷写为保证则是本轮文档问题。对草案/未决不自动升级要求。资源审查：无产品变更不适用性能测量，但检查Spec是否准确描述已有资源边界，切勿新造运行保证。

## 输出

完整返回中文原始报告：请求与快照标识、模型及参数、实际逐文档/章节和源码覆盖、总体结论、资源影响与未验证范围。每项问题编号R1起，严重程度阻断/高/中/低，准确相对文件与行号、触发条件、影响、源码符号与行号证据、建议；区分确定问题和待核实。无问题也明确全文覆盖/未读边界。不要只给评分。报告直接返回主Agent，由主Agent原字节保存并另写处置，reviewer不修改材料。
