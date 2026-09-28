import SwiftUI

#if DEBUG
// 用示例状态检查布局与文字/语音切换；此预览不会调用麦克风或语音识别服务。
// 语音布局复用正式 VoiceComposerPanel；这里只模拟录音与发送。

private enum ShortVoicePreviewPhase {
    case text
    case recording
    case reviewing
}

/// 预览容器持有示例草稿；语音布局与正式聊天共用组件。
private struct ShortVoiceComposerPreviewContent: View {
    @Binding var transcript: String
    let phase: ShortVoicePreviewPhase
    let statusNote: String
    let onFinish: () -> Void
    let onRecord: () -> Void
    let onSend: () -> Void
    let onKeyboard: () -> Void
    let onEnterVoice: () -> Void
    let onAuxiliary: (String) -> Void
    var editorFocus: FocusState<Bool>.Binding

    @State private var waveformSource = VoiceWaveformSource(levels: [0.1, 0.3, 0.7, 0.5, 0.9, 0.2, 0.4, 0.6, 0.2, 0.8, 0.4, 0.3])
    @State private var showsSettings = false
    @State private var language = "中文（普通话）"
    @State private var readsReplies = false
    @State private var voiceModel = ShortVoicePreviewModelSelection()
    @State private var showsModelPicker = false
    @State private var settingsDetent: PresentationDetent = .medium
    @ScaledMetric(relativeTo: .body) private var textSize = VoiceComposerStyle.textSize
    @ScaledMetric(relativeTo: .body) private var textMinHeight = VoiceComposerStyle.textMinHeight
    @ScaledMetric(relativeTo: .body) private var textMaxHeight = VoiceComposerStyle.textMaxHeight

    @ScaledMetric(relativeTo: .caption) private var statusMinHeight = VoiceComposerStyle.statusMinHeight

    private var isRecording: Bool { phase == .recording }

    private var statusText: String {
        switch phase {
        case .recording: "正在录音并识别 · 可继续说话"
        case .reviewing: "录音已结束 · 点文字可编辑"
        case .text: statusNote
        }
    }

    var body: some View {
        Group {
            if phase == .text {
                textComposer
            } else {
                VoiceComposerPanel(
                    transcript: transcript,
                    phase: phase == .recording ? .recording : .idle,
                    title: isRecording ? "正在录音" : "语音输入",
                    statusText: statusText,
                    languageLabel: language == "英语" ? "英语" : "中文",
                    waveformSource: waveformSource,
                    drawsSurface: false,
                    onStop: onFinish, onRecord: onRecord, onKeyboard: onKeyboard,
                    onSettings: { showsSettings = true }
                ) {
                    Button(action: onSend) {
                        VoiceComposerSendLabel(isEnabled: !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("发送示例草稿")
                    .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .modifier(ComposerContentTransition(isVoice: phase != .text))
        .modifier(ComposerSurface(voiceStyle: phase != .text))
        .sheet(isPresented: $showsSettings) { settingsSheet }
    }

    private var textComposer: some View {
        VStack(spacing: VoiceComposerStyle.sectionSpacing) {
            TextEditor(text: $transcript)
                .font(.system(size: textSize))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 56, maxHeight: textMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .focused(editorFocus)
                .accessibilityLabel("消息草稿")
            textControls
            if !statusNote.isEmpty {
                Text(statusNote).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: statusMinHeight)
            }
        }
        .padding(VoiceComposerStyle.contentPadding)
    }

    // 对齐 AIChatView.inputBottomControls 的顺序，复用正式的上下文用量组件。
    // 附件和命令仅展示入口，不访问相册、文件或真实会话。
    private var textControls: some View {
        HStack(spacing: 8) {
            textToolbarButton("添加附件", symbol: "plus") { onAuxiliary("附件入口") }
            Button { onAuxiliary("快捷命令入口") } label: {
                Text("/").font(.system(size: 18, weight: .semibold, design: .rounded)).italic()
                    .frame(width: 34, height: 34)
                    .background(ChatColors.inputIconBg, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).accessibilityLabel("快捷命令")
            Spacer(minLength: 0)
            ContextUsageIndicator(percentage: 2, fraction: 0.02) { onAuxiliary("上下文用量入口") }
            textToolbarButton("开始语音输入", symbol: "mic", action: onEnterVoice)
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? ChatColors.sendButtonDisabled : ChatColors.sendButton)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("发送示例草稿")
        }
        .foregroundStyle(ChatColors.secondaryText)
    }

    private func textToolbarButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 34)
                .background(ChatColors.inputIconBg, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func roundButton(
        _ label: String, symbol: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: VoiceComposerStyle.iconSize, weight: .medium))
                .frame(width: VoiceComposerStyle.buttonSize, height: VoiceComposerStyle.buttonSize)
                .foregroundStyle(prominent ? Color(uiColor: .systemBackground) : Color.primary)
                .background(prominent ? Color.primary : Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("识别语言", selection: $language) {
                        Text("中文（普通话）").tag("中文（普通话）")
                        Text("英语").tag("英语")
                    }
                    Button {
                        settingsDetent = .large
                        showsModelPicker = true
                    } label: {
                        HStack {
                            LabeledContent("语音输入模型", value: voiceModel.name)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("voicePreview.modelPicker")
                } footer: {
                    Text("选择用于把语音转成文字的模型。")
                }
                Toggle("朗读回复", isOn: $readsReplies)
            }
            .navigationDestination(isPresented: $showsModelPicker) {
                ShortVoicePreviewModelPicker(selection: $voiceModel)
            }
            .navigationTitle("语音设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !showsModelPicker {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showsSettings = false }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $settingsDetent)
    }
}

/// 预览中的选择只保存在这一份状态，不写入 VoiceSelectionStore。
private struct ShortVoicePreviewModelSelection {
    var entryID: String?
    var groupID: String? = "voice-preview-group"
    var name = "语音输入"
}

private struct ShortVoicePreviewModelPicker: View {
    @Binding var selection: ShortVoicePreviewModelSelection
    @StateObject private var store: ProviderConfigStore

    init(selection: Binding<ShortVoicePreviewModelSelection>) {
        _selection = selection
        let group = ModelGroup(id: "voice-preview-group", name: "语音输入",
                               memberEntryIds: [ModelEntry.systemASROnline.id, ModelEntry.systemASROffline.id])
        _store = StateObject(wrappedValue: ProviderConfigStore(previewConfig: ProviderConfig(
            instances: [], modelEntries: [], modelGroups: [group],
            defaultPrimaryGroupId: nil, defaultSubGroupId: nil, sessionBindings: [:],
            voiceInputGroupId: group.id)))
    }

    private var config: ModelPickerConfig {
        ModelPickerConfig(
            title: "Voice Input",
            explicitPreferModality: [.audioInput],
            groupScope: .single("voice-preview-group"),
            headerNote: "界面预览：选择仅用于本次演示，编辑分组、新建分组和模型测试暂不执行。",
            showCreateGroup: true,
            allowsManagementAndTesting: false,
            currentEntryId: { selection.entryID },
            currentGroupId: { selection.groupID },
            onSelect: { entry in
                selection = ShortVoicePreviewModelSelection(entryID: entry.id, groupID: nil,
                                                           name: entry.model.displayName)
            },
            onSelectGroup: { group in
                selection = ShortVoicePreviewModelSelection(entryID: nil, groupID: group.id, name: group.name)
            }
        )
    }

    var body: some View {
        // 与当前 App 共用同一个模型选择页面；仅数据和选择回调替换为本地样本。
        UnifiedModelPicker(config: config, store: store)
    }
}

// MARK: - 示例状态与 Canvas 入口

private enum ShortVoicePreviewSamples {
    static let partial = "那我今天下午出门需要带伞吗？帮我看一下三点到五点"
    static let complete = "那我今天下午出门需要带伞吗？帮我看一下三点到五点的天气。"
}

/// 只管理预览草稿。开始录音前保存前缀，停止和返回键盘都保留已经显示的文字。
private struct ShortVoicePreviewDraft {
    var text: String
    var phase: ShortVoicePreviewPhase
    private(set) var beforeRecording = ""
    private(set) var takeID = UUID()

    mutating func startRecording() {
        beforeRecording = text
        takeID = UUID()
        phase = .recording
    }

    mutating func receive(_ partial: String, for id: UUID) {
        guard phase == .recording, takeID == id else { return }
        text = beforeRecording + partial
    }

    mutating func finish() {
        // 结束只接受已经展示的文字，不把未说完的样本强行补全。
        phase = .reviewing
    }

    mutating func useKeyboard() { phase = .text }

    mutating func send() {
        text = ""
        phase = .text
    }
}

private struct ShortVoicePreviewSession: View {
    @State private var draft: ShortVoicePreviewDraft
    @State private var resultNote = ""
    @FocusState private var editorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let slowMotion: Bool

    private var modeAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: VoiceComposerStyle.transitionDuration
            * (slowMotion ? VoiceComposerStyle.slowMotionMultiplier : 1))
    }

    // phase/text 是每张预览的一次性种子，后续编辑完全由当前会话持有。
    init(phase: ShortVoicePreviewPhase, text: String? = nil, slowMotion: Bool = false) {
        self.slowMotion = slowMotion
        var initial = ShortVoicePreviewDraft(
            text: text ?? (phase == .reviewing ? ShortVoicePreviewSamples.complete : ""), phase: phase)
        if phase == .recording { initial.startRecording() }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 8) {
            ShortVoiceComposerPreviewContent(
                transcript: $draft.text, phase: draft.phase, statusNote: resultNote,
                onFinish: {
                    draft.finish()
                    resultNote = ""
                },
                onRecord: {
                    editorFocused = false
                    draft.startRecording()
                    resultNote = ""
                },
                onSend: {
                    editorFocused = false
                    draft.send()
                    resultNote = "已模拟发送，未写入真实会话"
                },
                onKeyboard: {
                    draft.useKeyboard()
                    editorFocused = true
                    resultNote = "草稿已保留，可直接修改"
                },
                onEnterVoice: {
                    editorFocused = false
                    draft.startRecording()
                    resultNote = ""
                },
                onAuxiliary: { resultNote = "\($0)：沿用现有功能，此预览不执行" },
                editorFocus: $editorFocused
            )
        }
        // 仅随输入模式切换动画；编辑器身份保持不变，逐字文字更新不触发布局动效。
        .animation(modeAnimation, value: draft.phase)
        .onChange(of: editorFocused) { _, focused in
            // 点击语音草稿也能直接编辑，并恢复文字工具栏。
            if focused { draft.useKeyboard() }
        }
        .task(id: draft.phase == .recording ? draft.takeID : nil) {
            guard draft.phase == .recording else { return }
            let id = draft.takeID
            let sample = draft.beforeRecording.isEmpty
                ? ShortVoicePreviewSamples.complete : "也帮我看看明天的天气。"
            // 点击立即进入录音态；本轮无触觉反馈，也不为动效或反馈推迟开始。
            // 可取消的示例播放；不访问麦克风，快速切换也不会写回旧录音。
            for count in 1...sample.count {
                do { try await Task.sleep(for: .milliseconds(110)) }
                catch { return }
                guard !Task.isCancelled else { return }
                draft.receive(String(sample.prefix(count)), for: id)
            }
        }
    }
}

private struct ShortVoicePreviewComparison: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("录音与文字同屏").font(.headline)
                    ShortVoicePreviewSession(phase: .recording)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("结束后原位检查").font(.headline)
                    ShortVoicePreviewSession(phase: .reviewing)
                }
            }
            .padding(VoiceComposerStyle.pageInset)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct ShortVoicePreviewChat: View {
    @State private var slowMotion = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("MinisX", systemImage: "sparkles").font(.headline)
                    Text("上海当前天气").font(.headline)
                    Text("天气：下雨\n气温 25.1°C，体感 27.3°C\n湿度 90%，能见度 12.4 km")
                    Text("潮湿、正在下雨，出门带伞。")
                    Text("点底部麦克风开始 → 点方块结束 → 点文字编辑")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Toggle("慢放切换动画", isOn: $slowMotion)
                        .font(.subheadline)
                    Text("预览控制 · 录音和发送均为模拟")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("上海今日天气与带伞建议")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ShortVoicePreviewSession(phase: .text, text: "那我今天下午出门需要带伞吗？", slowMotion: slowMotion)
                    .padding(.horizontal, VoiceComposerStyle.pageInset)
                    .padding(.bottom, 8)
                    .background(Color(uiColor: .systemBackground))
            }
        }
    }
}

#Preview("01 · 文字与语音完整交互") {
    ShortVoicePreviewChat()
}

#Preview("02 · 录音与检查对照") {
    ShortVoicePreviewComparison()
}

#Preview("04 · 语音模型入口") {
    ShortVoicePreviewSettingsDemo()
        .environment(\.locale, Locale(identifier: "zh-Hans"))
}

private struct ShortVoicePreviewSettingsDemo: View {
    @State private var selection = ShortVoicePreviewModelSelection()

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ShortVoicePreviewModelPicker(selection: $selection)
                } label: {
                    LabeledContent("语音输入模型", value: selection.name)
                }
            }
            .navigationTitle("语音设置")
        }
    }
}

#Preview("03 · 深色对照") {
    ShortVoicePreviewComparison().preferredColorScheme(.dark)
}
#endif
