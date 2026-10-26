//
//  AIChatViewModel+PromptQueue.swift
//  Minis - AIChatViewModel 扩展（Agent/Chat）
//
//  排队的提示词：取消后恢复、依次发出、作为新一轮注入。
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

    /// Resume queue processing after the user stopped the current task.
    /// Spawns a fresh Task (not cancelled) so the drain loop can call runAgentLoop().
    func resumeQueueAfterCancel() {
        // Small delay to let the cancelled task's error handler finish cleanup.
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Wait briefly for the previous task to complete cleanup
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            self.handleUserCancelledCleanup()
            self.userDidCancel = false
            // [T-stop-with-queue-render-desync] handleUserCancelledCleanup (run
            // here or by the cancelled task's own catch) set canResume=true —
            // correct for a plain Stop, but this drain immediately continues the
            // conversation with the queued prompt, so the "Interrupted — tap
            // Resume" banner / ⏸ badge must not stay up over a live run. Clearing
            // it also lets the didSet replay any sync reload it deferred.
            self.canResume = false
            self.isProcessing = true
            self.beginBackgroundProcessing()
            logger.info("📨[DRAIN] Resuming queue in new task — \(self.promptQueue.count) prompt(s)")
            await self.drainQueuedPrompts()

            // [T-stop-with-queue-render-desync] A second Stop during this drained
            // run cancels THIS task and may spawn yet another drain task — same
            // handover as send()'s epilogue, so don't clobber its state either.
            guard !Task.isCancelled else {
                logger.info("📨[DRAIN] queue-resume epilogue skipped (task cancelled) session=\(self.sessionId ?? "nil")")
                return
            }

            if let sid = self.sessionId {
                let dbMessages = await ChatStore.shared.loadMessages(sessionId: sid)
                self.lastKnownDbSortOrder = dbMessages.last?.sortOrder ?? self.lastKnownDbSortOrder
                self.lastKnownDbCount = dbMessages.count
                // T-baseline-hash-drift: see send DONE path for why hash
                // must be refreshed alongside count/sortOrder.
                self.lastKnownDbOrderHash = Self.computeOrderHash(of: dbMessages)
            }
            self.isProcessing = false
            self.endBackgroundProcessing()
        }
    }

    /// Drain any queued prompts after an agent loop finishes.
    /// Called from send(), retry(), resume(), and retryFromMessage() before setting isProcessing=false.
    /// Uses a while loop + final yield to catch prompts queued during the last streaming response.
    /// Reentrancy-guarded entry point. Only ONE drain may be active at a time:
    /// a Stop with queued prompts spawns a fresh resume Task whose drain races
    /// the superseded original Task's post-loop drain, and without this guard
    /// both would run the queued turn and double-fire the next request (every
    /// tool call + reply twice). The guard is set/cleared only on @MainActor so
    /// check-and-set is atomic and held across the inner `await runAgentLoop()`.
    /// [T-ios-concurrent-stop-double-request]
    /// `internal` (not `private`) so `compactAndSend` in the +Compaction
    /// extension file can drain through this same path after a compact.
    func drainQueuedPrompts() async {
        guard !self.isDrainingQueue else {
            logger.info("📨[DRAIN] Already draining in another task — skipping duplicate drain")
            return
        }
        self.isDrainingQueue = true
        defer { self.isDrainingQueue = false }
        await drainQueuedPromptsInner()
    }

    /// The actual drain loop. Unguarded so its own tail-recursion for late
    /// arrivals (below) doesn't trip the reentrancy guard — that guard only
    /// gates cross-Task duplicate entry, which all goes through the wrapper.
    private func drainQueuedPromptsInner() async {
        while !self.userDidCancel && !self.promptQueue.isEmpty {
            // If the Task itself is cancelled (e.g. user tapped stop), don't
            // consume queue items — resumeQueueAfterCancel() handles them
            // in a fresh Task.
            guard !Task.isCancelled else {
                logger.info("📨[DRAIN] Task cancelled — leaving \(self.promptQueue.count) prompt(s) in queue")
                break
            }
            let queued = self.promptQueue
            self.promptQueue.removeAll()
            logger.info("📨[DRAIN] Draining \(queued.count) queued prompt(s)")

            let queuedIds = Set(queued.map(\.id))
            for msg in self.messages where msg.isQueued {
                if let pid = msg.queuedPromptId, queuedIds.contains(pid) {
                    // Queue drain: isQueued true -> false. The withdraw button
                    // disappears here, so the bubble's wrap width widens by
                    // ~28pt and any measurement taken while queued is
                    // superseded from this point on.
                    msg.isQueued = false
                }
            }
            self.scrollToBottomSignal.send()

            let sid = self.sessionId ?? "unknown"
            let uploadsDir = Self.minisUploadsDir(for: sid)
            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime]
            let nowStr = isoFmt.string(from: Date())
            try? FileManager.default.createDirectory(at: uploadsDir, withIntermediateDirectories: true)

            var combinedParts: [AgentContentPart] = []
            for prompt in queued {
                if !prompt.attachments.isEmpty {
                    let (attParts, attMetas) = self.processAttachments(prompt.attachments, uploadsDir: uploadsDir, nowStr: nowStr)
                    combinedParts.append(contentsOf: attParts)
                    Self.cleanupAttachmentFiles(prompt.attachments)
                    if let chatMsg = self.messages.first(where: { $0.queuedPromptId == prompt.id }) {
                        chatMsg.attachments = attMetas
                        chatMsg.inputAttachments = []
                        // [T-ios-user-attach-mount-invalidate #182-followup] The
                        // mount above is an in-place +70pt/row content change on
                        // a cell whose item identity does not move; without this
                        // the tile-less height measured moments earlier stays
                        // cached and the bubble truncates (see the Name's doc).
                        NotificationCenter.default.post(name: .minisUserAttachmentsMounted, object: chatMsg.id)
                    }
                }
                if !prompt.text.isEmpty {
                    combinedParts.append(.text(prompt.text))
                }
            }

            let queueAgentMsg = AgentMessage(role: .user, parts: combinedParts)
            let qIdx = self.agentHistory.count
            self.agentHistory.append(queueAgentMsg)
            if let pid = await self.persistAgentMessage(queueAgentMsg), qIdx < self.agentHistory.count {
                self.agentHistory[qIdx].dbMessageId = pid
            }

            do {
                try await self.runAgentLoop()
            } catch is CancellationError {
                logger.info("Agent loop (queued-drain) cancelled")
                self.handleUserCancelledCleanup()
                // Don't consume remaining queue items — resumeQueueAfterCancel()
                // will pick them up in a fresh Task.
                break
            } catch {
                let rawDesc = String(describing: error)
                logger.error("Agent loop (queued-drain) error: \(rawDesc)")
                if self.userDidCancel {
                    self.handleUserCancelledCleanup()
                } else {
                    let displayDesc = Self.friendlyErrorMessage((error as? LocalizedError)?.errorDescription ?? rawDesc)
                    // [T-stream-empty-banner-trace] Diagnostic: log the
                    // messages-tail state when an agent-loop error
                    // surfaces so we can tell whether the placeholder
                    // assistant message survived the failure (bubble
                    // path) or got pruned beforehand (banner path).
                    // Catalyst users have reported the loading
                    // indicator flashing once and the error red banner
                    // appearing at the top of the chat with no
                    // placeholder bubble — that's the "else" branch
                    // below and it shouldn't happen if runAgentLoop's
                    // line 5124 placeholder is still in `messages`.
                    let lastRoleStr = self.messages.last.map { "\($0.role)" } ?? "nil"
                    let lastBlocks = self.messages.last?.blocks.count ?? -1
                    let lastErr = self.messages.last?.error ?? "nil"
                    let tail3 = self.messages.suffix(3).map { "\($0.role)(\($0.blocks.count)blk err=\($0.error ?? "nil"))" }.joined(separator: " > ")
                    AppLogger(category: "StreamError").error("[StreamError] catch displayDesc=\"\(displayDesc.prefix(120))\" msgCount=\(self.messages.count) lastRole=\(lastRoleStr) lastBlocks=\(lastBlocks) lastErr=\(lastErr) tail=\(tail3)")
                    // [T-ios-retry-tool-blocks-invisible / T-stream-empty-banner-trace]
                    // Resolve the streaming assistant by the last ASSISTANT row,
                    // not messages.last. A queued .user message (enqueuePrompt
                    // appends one mid-tool) sits AFTER the candidate, so
                    // messages.last would be that user row — the error then fell
                    // through to the top red banner (vm.errorMessage) instead of
                    // attaching to the assistant bubble. Same root cause as the
                    // Stop-loses-content fix.
                    if let last = self.messages.last(where: { $0.role == .assistant }) {
                        last.error = displayDesc
                        Task { await self.persistErrorInfo(displayDesc) }  // [T-error-persist-ios]
                        AppLogger(category: "StreamError").error("[StreamError] → bubble path (set last.error)")
                    } else {
                        self.reportTurnFailure(displayDesc)   // [T-ios-error-banner-lost]
                        AppLogger(category: "StreamError").error("[StreamError] → banner path (carrier row + vm.errorMessage set)")
                    }
                }
                break
            }
        }

        // Yield once to let any last-moment enqueuePrompt() calls execute
        await Task.yield()
        if !Task.isCancelled && !self.userDidCancel && !self.promptQueue.isEmpty {
            logger.info("📨[DRAIN] Late arrivals after yield: \(self.promptQueue.count)")
            // Recurse on the INNER worker (we already hold the reentrancy guard)
            // so late-arrival handling isn't skipped by our own guard.
            await drainQueuedPromptsInner()
        }
    }

    /// [T-ios-queued-message-continues-prev-turn] Drain any prompts the user
    /// queued mid-run and append them as ONE standalone user turn, then start a
    /// fresh assistant message so the next loop iteration produces a dedicated
    /// response. Called ONLY from the agent loop's finish branch (after the
    /// current turn's tool loop has fully converged to a no-tool-use assistant
    /// reply), so the queued prompt never gets folded into a mid-loop tool_result
    /// (which made the model treat it as in-loop context for the previous turn).
    ///
    /// Returns true if a prompt was injected (caller should `continue` the loop
    /// instead of breaking). `msgIdx` / `committedBlockCount` are advanced to the
    /// new assistant message. The caller must have already persisted the just-
    /// finished assistant reply before calling this.
    func injectQueuedPromptsAsNewTurn(
        msgIdx: inout Int,
        committedBlockCount: inout Int,
        turnUsage: TokenUsage
    ) async -> Bool {
        guard !promptQueue.isEmpty else { return false }
        let queued = promptQueue
        promptQueue.removeAll()
        // Mark corresponding chat messages as no longer queued (remove dashed border + X)
        let queuedIds = Set(queued.map(\.id))
        for msg in messages where msg.isQueued {
            if let pid = msg.queuedPromptId, queuedIds.contains(pid) {
                msg.isQueued = false
            }
        }

        // Build combined parts from all queued prompts (text + attachments)
        let qSid = sessionId ?? "unknown"
        let qUploadsDir = Self.minisUploadsDir(for: qSid)
        let qIsoFormatter = ISO8601DateFormatter()
        qIsoFormatter.formatOptions = [.withInternetDateTime]
        let qNowStr = qIsoFormatter.string(from: Date())
        try? FileManager.default.createDirectory(at: qUploadsDir, withIntermediateDirectories: true)

        var qCombinedParts: [AgentContentPart] = []
        for prompt in queued {
            if !prompt.attachments.isEmpty {
                let (attParts, attMetas) = processAttachments(prompt.attachments, uploadsDir: qUploadsDir, nowStr: qNowStr)
                qCombinedParts.append(contentsOf: attParts)
                Self.cleanupAttachmentFiles(prompt.attachments)
                // Update the corresponding ChatMessage so attachment thumbnails appear in the UI
                if let chatMsg = messages.first(where: { $0.queuedPromptId == prompt.id }) {
                    chatMsg.attachments = attMetas
                    chatMsg.inputAttachments = []
                    // [T-ios-user-attach-mount-invalidate] See the sibling drain site.
                    NotificationCenter.default.post(name: .minisUserAttachmentsMounted, object: chatMsg.id)
                }
            }
            if !prompt.text.isEmpty {
                qCombinedParts.append(.text(prompt.text))
            }
        }

        // Guard: if every queued prompt was empty (no text, no attachments) the
        // combined parts are empty — an empty user message is a 400. Skip.
        guard !qCombinedParts.isEmpty else {
            logger.warning("injectQueuedPromptsAsNewTurn: \(queued.count) queued prompt(s) produced no content, skipping")
            return false
        }

        // [T-ios-queued-message-interrupt-on-toolclose] When we interrupt mid-tool-
        // loop (right after a tool call closes), the agentHistory tail is
        // assistant(tool_use) → user(tool_result). Appending the queued user
        // message directly would make two consecutive .user entries that
        // mergeConsecutiveSameRole folds into one (tool_result + queued text) —
        // exactly the bug where the model reads the queued prompt as in-loop
        // context instead of a new turn (#579). Insert a minimal assistant bridge
        // so the sequence is …user(tool_result) → assistant(interrupted) →
        // user(queued) → assistant(responds). Only needed when the tail is .user;
        // in the no-tool finish-branch the tail is already an assistant reply.
        if agentHistory.last?.role == .user {
            // Text MUST stay byte-identical to RawMessage.internalBridgeText —
            // that constant is how the session-reload path recognizes this row
            // as internal and keeps it out of the visible chat.
            // [T-bridge-message-ui-leak]
            let bridge = AgentMessage(role: .assistant, parts: [.text(RawMessage.internalBridgeText)])
            let bridgeIdx = agentHistory.count
            agentHistory.append(bridge)
            if let pid = await persistAgentMessage(bridge, snapshots: [:]), bridgeIdx < agentHistory.count {
                agentHistory[bridgeIdx].dbMessageId = pid
            }
        }

        let queueMsg = AgentMessage(role: .user, parts: qCombinedParts)
        let queueIdx = agentHistory.count
        agentHistory.append(queueMsg)
        if let pid = await persistAgentMessage(queueMsg, snapshots: [:]), queueIdx < agentHistory.count {
            agentHistory[queueIdx].dbMessageId = pid
        }
        // Cache markdown on the completed assistant message before starting a new one
        if msgIdx < messages.count {
            for i in messages[msgIdx].blocks.indices {
                if case .text = messages[msgIdx].blocks[i].kind, !messages[msgIdx].blocks[i].content.isEmpty {
                    messages[msgIdx].blocks[i].cachedMarkdown = MarkdownContent(prepareMarkdownForRender(messages[msgIdx].blocks[i].content))
                    cacheAttributedString(for: messages[msgIdx].blocks[i])
                }
            }
            // Clear "thinking" indicator + store usage on the just-finished assistant message
            messages[msgIdx].isAwaitingModelResponse = false
            messages[msgIdx].usage = turnUsage
        }
        // Start a new assistant message so the next response appears below the queued user message
        messages.append(ChatMessage(role: .assistant, content: "", blocks: []))
        msgIdx = messages.count - 1
        committedBlockCount = 0
        self.committedBlockCount = 0
        scrollToBottomSignal.send()
        logger.info("Injected \(queued.count) queued prompt(s) as new turn after tool loop, new msgIdx=\(msgIdx)")
        return true
    }

}
