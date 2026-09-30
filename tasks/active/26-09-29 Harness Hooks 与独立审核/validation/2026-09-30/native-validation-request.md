这是用户已授权的 OpenMinis Harness Hooks 原生验收，必须在当前项目目录通过真实工具调用完成。你是项目要求的 gpt-6-luna / xhigh 内部实现代理。本次不保存会话，不创建用户可见对话。

只执行以下验收，不扩展代码修改范围：
1. 查阅 AGENTS.md 与 .codex/hooks.json、scripts/harness/pre_tool_use_policy.py，确认项目规则。不要读取归档任务历史。
2. 通过真实 apply_patch 工具提交一次空补丁（Begin Patch / End Patch），预期项目 PreToolUse Hook 以无法识别补丁目标拒绝。必须记录真实工具反馈，不手工调用策略脚本伪造宿主事件。
3. 先确认 tasks/active/26-09-29 Harness Hooks 与独立审核/validation/2026-09-30/native-hook-probe.md 不存在，然后通过真实 apply_patch 新增该文件（仅内容 native hook probe），再通过真实 apply_patch 删除该文件。预期合规 Luna 允许，最后必须确认文件不存在。禁止使用 shell 写文件替代补丁工具。
4. 如宿主提供支持 model/reasoning_effort/fork_turns 参数的 spawn_agent 工具，使用 review_native_hook_probe、gpt-6-astra、medium、none 触发旧审核参数的真实拒绝；收到项目 Hook 明确拒绝后，自动修正为 gpt-6.1-sol、high、none，helper 仅只读核对 hooks 配置并返回，等待完成。不兼容该参数时明确报告未覆盖，勿猜测参数。如果旧参数意外获准创建代理，立即停止它并报告验收失败。

不要修改信任、全局设置、Hooks 配置、策略源码、产品文件或其他任务记录；不要提交、推送、构建、使用信任绕过参数，也不要另外开展完整审核。验收结束以中文说明每个实际调用、真实反馈、临时文件清理结果及未覆盖范围。失败时报告真实限制，不声称已经通过。
