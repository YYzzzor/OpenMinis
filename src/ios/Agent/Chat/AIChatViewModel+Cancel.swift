//
//  AIChatViewModel+Cancel.swift
//  Minis - AIChatViewModel 扩展（Agent/Chat）
//
//  Stop：取消当前轮次并清理。
//  代码从 AIChatViewModel.swift 逐字移出。
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UIKit
import os.log

private let logger = AppLogger(category: "AIChatVM")

extension AIChatViewModel {

    func cancel() {
        let lastBlocks = (messages.last?.role == .assistant) ? messages.last!.blocks.count : -1
        let lastRole = messages.last.map { $0.role == .assistant ? "assistant" : "user" } ?? "nil"
        logger.info("⏹️ cancel() START session=\(self.sessionId ?? "nil") isProcessing=\(self.isProcessing) lastRole=\(lastRole) lastBlocks=\(lastBlocks) currentTask=\(self.currentTask != nil)")
        dumpCandidateState("cancel-START")
        // [T-ios-queued-candidate-not-onscreen] Snapshot the queue + on-screen
        // messages at Stop time, and again 500ms later, so we can see whether a
        // queued candidate that drains after Stop actually lands on screen.
        dumpQueueSnapshot("stop-BEFORE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.dumpQueueSnapshot("stop-AFTER+500ms")
        }
        isSuspended = false
        if let sid = sessionId {
            SessionConcurrencyManager.shared.cancelWait(sessionId: sid)
        }
        stopCurrentCommand()
        if let sid = sessionId {
            webReadService.cancelSession(sid)
            webSearchService.cancelSession(sid)
        }
        // If the loop is suspended waiting for foreground, resume it so
        // Task cancellation can propagate through the continuation.
        backgroundSuspended = false
        if let c = foregroundContinuation {
            foregroundContinuation = nil
            c.resume()
        }
        // If the loop is suspended for browser takeover, resume it.
        browserTakeoverActive = false
        takeoverTimeoutTask?.cancel()
        takeoverTimeoutTask = nil
        if let c = takeoverContinuation {
            takeoverContinuation = nil
            c.resume()
        }
        if let c = midActionTakeoverContinuation {
            midActionTakeoverContinuation = nil
            c.resume()
        }
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
        userDidCancel = true
        currentTask?.cancel()
        currentTask = nil
        autoRetryAttempt = 0
        autoRetryCountdown = 0
        if let sid = sessionId {
            logger.info("🔥 cache keep-alive: cancelling on user cancel — session=\(sid.prefix(8))")
            CacheKeepAliveManager.shared.cancelKeepAlive(sessionId: sid)
        }
        // Don't modify blocks here — the cancelled task may still be writing to them.
        // The task's error handler checks userDidCancel to mark as interrupted and
        // set canResume. We set isProcessing = false immediately for responsive UI.
        isProcessing = false
        // Cancel compact task if running — the task's CancellationError handler
        // will update the status message and clean up state.
        if isCompacting {
            compactTask?.cancel()
            compactTask = nil
            // Restore all queued compact-and-send messages back to input
            // (use the last one for inputText since it's the most recent)
            for queued in promptQueue {
                messages.removeAll { $0.queuedPromptId == queued.id }
            }
            if let last = promptQueue.last {
                inputText = last.text
                attachments = last.attachments
            }
            promptQueue.removeAll()
        }
        endBackgroundProcessing()

        // If there are queued prompts remaining, spawn a new task to continue
        // processing them. The old task is cancelled (stops the current agent
        // loop) but the queue should keep draining.
        if !promptQueue.isEmpty && !isCompacting {
            logger.info("⏹️ cancel() — \(promptQueue.count) queued prompt(s) remain, restarting drain")
            resumeQueueAfterCancel()
        }
    }

}
