//
//  AIChatView+QuickActions.swift
//  Minis - 聊天页（AIChatView）
//
//  主屏幕 Quick Actions（相机、workflow 交接）：匹配本页、通知 workflow 聊天已就绪、执行动作。
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
    // MARK: - Home Screen Quick Actions

    /// Stable id this view represents in the navigation stack. For
    /// draft sessions (`__new__…`) this is the draftId; for opened
    /// sessions it's the real sessionId. `vm.sessionId` cannot be used
    /// because it stays nil for drafts until the first message is sent,
    /// which is too late for the workflow handoff.
    private var quickActionMatchId: String? { sessionId ?? draftId }

    var quickActionObserver: QuickActionObserverModifier {
        QuickActionObserverModifier(
            sessionId: quickActionMatchId,
            isVisible: isChatViewVisible,
            onWaitingMatch: { tryMarkWorkflowChatReady(reason: "modifier-waiting") },
            onChatReady: { action in applyQuickAction(action) }
        )
    }

    /// Tell the workflow this view is alive + showing the right
    /// session, so it can promote `waitingForChatMount → chatReady`.
    /// Idempotent: workflow ignores the call unless its target id
    /// matches and the state is `waitingForChatMount`.
    func tryMarkWorkflowChatReady(reason: String) {
        guard let sid = quickActionMatchId, isChatViewVisible else { return }
        if case .waitingForChatMount(_, let target) = QuickActionWorkflow.shared.state, target == sid {
            minisLogger.info("[QuickAction] tryMarkWorkflowChatReady reason=\(reason) sid=\(sid)")
            QuickActionWorkflow.shared.markChatReady(sessionId: sid)
        }
    }

    /// Apply a one-shot launch action delivered by the workflow's
    /// `chatReady` state. Flips the relevant @State so SwiftUI mounts
    /// the camera sheet / starts speech recognition.
    private func applyQuickAction(_ action: ChatLaunchAction) {
        minisLogger.info("[QuickAction] applyQuickAction action=\(String(describing: action)) showCamera=\(showCamera) hasOverlay=\(hasOverlayPresented) chatVisible=\(isChatViewVisible)")
        // Guard against late deliveries to a view that already
        // disappeared — workflow re-publishes chatReady on retry and
        // the modifier's onReceive can fire after our onDisappear set
        // isChatViewVisible=false. In that case let the workflow's
        // retry timer re-publish so the next live view picks it up.
        guard isChatViewVisible else {
            minisLogger.info("[QuickAction] applyQuickAction skipped — view not visible")
            return
        }
        switch action {
        case .startVoice:
            beginVoiceInput()
            // No cover for voice — close the workflow loop immediately
            // so the retry timer doesn't fire and re-trigger the mic.
            QuickActionWorkflow.shared.markCoverPresented()
        case .openCamera:
            // Drop the keyboard so the system camera UI animates in
            // without fighting the input bar for the screen. The
            // workflow guarantees we're only invoked when the view is
            // visible + the cover binding is attached, so no runloop
            // hop is needed.
            inputFocused = false
            showCamera = true
            minisLogger.info("[QuickAction] openCamera — showCamera=true")
        }
    }
}
