# 审查发送被自动审批拒绝

状态：未发送，Pi 未启动，无审查报告。
用户指令：“先发送审核吧”。
模型目的地：DeepSeek / deepseek-flash。
固定快照：a22c1367135b22fcb42450875b75ed8a2ff3085964a0689910bcaf3cbfc5a7e8
完整 bundle：/Users/huyuanzhao/.codex/.chatgpt-projects/g-p-6aa8f27e863c8191be6cf501db847b1a/review-bundles/20260928-voice-ui-001
发送前 `review.py check --repo` 已通过。

自动审批原文：
> 该命令会把 21 个源码文件和任务记录发送到外部 DeepSeek；用户只授权“发送审核”，未明确授权将这些具体敏感源码发送至该具体目的地。

没有改用其他渠道或接收方绕过。需要用户明确同意将下面列出的相关源码及本任务记录发送到 DeepSeek；不含凭据、用户会话和其他任务。

## 准备发送的文件
- src/ios/Agent/Chat/AIChatViewModel.swift
- src/ios/Agent/Speech/VoiceCorrectionEngine.swift
- src/ios/Agent/Speech/VoiceCorrectionRecorder.swift
- src/ios/Minis.xcodeproj/project.pbxproj
- src/ios/MinisTests/VoiceComposerLifecycleTests.swift
- src/ios/Providers/ModelEntry.swift
- src/ios/Providers/ModelGroupRouter.swift
- src/ios/Providers/ProviderConfigStore.swift
- src/ios/Providers/Voice/VoiceActivityDetector.swift
- src/ios/Providers/Voice/VoiceCorrectionDB.swift
- src/ios/Providers/Voice/VoiceInputModels.swift
- src/ios/Providers/Voice/VoiceOutputPlayer.swift
- src/ios/Providers/Voice/VoiceProvider+System.swift
- src/ios/Providers/Voice/VoiceProviderResolver.swift
- src/ios/Views/Chat/AIChatView.swift
- src/ios/Views/Chat/ChatInputBar.swift
- src/ios/Views/Chat/Voice/InlineVoiceInputView.swift
- src/ios/Views/Chat/Voice/ShortVoiceComposerPreview.swift
- src/ios/Views/Chat/Voice/VoiceComposerPanel.swift
- src/ios/Views/Chat/Voice/VoiceInputPanel.swift
- src/ios/Views/Providers/UnifiedModelPicker.swift
- tasks/active/26-09-28 语音输入 UI 正式接入/task.md
