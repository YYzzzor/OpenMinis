# 审查参数同步与原生验收入口

用户要求继续已有 Harness Hooks 任务。当前根 AGENTS.md 规定独立 reviewer 为 gpt-6.1-sol/high/none；本轮仅同步脚本的旧 Astra medium reviewer 门槛、定向测试，以及五份下游现行文档的 reviewer 参数，operations 新增信任/原生验收步骤。编码由 Luna xhigh；不修改产品源码，不修改 trust，不新增可见对话、后台日志、分支、worktree、commit/push。

只读审查固定 snapshot 和 before 文档副本、validation/reviewer-policy.patch、作者日志及manifest，勿修改任何文件。两份脚本原来未跟踪，精确本轮diff由作者提供，不能将全文件当作本轮新增；其他之前的dirty亦不在范围。确认 reviewer 新配置放行、旧配置拒绝与自动纠正、fork none要求、既有 Luna与patch gate未变，识别同步造成的真实缺陷和文档错误。资源规范全文必读；本轮为常量参数同步及小型测试，勿扩展为无关审计。已知主模型文档门槛仍仅识别 Astra，shell等路径未覆盖，代码模式和宿主真实trigger尚未验收；这些历史限制未声称已解决。未修改hooks.json定义。

不要运行完整测试、模型会话或原生Hook触发，作者12项测试日志可静态核对。可以运行最小纯内存行为样本。返回审查覆盖、findings（严重度、明确文件/行与依据）、资源判断、验证与限制。若无新问题明确no_findings，但不可宣称原生Hook已生效。
