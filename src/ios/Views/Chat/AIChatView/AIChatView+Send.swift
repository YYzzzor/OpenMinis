//
//  AIChatView+Send.swift
//  Minis - 聊天页（AIChatView）
//
//  canSend / canEnqueue、入队、发送。
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

private let minisLogger = AppLogger(category: "MinisURL")

extension AIChatView {
    var canSend: Bool {
        let hasText = !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ready = vm.isReady
        // [T-ios-photo-pick-placeholder] Block sending while any picked photo is
        // still loading. Only count `.ready` attachments as sendable content, so
        // a composer holding ONLY failed/loading chips (and no text) can't send.
        let hasReadyAttachment = vm.attachments.contains { $0.loadState == .ready }
        return !voiceVM.isBusyForComposer && ready && !vm.hasLoadingAttachments && (hasText || hasReadyAttachment)
    }

    var canEnqueue: Bool {
        !voiceVM.isBusyForComposer && vm.isProcessing && !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the composer actually holds something worth moving to another
    /// session — non-blank text or at least one attachment. Gates the
    /// "Move to…" pill so it never appears over an empty composer.
    var hasMovableShareContent: Bool {
        !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !vm.attachments.isEmpty
    }


    func performEnqueue() {
        guard !voiceVM.isBusyForComposer else { return }
        // Dismiss the software keyboard on enqueue. With a hardware keyboard,
        // keep focus so the user can continue typing the next candidate.
        if GCKeyboard.coalesced == nil {
            inputFocused = false
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        vm.forceScrollToBottom.send()
        if speechManager.state == .recording {
            speechManager.stopRecording()
        }
        speechManager.recognizedText = ""
        lastRecognizedLength = 0
        vm.enqueuePrompt()
        // [inline-voice] Enqueue consumed the text — clear the voice transcript
        // too, otherwise it lingers in the panel (the "residual after swipe-send"
        // bug). performSend already does this; the enqueue path (taken while the
        // agent is processing) was missing it.
        if voiceInputActive {
            voiceVM.clearAndRearm()
            withAnimation(voiceTransition) { voiceInputActive = false }
        }
    }

    /// Dismiss keyboard (commit dictation/marked text) before sending.
    func performSend() {
        guard !voiceVM.isBusyForComposer else { return }
        // Intercept slash commands — execute instead of sending to LLM
        if vm.tryExecuteInputAsSlashCommand() { return }

        minisLogger.info("🔑DRAFT performSend vm=\(vm.vmInstanceId) vm.sessionId=\(vm.sessionId ?? "nil") draftId=\(draftId ?? "nil") inputText='\(String(vm.inputText.prefix(50)))' isProcessing=\(vm.isProcessing)")
        // Keep SwiftUI focus when a hardware keyboard is connected — dropping
        // it would force the user to tap the field again before typing the
        // next message. With only the software keyboard, clear focus and
        // dismiss it so the @FocusState binding stays in sync.
        let hasHardwareKeyboard = GCKeyboard.coalesced != nil
        if !hasHardwareKeyboard {
            inputFocused = false
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // User actively sending — force scroll-to-bottom so the response scrolls into view
        vm.forceScrollToBottom.send()
        // Stop recording and clear recognized text so it doesn't linger after send
        if speechManager.state == .recording {
            speechManager.stopRecording()
        }
        speechManager.recognizedText = ""
        lastRecognizedLength = 0
        hasInjectedShareContent = false
        // Send FIRST while inputText still holds the recognized text. Clearing the
        // voice transcript here (clearAndRearm) mirrors "" into inputText via the
        // onChange binding, so doing it before send() left send() with empty text
        // → "send() GUARD FAILED" and nothing was sent. send() consumes and clears
        // inputText itself; we re-arm voice listening only AFTER it has run.
        vm.send()
        // 发送完成后回到普通输入；下一次点麦克风才开启新的录音。
        if voiceInputActive {
            voiceVM.clearAndRearm()
            withAnimation(voiceTransition) { voiceInputActive = false }
        }
    }
}
