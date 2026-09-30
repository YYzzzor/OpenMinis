# 001 现有 Spec 条件与现状修复 — 独立复审请求

用户授权：创建项目任务并修复上一轮 S01—S10、H01—H02；缺失 Spec 后续处理。本轮只修改12份现有文档及本任务，不改产品代码/测试/配置、不构建或运行测试/模拟器/真机、不提交或推送。

快照范围由 manifest.json 绑定。changes.patch 是本轮开始时工作区文件到本轮修订的差异，不是 HEAD 全部 Git diff。禁止把快照中的既有代码变更归于本任务。不得读取或改写实际仓库、其他任务或归档。只读快照内选定文档和必要源码；目录外目标的链接可根据 manifest 看范围，不能为了补全链接扫描其他文件。

必读全文：resource-efficiency.md、spec-authoring.md、spec-context.md、AGENTS.md 和10份修改的 Spec。另看operations示例、任务范围、patch和静态结果。相关 iSH/日历/设备能力只作标题、版本及旁支核对。

逐项复核：S01环境变量元数据/值和providers凭证导出恢复依赖；S02snapshotAt与跨类别一致快照；S03未知POST路径进入RPC且不等于认证绕过；S04当前上下文快照、历史token、请求估算与账号余额；S05fetch的browser落点与WKDownload workspace；S06空ASR链System回退与待决定策略；S07voiceCorrections显式导出例外；S08最低iOS26与历史分支；S09现存Spec路由；S10dirty初始化/类别前提与补齐边界；H01精确选择器；H02局部抽取能定位已知例外。

源代码阅读只针对相关符号：BackupExporter类别/凭证/续跑，Importer类别与secrets；DebugServer 203-258；AIChatViewModel recordContextUsage/响应后session token；Billing身份/request账本；VoiceProviderResolver.resolveEntries/resolvedInputCandidates和VoiceInputPanel.resolveInputCandidates/transcribeWithFailover；ChatStore.markDirty；browser encode fetch/ConcurrentTools fetchedFileData；Pbx部署目标。保留静态和运行证据边界，不把未决产品语义升级为承诺，也不因已有已知产品缺陷未修而判本次文档未完成。

要求中文报告：12个编号各自修复是否充分；新引入的确定文档错误（稳定R编号、严重度阻断/高/中/低、文件与行号、触发/影响/源码依据/最小建议）；范围和资源影响；未验证范围；是否有实质未完成项。没有问题也要明确覆盖边界，不宣称产品运行通过。不要写文件；将完整原始报告直接返回主Agent，由主Agent保存报告并记录处置。Pi暂停。无需子Agent。