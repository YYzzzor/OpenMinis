# 输入模式切换动画局部复审

用户需求：点击麦克风进入语音面板时，旧文字/按钮与新内容不得交叠，保留背景平滑展开、即时请求录音以及回文字的焦点交接。用户已明确指令“修改啊”。

本轮只审查以下局部改动，不重新审查整个语音接入与此前已记录的五项意见；git patch 相对于 main 会包含此前接入代码，不能将其全部当成本轮新增。
1. VoiceComposerPanel.swift 新增 ComposerContentTransition：transaction(value: isVoice) 内 animation=nil、disablesAnimations=true。
2. AIChatView.inputBar 把 inputFieldOrWaveform 与条件 inputBottomRow 合为 VStack(spacing:5)，应用该 modifier。ComposerSurface 仍在外层，保留动画。
3. ShortVoiceComposerPreviewContent 把各自背景移至共享外层，并共用该内容事务边界。
没有修改录音 VM、启动、停止、数据同步。InlineVoiceInputView 和 VoiceInputPanel 仅作为生命周期上下文。请只报告上述变化导致的可证实回归或具体疑点，重点是禁动画事务范围、视图生命周期、回键盘焦点和预览一致性。

主 Agent 验证：git diff --check，通过正式模拟器 Debug 构建；同一 iPhone 18 Pro (479131C9-8187-44E7-8510-A499D7AC3034) 实际前后录像对比。初始方案仍有残影已舍弃，最终 transaction 方案逐帧确认旧文字/工具栏和新语音内容不再交叠，背景持续伸缩；回文字有光标。软件键盘仅有 UI 节点、截图未显示，不声称弹出验收。未新增实现镜像测试。
验证边界：临时拒绝麦克风路径、不采集音频，结束恢复授权。录制帧与用户内容不外发；审核依据源码与此摘要，不能声称你亲自看过录像。真实录音、输入法、深色/动态字体不在本轮已验收范围。此前流式识别改造明确延期，不能扩大本轮修复。

授权：用户已持续授权本项目 Pi 审核到 DeepSeek/deepseek-flash，并在本对话明确催促直接发送。本轮仅发送 5 个直接相关源码和本审核范围文档，无凭据、会话、截图、其他任务或无关资料。
