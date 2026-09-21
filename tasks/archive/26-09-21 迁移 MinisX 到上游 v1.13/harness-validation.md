# v1.13 迁移：Harness 独立验证

验证范围为复制后的 Harness、任务材料和运行入口。未修改仓库源码、规则、脚本或任务；旧工作目录只读。未创建应用提交、推送或修改全局配置。归档仅做程序化字节校验、位置 JSON 和压缩包成员元数据检查，未读取归档任务正文。

## 结果

- 源清单共 247 个文件、8,587,767 字节；再次核对源目录枚举，没有源清单遗漏。246 个文件 SHA-256 与源清单一致，唯一变化是主 Agent 正在更新的本次迁移任务正文；没有缺失文件。
- 原样保留范围：AGENTS.md 1 份、.agents 5 份、scripts/harness 6 份、docs/harness 67 份、tasks 167 份、.ignore 1 份。原来源的 180 个已跟踪文件在新目录没有被忽略规则意外隐藏。
- 全部 42 项 Harness 测试运行完毕：41 项通过，1 项因本机文件系统拒绝非 UTF-8 文件名而跳过。第一次沙箱运行该项产生 EPERM；获准在正常文件系统权限下重跑后，测试按其既有逻辑正确跳过。没有为获得通过修改任何测试或脚本。
- 单独的临时仓库 CLI 验证通过 16 步：checkpoint/inspect、归档缺少显式选择时拒绝、指定归档的 checkpoint/inspect、prepare、完整性与当前输入检查、Spec 必读/参考小节、伪审查进程调用、export 原文保留、Spec 变化导致过期拒绝、固定快照继续可核验。临时仓库已清理，日志保留。此处明确使用假 Pi，不能算真实模型审查。
- 新工作区的实际 Spec 小节选择成功，输出包含原文 SHA-256、祖先引言和选定完整小节。普通任务发现返回 20 个可见路径，其中归档路径为 0。
- 检查 41 份当前入口/技能/Harness Markdown 的链接；当前规则、技能和 Spec 路径均存在。5 个无法按当前位置解析的相对链接均属于原样保留的历史报告摘录，指向 `proposals/003-spec-context.md`，原文件实际位于 `docs/harness/proposals/003-spec-context.md`。没有为修正历史排版而改写报告。
- 11 个历史 bundle-location 引用原样保留。10 个外部目录含 manifest。旧 `/private/tmp/OpenMinis-build-review-003` 仍存在但只剩 snapshot/patches/requirements；对应任务本地保存的 `reviews/003/bundle.tar.gz` 原字节完整，压缩包共 43 个条目，包含 `review-003/manifest.json`、report.json、status.json。该历史临时目录不足以单独复现，需使用保留压缩包；这不是迁移造成的丢失。
- 本机 Python 为 3.14.7，Pi 入口版本为 0.85.1。`pi --help` 在当前沙箱因需要创建 `~/.pi/agent/trust.json.lock` 被拒，未修改认证或全局设置；实际模型审查由主 Agent 在既有权限流程中运行。

## 留给集成验收的事项

- 当前迁移任务的真实 inspect 正确报告 changed，包含旧 checkpoint 的 branch/head 以及并发实现造成的工作区差异。源工作区 checkpoint 原样保留；应在集成稳定并更新任务后，由主 Agent 为本任务建立新 checkpoint 并确认 inspect match。
- 上述测试及假 Pi 流程证明 Harness 功能与搬迁完整性，不代表本次应用改动已通过真实 Pi 独立审查。真实审查及最终接受/拒绝意见仍由主 Agent 完成。
- 现有历史任务、报告与 checkpoint 保留历史绑定；没有将旧验证改写为 v1.13 的验证证据。

## 证据文件

- `harness-source-manifest.json`：父任务生成的迁移来源清单。
- `harness-preservation.json`：再次进行的内容完整性核验。
- `harness-tests.log`：初次沙箱运行及 EPERM 原始证据。
- `harness-tests-final.log`：最终全套测试，41 通过 / 1 跳过。
- `harness-cli-smoke.json`：独立临时仓库的 16 步 CLI 流程记录，明确标记未调用真实模型。
- `harness-spec-selection.txt`：真实新工作区 Spec 小节读取结果。
- `harness-links.json`：链接存在性检查及历史摘录限制。
- `harness-external-bundles.json`：历史外部 bundle 位置元数据。
- `harness-versioning.json`：原已跟踪文件的忽略规则核查。
