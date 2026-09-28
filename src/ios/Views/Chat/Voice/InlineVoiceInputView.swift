import SwiftUI
import UIKit

/// 正式录音适配层：共享面板只展示状态，这里连接现有录音、草稿和设置。
struct InlineVoiceInputView: View {
    @ObservedObject var viewModel: VoiceInputViewModel
    @Binding var inputText: String
    var onKeyboard: () -> Void
    var sendControl: () -> AnyView
    var conversationContext: (() -> ConversationContext)?

    @ObservedObject private var voiceSelection = VoiceSelectionStore.shared
    @ObservedObject private var providerStore = ProviderConfigStore.shared
    @ObservedObject private var voiceOutput = VoiceOutputState.shared
    @State private var showsSettings = false
    @State private var showsModelSelector = false
    @State private var settingsDetent: PresentationDetent = .medium
    @State private var wantsKeyboard = false
    @State private var isCorrecting = false
    @State private var correctionTask: Task<Void, Never>?
    @State private var showCollectionConsentPrompt = false

    private var phase: VoiceComposerPhase {
        if viewModel.isStarting || viewModel.isCaptureActive { return .recording }
        if viewModel.isBusyForComposer { return .transcribing }
        return .idle
    }

    private var statusText: String {
        if let error = viewModel.startError { return error }
        if let seconds = viewModel.retryCountdown { return "识别失败，\(seconds) 秒后重试…" }
        if let failure = viewModel.lastFailure { return failure.message }
        if let error = viewModel.transcribeError { return error }
        if viewModel.isStarting { return "正在开启麦克风…" }
        if phase == .recording {
            return viewModel.usesRealtimeRecognition
                ? "实时识别中 · 文字可能修正，可以停顿后继续说话"
                : "分段识别 · 停顿或停止后出字"
        }
        if phase == .transcribing { return "正在整理这次录音的文字，请稍候" }
        return inputText.isEmpty ? "点麦克风开始说话" : "录音已结束 · 点文字可编辑"
    }

    var body: some View {
        VoiceComposerPanel(
            transcript: inputText,
            phase: phase,
            title: viewModel.isStarting ? "正在开启麦克风" : (phase == .recording ? "正在录音" : "语音输入"),
            statusText: statusText,
            languageLabel: VoiceLanguages.option(for: viewModel.language).label,
            waveformSource: viewModel.waveformSource,
            drawsSurface: false,
            canRecord: !isCorrecting,
            onRetry: viewModel.canManualRetry ? { viewModel.manualRetry() } : nil,
            onStop: { viewModel.finishFromComposer() },
            onRecord: startRecording,
            onKeyboard: requestKeyboard,
            onSettings: { showsSettings = true },
            sendControl: sendControl
        )
        .onAppear {
            // 麦克风入口已同步启动；重新挂载不能把正在录音的状态重置为 waiting。
            if !viewModel.isBusyForComposer {
                viewModel.prepare()
                viewModel.setTranscript(inputText)
            }
            viewModel.accumulate = true
        }
        .onChange(of: viewModel.transcript) { _, text in
            if inputText != text { inputText = text }
        }
        .onChange(of: inputText) { _, text in
            if viewModel.transcript != text { viewModel.setTranscript(text) }
        }
        .onChange(of: viewModel.isBusyForComposer) { _, busy in
            if !busy { completeKeyboardRequest() }
        }
        .onChange(of: voiceSelection.inputEntryId) { _, _ in viewModel.refreshInputProvider() }
        .onChange(of: providerStore.configRevision) { _, _ in
            if !viewModel.isBusyForComposer { viewModel.refreshInputProvider() }
        }
        .onDisappear {
            // 离开聊天/转键盘后不让权限请求或旧转录在后台重新启动录音。
            correctionTask?.cancel()
            viewModel.reset(clearTranscript: false)
        }
        .sheet(isPresented: $showsSettings) { settingsSheet }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MinisDebugVoiceMicTap"))) { _ in
            if viewModel.isCaptureActive || viewModel.isStarting { viewModel.finishFromComposer() }
            else if !viewModel.isBusyForComposer { startRecording() }
        }
        #endif
    }

    private func startRecording() {
        guard !viewModel.isBusyForComposer else { return }
        // 分组可能在录音期间被其他页面或同步更新；新一轮重新解析，再追加草稿。
        viewModel.prepare()
        viewModel.setTranscript(inputText)
        viewModel.startFromComposer()
    }

    private func requestKeyboard() {
        wantsKeyboard = true
        if viewModel.isCaptureActive || viewModel.isStarting { viewModel.finishFromComposer() }
        completeKeyboardRequest()
    }

    private func completeKeyboardRequest() {
        guard wantsKeyboard, !viewModel.isBusyForComposer else { return }
        wantsKeyboard = false
        // 直接读取已完成的全文，不依赖 SwiftUI onChange 与卸载之间的派发顺序。
        inputText = viewModel.transcript
        onKeyboard()
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("识别语言", selection: $viewModel.language) {
                        ForEach(VoiceLanguages.options) { option in
                            Text(option.label).tag(option.code)
                        }
                    }
                    Button {
                        settingsDetent = .large
                        showsModelSelector = true
                    } label: {
                        HStack {
                            LabeledContent("语音输入模型", value: VoiceProviderResolver.inputModelLabel(includeInstance: false))
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("voice.modelPicker")
                } footer: {
                    Text(viewModel.inputCapabilityDescription)
                }
                Section {
                    Toggle("朗读回复", isOn: Binding(
                        get: { voiceOutput.isEnabled && !voiceOutput.isMuted },
                        set: { enabled in
                            voiceOutput.isMuted = false
                            voiceOutput.isEnabled = enabled
                        }))
                }
                if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("文字校对") {
                        correctionButton
                    }
                }
            }
            .navigationTitle("语音设置")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsModelSelector) {
                UnifiedModelPicker(config: .voiceInput())
            }
            .toolbar {
                if !showsModelSelector {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showsSettings = false }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $settingsDetent)
    }

    private var correctionButton: some View {
        Button {
            // One-time collection-consent prompt on the very first tap
            // (T-voice-correction-collection-consent). After the user answers
            // once — either way — it never shows again; the correction itself
            // runs regardless of the choice.
            if !VoiceCorrectionCollectionConsent.shared.hasPrompted {
                showCollectionConsentPrompt = true
            } else {
                runManualCorrection()
            }
        } label: {
            HStack {
                Label("用 AI 校对文字", systemImage: "sparkles")
                Spacer()
                if isCorrecting { ProgressView().controlSize(.small) }
            }
            .frame(minHeight: 44)
        }
        .disabled(isCorrecting)
        .accessibilityLabel(Text("Correct transcript with AI", comment: "Voice manual-correction button"))
        .alert(AppLocalized("Improve voice corrections?",
                      comment: "One-time prompt: enable correction data collection"),
               isPresented: $showCollectionConsentPrompt) {
            Button(AppLocalized("Enable", comment: "Enable correction data collection")) {
                VoiceCorrectionCollectionConsent.shared.isEnabled = true
                VoiceCorrectionCollectionConsent.shared.hasPrompted = true
                runManualCorrection()
            }
            Button(AppLocalized("Not Now", comment: "Decline correction data collection"),
                   role: .cancel) {
                VoiceCorrectionCollectionConsent.shared.hasPrompted = true
                runManualCorrection()
            }
        } message: {
            Text("MinisX can store your transcript fixes (original → corrected pairs) and accepted AI corrections in a local on-device database to make future voice corrections smarter. Nothing is uploaded. You can change this or clear the data anytime in Settings → Permissions.",
                 comment: "One-time prompt body: correction data collection")
        }
    }

    /// User tapped the AI-correction button. Run the engine on the current transcript and
    /// apply the result in place. Manual, one-shot: no debounce, no auto pass.
    ///
    /// Applying a real change is ALSO the "accepted" signal for learning — the user asked
    /// for the correction and took it — so it records the acceptance the same way the old
    /// apply-suggestion button did. That is what lets the confusion dictionary grow (the
    /// prior auto-flow left acceptance at zero because it required a second explicit tap on
    /// a menu the user rarely opened).
    private func runManualCorrection() {
        let text = viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !viewModel.isEditingTranscript, !isCorrecting else { return }
        isCorrecting = true
        VoiceLog.log("[VoiceCorrection] manual correction requested transcript=\"\(text.prefix(40))\" len=\(text.count)")

        let context = conversationContext?() ?? .empty
        correctionTask = Task {
            let suggestion = await VoiceCorrectionEngine.shared.correct(
                transcript: text,
                locale: PhoneticNormalizerRegistry.normalizedLocaleKey(viewModel.language),
                context: context,
                trigger: "manual")
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isCorrecting = false
                // Bail if the transcript changed under us (re-recorded / edited / sent while
                // the model was running) — applying to text no longer on screen is wrong.
                guard !viewModel.isBusyForComposer, viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines) == text else {
                    VoiceLog.log("[VoiceCorrection] manual result discarded — transcript changed during run")
                    return
                }
                if suggestion.hasChange {
                    VoiceLog.log("[VoiceCorrection] manual applied: \(suggestion.diffSummary)")
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.setTranscript(suggestion.corrected)
                    }
                    inputText = suggestion.corrected
                    // Taking a requested correction is the acceptance signal (learning).
                    Task.detached(priority: .utility) {
                        await VoiceCorrectionRecorder.shared.recordSuggestionAccepted(
                            original: suggestion.original,
                            corrected: suggestion.corrected,
                            summary: suggestion.diffSummary)
                    }
                } else {
                    let reason = suggestion.rejectedReason ?? "none"
                    VoiceLog.log("[VoiceCorrection] manual: no change (reason=\(reason))")
                    if reason == "llm_timeout" || reason.hasPrefix("llm_error") {
                        // Infrastructure failure (timeout / empty stream / API
                        // error) — the model never actually judged "no fix
                        // needed". Saying "No corrections needed" here disguises
                        // an outage as a semantic verdict (exactly how the
                        // adaptive-thinking token-burn bug stayed hidden).
                        MinisToast.show(AppLocalized("Correction failed, original kept",
                                               comment: "Voice: AI correction call failed (timeout/error); transcript left unchanged"),
                                        systemImage: "exclamationmark.triangle.fill")
                    } else {
                        // Model genuinely found nothing to fix — tell the user so
                        // the tap doesn't read as "nothing happened".
                        MinisToast.show(AppLocalized("No corrections needed",
                                               comment: "Voice: AI found nothing to fix"),
                                        systemImage: "sparkles")
                    }
                }
            }
        }
    }


}
