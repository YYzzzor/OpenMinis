//
//  AIChatView+ComposerControls.swift
//  Minis - 聊天页（AIChatView）
//
//  输入区按钮与行：附件 "+"、斜杠、朗读、语言、麦克风、发送、输入框 / 波形、iPad 拖拽高度。含 MinisX 的语音草稿入口（beginVoiceInput、returnToKeyboard）。
//
//  AIChatView 文件地图见 AIChatView/AIChatView.swift。
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

extension AIChatView {
    /// Attachment "+" button.
    /// iOS 16's Menu has a vertical alignment bug inside HStack that causes it
    /// to sit higher than sibling buttons when the keyboard is up.
    /// Use confirmationDialog on iOS 16, Menu on iOS 17+.
    @ViewBuilder
    private var attachmentMenuButton: some View {
        // [T-ios-voiceover-labels] Labelled on the shared `icon` so both the
        // iOS 17 Menu branch and the iOS 16 confirmationDialog branch below
        // announce the same thing; otherwise VoiceOver reads "plus".
        let icon = Image(systemName: "plus")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(ChatColors.secondaryText)
            .frame(width: 34, height: 34)
            .accessibilityLabel(Text("Add attachment", comment: "VoiceOver label for the attachment button"))
            .background(ChatColors.inputIconBg)
            .clipShape(Circle())
            .overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))

        if #available(iOS 17, *) {
            Menu {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                Button { showPhotoPicker = true } label: { Label("Choose Photos & Videos", systemImage: "photo.on.rectangle") }
                Button { showDocumentPicker = true } label: { Label("Add File", systemImage: "doc") }
            } label: {
                icon
            }
        } else {
            Button { showAttachmentMenu = true } label: {
                icon
            }
            .confirmationDialog("Add Attachment", isPresented: $showAttachmentMenu) {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                Button { showPhotoPicker = true } label: { Label("Choose Photos & Videos", systemImage: "photo.on.rectangle") }
                Button { showDocumentPicker = true } label: { Label("Add File", systemImage: "doc") }
            }
        }
    }

    /// Bottom toolbar under the text field (+ / edit-exit / mic / send).
    /// Returns AnyView to keep `inputBar`'s generic type compact; SwiftUI
    /// runtime demangle chokes on deep nested types otherwise.
    // 胶囊与麦克风按可见背景边界保持 12pt，与 + 和 / 按钮一致。
    private static let inputControlSpacing: CGFloat = 12

    var inputBottomRow: AnyView {
        AnyView(
            ViewThatFits(in: .horizontal) {
                inputBottomControls(compactAccessory: false)
                inputBottomControls(compactAccessory: true)
            }
        )
    }

    private func inputBottomControls(compactAccessory: Bool) -> some View {
        let usage = vm.currentContextUsage
        return HStack(spacing: Self.inputControlSpacing) {
            attachmentMenuButton
            slashMenuButton
            if vm.editingMessageIndex != nil {
                editExitButton(compact: compactAccessory)
            }
            Spacer(minLength: 0)
            // 空间不足时只收起辅助按钮文字，保留其操作和辅助朗读名称。
            if voiceInputActive, vm.editingMessageIndex == nil {
                readAloudToolbarToggle(compact: compactAccessory)
                Spacer(minLength: 0)
            }
            ContextUsageIndicator(percentage: usage?.percentage, fraction: usage?.fraction) {
                showTokenUsage = true
            }
            micButtonContainer
            sendButton
        }
    }

    /// "Read replies aloud" toggle shown centered in the toolbar during voice
    /// input (TTS on/off). Styled like the other secondary toolbar controls.
    private func readAloudToolbarToggle(compact: Bool) -> some View {
        // Source of truth = vm.speakEnabled (also driven by the floating speaker's
        // tap-cycle / long-press-off), so this toggle reflects those changes too.
        // Three states, in lockstep with the global voice-output capsule:
        //  • disabled  (!isEnabled)        → gray, slashed speaker
        //  • muted     (isEnabled & muted) → accent, slashed speaker
        //  • active    (isEnabled & !muted)→ accent, wave speaker
        let on = voiceOutput.isEnabled
        let muted = voiceOutput.isMuted
        return Button {
            if on && !muted {
                // Active → mute (temporary silence, capsule stays visible).
                voiceOutput.isMuted = true
            } else if on && muted {
                // Muted → fully off (capsule hides).
                vm.speakEnabled = false
                VoiceOutputPreferences.isEnabled = false
            } else {
                // Off → turn on (resume last speed, un-muted).
                voiceOutput.isMuted = false
                vm.speakEnabled = true
                VoiceOutputPreferences.isEnabled = true
            }
        } label: {
            HStack(spacing: 5) {
                // Fixed-width icon slot so the size stays constant when the glyph
                // swaps between wave / slash.
                // [T-ios-voiceover-labels] The glyph only mirrors the on/off
                // state that the accessibilityValue below already announces,
                // and the row carries visible text — so it is pure decoration
                // for VoiceOver and would otherwise be read as
                // "speaker wave 2 fill".
                Image(systemName: (on && !muted) ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                if !compact {
                    Text("Read replies", comment: "Voice TTS toggle (compact)")
                        .font(.subheadline)
                }
            }
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(on ? Color.accentColor.opacity(0.15)
                                  : Color.secondary.opacity(0.10))
            )
            .fixedSize()
        }
        .buttonStyle(.plain)
        // [T-ios-voiceover-labels] State goes in the VALUE, not the label:
        // folding "on"/"off" into the label would lose VoiceOver's own
        // "on/off" semantics and make the control's name change as it toggles.
        // Muted is a third state the glyph distinguishes visually, so it is
        // announced too rather than being flattened into "on".
        .accessibilityValue(Text(
            on ? (muted
                    ? AppLocalized("On, muted", comment: "VoiceOver value for the read-replies toggle when enabled but muted")
                    : AppLocalized("On", comment: "VoiceOver value for the read-replies toggle when enabled"))
               : AppLocalized("Off", comment: "VoiceOver value for the read-replies toggle when disabled")
        ))
        .accessibilityLabel(Text("Read replies", comment: "Voice TTS toggle (compact)"))
        .accessibilityHint(Text("Toggles reading replies aloud", comment: "VoiceOver hint for the read-replies toggle"))
    }

    /// `/` button that opens the slash command menu.
    private var slashMenuButton: some View {
        Button {
            if vm.showSlashMenu {
                vm.dismissSlashMenu()
            } else {
                vm.showSlashMenuOverInput()
                inputFocused = true
            }
        } label: {
            Text("/")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .italic()
                .foregroundStyle(ChatColors.secondaryText)
                .frame(width: 34, height: 34)
                .background(ChatColors.inputIconBg)
                .clipShape(Circle())
                .overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))
        }
    }

    /// "Exit Edit Mode" capsule shown while editing a past message.
    private func editExitButton(compact: Bool) -> some View {
        Button {
            vm.cancelEdit()
        } label: {
            Group {
                if compact {
                    Image(systemName: "xmark")
                        .frame(width: 14, height: 16)
                } else {
                    Text("Exit Edit Mode", comment: "Cancel message editing")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ChatColors.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ChatColors.inputIconBg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))
            .fixedSize()
        }
        .accessibilityLabel(Text("Exit Edit Mode", comment: "Cancel message editing"))
    }

    /// Speech language badge shown only while recording.
    private var languageBadgeButton: some View {
        Button {
            speechManager.showLanguagePicker = true
        } label: {
            Text(speechManager.languageLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChatColors.secondaryText)
                .frame(width: 34, height: 34)
                .background(ChatColors.inputIconBg)
                .clipShape(Circle())
                .overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))
        }
    }

    /// 普通输入与语音输入共用同一草稿；启动不等待面板动画完成。
    func beginVoiceInput() {
        guard !voiceVM.isBusyForComposer else { return }
        inputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        vm.prepareInputForVoiceMode()
        vm.voiceUsedInComposition = true
        voiceVM.prepare()
        voiceVM.accumulate = true
        voiceVM.setTranscript(vm.inputText)
        withAnimation(voiceTransition) { voiceInputActive = true }
        voiceVM.startFromComposer()
    }

    private func returnToKeyboard() {
        vm.inputText = voiceVM.transcript
        // 离场视图的结束编辑回调会清空共享焦点，必须等它退出后再交接。
        withAnimation(voiceTransition, completionCriteria: .removed) {
            voiceInputActive = false
        } completion: {
            DispatchQueue.main.async {
                guard !voiceInputActive else { return }
                inputFocused = true
            }
        }
    }

    private var micButtonContainer: some View {
        MicButton(inputFocused: $inputFocused, onTap: beginVoiceInput)
    }

    /// Send / Enqueue / Stop circular button.
    ///
    /// [T-ios-voiceover-labels] All three states are icon-only, and two of them
    /// (send / enqueue) use the SAME glyph, so without explicit labels
    /// VoiceOver reads "arrow up circle fill" for both and a blind user cannot
    /// tell what pressing it will do. Each branch therefore names its own
    /// action; the destructive one also carries a hint.
    @ViewBuilder
    var sendButton: some View {
        if vm.isProcessing && canEnqueue {
            Button { performEnqueue() } label: {
                sendArrowIcon(enabled: true)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(Text("Add to queue", comment: "VoiceOver label for the send button while a reply is generating"))
            .accessibilityHint(Text("Queues this message to send after the current reply finishes", comment: "VoiceOver hint for the queue button"))
        } else if vm.isProcessing {
            Button { vm.cancel() } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Stop generating", comment: "VoiceOver label for the stop button"))
            .accessibilityHint(Text("Stops the reply that is being generated", comment: "VoiceOver hint for the stop button"))
        } else {
            Button { performSend() } label: {
                sendArrowIcon(enabled: canSend)
            }
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(Text("Send", comment: "VoiceOver label for the send button"))
        }
    }

    @ViewBuilder
    private func sendArrowIcon(enabled: Bool) -> some View {
        if voiceInputActive {
            VoiceComposerSendLabel(isEnabled: enabled)
        } else {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(enabled ? ChatColors.sendButton : ChatColors.sendButtonDisabled)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    /// Either the multi-line text field or the audio waveform, depending on
    /// whether speech recording is active. Returning `AnyView` erases the
    /// nested `PastableTextView` generic so SwiftUI's runtime type metadata
    /// decoder doesn't recurse past its stack limit (see crash 2026-04-17
    /// where `AIChatView.inputBar.getter` blew the stack via
    /// `__swift_instantiateConcreteTypeFromMangledNameV2`).
    var inputFieldOrWaveform: AnyView {
        let topPadding: CGFloat = (vm.attachments.isEmpty && vm.loadingVideoCount == 0) ? 16 : 11
        if voiceInputActive {
            return AnyView(
                // [voice-correction §6] Recent conversation turns, straight from the
                // already-loaded in-memory list (§12.1 forbids a DB query on this path),
                // budgeted by CorrectionContextBuilder.
                VStack(spacing: 0) {
                    if vm.editingMessageIndex != nil {
                        HStack {
                            Text("正在编辑历史消息").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            editExitButton(compact: false)
                                .disabled(voiceVM.isBusyForComposer)
                        }
                        .padding(.horizontal, VoiceComposerStyle.contentPadding)
                        .padding(.top, 8)
                    }
                    InlineVoiceInputView(
                        viewModel: voiceVM,
                        inputText: inputTextBinding,
                        onKeyboard: returnToKeyboard,
                        sendControl: { AnyView(sendButton) },
                        conversationContext: { voiceCorrectionContext(from: vm.messages) }
                    )
                }
            )
        }
        if speechManager.state == .recording {
            // Transcript area grows with content up to a cap (~5 lines),
            // then scrolls internally. ScrollView is greedy in its scroll
            // axis, so we measure the Text's intrinsic height via a
            // GeometryReader preference and clamp the ScrollView frame to
            // min(measured, cap).
            let transcriptMaxHeight: CGFloat = 100
            let waveform = VStack(spacing: 6) {
                AudioWaveformView(levels: speechManager.audioLevels)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                if !speechManager.recognizedText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(speechManager.recognizedText)
                                .font(.subheadline)
                                .foregroundStyle(ChatColors.secondaryText)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .background(GeometryReader { geo in
                                    Color.clear.preference(key: TranscriptHeightKey.self, value: geo.size.height)
                                })
                                .id("transcriptTail")
                        }
                        .frame(height: min(max(transcriptHeight, 22), transcriptMaxHeight))
                        .onPreferenceChange(TranscriptHeightKey.self) { transcriptHeight = $0 }
                        .onReceive(speechManager.$recognizedText) { _ in
                            withAnimation(.linear(duration: 0.1)) {
                                proxy.scrollTo("transcriptTail", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, topPadding)
            .padding(.bottom, 10)
            return AnyView(waveform)
        }
        let field = PastableTextView(
            text: inputTextBinding,
            isFocused: $inputFocused,
            hasSelection: $inputHasSelection,
            isScrollable: $inputIsScrollable,
            isAtScrollBottom: $inputAtScrollBottom,
            // `String(localized:)` with an interpolation extracts the
            // `%@` form ("Message %@ (@ to mention files)") as the lookup
            // key in Localizable.xcstrings, so translators get one
            // parameterized entry per locale instead of one per soul name.
            placeholder: AppLocalized("Message \(soulName) (@ to mention files)"),
            onPasteImage: { image in vm.addImageAttachment(image) },
            onPasteFile: { url in vm.addFileAttachment(from: url) },
            onReturnKey: handleReturnKey,
            onArrowUp: handleArrowUp,
            onArrowDown: handleArrowDown,
            onTab: handleTabKey,
            onCaretChange: handleCaretChange,
            onSelectionReplace: { before, after in
                // [T-text-input-correction-source] Feed composer select-and-
                // replace edits into the SAME correction learner as voice
                // transcript fixes, tagged source=text_input. Fire-and-forget
                // off the keystroke path (design §12.2). The recorder applies
                // the phonetic-admission + consent gate, so a plain reword is
                // dropped and nothing is stored without opt-in. locale "zh" is
                // the only phonetic normalizer currently active; the composer
                // has no ASR language context, and a non-normalizable locale
                // would just be discarded downstream.
                Task.detached(priority: .utility) {
                    await VoiceCorrectionRecorder.shared.recordEdit(
                        before: before, after: after,
                        locale: "zh", source: "text_input")
                }
            },
            desiredCaret: vm.pendingCaret,
            // [T-ipad-composer-resize] Raise the text view's growth cap in
            // lockstep with the dragged frame, otherwise text would scroll at
            // 120pt inside a taller box and the extra space would be dead.
            maxHeightOverride: composerTextHeight
        )
        return AnyView(composerBody(field: field, topPadding: topPadding))
    }

    /// [T-ipad-composer-resize] Wraps the text field with its (optional) fixed
    /// height and the iPad drag handle.
    ///
    /// `.fixedSize(vertical:)` and an explicit `.frame(height:)` are mutually
    /// exclusive: fixedSize asks the view for its intrinsic height, which is
    /// exactly what we're overriding once the user has resized. So the two
    /// modes are separate branches rather than modifiers stacked on one view.
    private func composerBody(field: PastableTextView, topPadding: CGFloat) -> some View {
        Group {
            if let height = composerTextHeight {
                field.frame(height: height)
            } else {
                field.fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: ChatInputTypography.minimumTextHeight, alignment: .top)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
        .padding(.bottom, 10)
        .overlay(alignment: .top) {
            if composerResizeEnabled { composerResizeHandle }
        }
    }

    /// The grab affordance. Dragging UP makes the composer taller, so the drag
    /// translation is negated. Double-tapping toggles between the two extremes.
    private var composerResizeHandle: some View {
        Capsule()
            .fill(ChatColors.secondaryText.opacity(0.35))
            .frame(width: 36, height: 5)
            .padding(.top, 4)
            .contentShape(Rectangle().inset(by: -12))  // enlarge the hit area
            // Order matters: the double-tap must be registered BEFORE the drag,
            // otherwise the drag (minimumDistance 2) claims the touch sequence
            // first and the second tap never forms.
            .onTapGesture(count: 2) { toggleComposerHeight() }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in composerDragOffset = -value.translation.height }
                    .onEnded { value in
                        let resolved = min(
                            max(currentComposerHeight - value.translation.height,
                                Self.composerDefaultHeight),
                            composerMaxHeight)
                        composerDragOffset = 0
                        persistComposerHeight(resolved)
                    }
            )
            .accessibilityLabel(AppLocalized("Resize input box"))
            .accessibilityHint(AppLocalized("Drag to resize, double tap to toggle"))
    }

    /// Double-tap: jump between the 50% cap and the default height. Anything
    /// short of the cap counts as "not expanded" and expands, so a partially
    /// dragged composer grows rather than collapsing unexpectedly.
    private func toggleComposerHeight() {
        let isExpanded = currentComposerHeight >= composerMaxHeight - 0.5
        withAnimation(.easeOut(duration: 0.2)) {
            persistComposerHeight(isExpanded ? Self.composerDefaultHeight : composerMaxHeight)
        }
    }

    /// Store a resolved composer height as a screen fraction. Collapsing to the
    /// default clears the preference entirely, so the composer returns to
    /// content-driven sizing rather than being pinned at the default.
    private func persistComposerHeight(_ height: CGFloat) {
        composerHeightFraction = height <= Self.composerDefaultHeight + 0.5
            ? 0
            : height / UIScreen.main.bounds.height
    }

    /// The composer's height right now, used as the drag's starting point.
    private var currentComposerHeight: CGFloat {
        composerHeightFraction > 0
            ? min(max(UIScreen.main.bounds.height * composerHeightFraction,
                      Self.composerDefaultHeight), composerMaxHeight)
            : Self.composerDefaultHeight
    }
}
