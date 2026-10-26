//
//  AIChatViewModel+TurnCompletion.swift
//  Minis - AIChatViewModel 扩展（Agent/Chat）
//
//  一轮结束后的收尾：完成触感、失败提示、用户取消后的清理。
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

    func playCompletionHaptic() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// [T-ios-error-banner-lost] Surface a turn failure that has no assistant
    /// bubble to attach to, in a form that SURVIVES leaving the session.
    ///
    /// The five error epilogues all ended with `self.errorMessage = displayDesc`
    /// when `messages` held no assistant row — which happens whenever a request
    /// dies before the first chunk (bad API key, refused connection, provider
    /// 4xx). `errorMessage` is a @Published on this view model, and the view
    /// model is a per-session @StateObject: switching sessions or letting the
    /// scene tear down destroys it, taking the only record of the failure with
    /// it. The user returns to a chat that looks like nothing was ever sent.
    ///
    /// Creating the assistant row here fixes both halves at once. It renders
    /// through the normal inline-error path (`ChatMessageRow` draws
    /// `inlineError` for assistant rows, and Retry hangs off the same row), and
    /// `persistErrorInfo` now writes a carrier row when none exists, so a
    /// reload restores it. This mirrors the shape the context-exhausted branch
    /// in `send()` already uses.
    ///
    /// `errorMessage` is still set as well: it is what drives the top banner for
    /// the current, still-live view, and clearing it is how the user dismisses
    /// that banner. The durable copy is the addition, not a replacement.
    func reportTurnFailure(_ displayDesc: String) {
        errorMessage = displayDesc
        let carrier = ChatMessage(role: .assistant, content: "", blocks: [])
        carrier.error = displayDesc
        messages.append(carrier)
        Task { await self.persistErrorInfo(displayDesc) }
    }

    func handleUserCancelledCleanup() {
        let blockCount = (messages.last?.role == .assistant) ? messages.last!.blocks.count : -1
        let hasContent = (messages.last?.role == .assistant) ? messages.last!.blocks.contains(where: { !$0.content.isEmpty }) : false
        let lastRole = messages.last.map { $0.role == .assistant ? "assistant" : "user" } ?? "nil"
        let historyLastRole = agentHistory.last?.role.rawValue ?? "nil"
        logger.info("⏹️ handleUserCancelledCleanup userDidCancel=\(self.userDidCancel) lastRole=\(lastRole) blocks=\(blockCount) hasContent=\(hasContent) canResume=\(self.canResume) historyLast=\(historyLastRole)")
        dumpCandidateState("cleanup-ENTER")
        if userDidCancel {
            userDidCancel = false
            // [T-ios-retry-tool-blocks-invisible] The candidate (streaming)
            // assistant message is NOT necessarily messages.last. If the user
            // types + sends while tools are running, enqueuePrompt() appends a
            // queued `.user` ChatMessage AFTER the candidate, so `messages.last`
            // is that user row. The old `guard messages.last == .assistant`
            // then bailed out entirely — the candidate's streamed text + tool
            // blocks were never committed to agentHistory and committedBlockCount
            // never advanced, so on Stop the just-generated answer vanished from
            // the list (it only survived in the preview bar, which flatMaps
            // vm.messages live). Resolve the candidate by the last *assistant*
            // row and operate on its index, mirroring the collection view's
            // `subscribeToLastMessage` (which already uses last(where: assistant)).
            guard let candidateIdx = messages.lastIndex(where: { $0.role == .assistant }) else { return }
            let last = messages[candidateIdx]

            // Case 1: Cancel during tool execution — the tool loop already committed
            // blocks and appended tool_result to agentHistory.
            let lastHistoryIsToolResult = agentHistory.last?.role == .user
                && agentHistory.last?.parts.contains(where: { if case .toolResult = $0 { return true }; return false }) == true
            logger.info("⏹️[StopDiag] branch-decision lastHistoryIsToolResult=\(lastHistoryIsToolResult) → \(lastHistoryIsToolResult ? "Case 1 (tool cancel)" : "Case 2 (text/param cancel)")")
            if lastHistoryIsToolResult {
                for block in last.blocks {
                    if let status = block.toolStatus {
                        switch status {
                        case .streaming, .running:
                            block.toolStatus = .cancelled
                        default: break
                        }
                    }
                }

                // [T-ios-stop-candidate-message-lost] Merged rendering accumulates
                // every agentHistory iteration into ONE UI message (messages[msgIdx]).
                // After a tool_result lands, the NEXT iteration can stream fresh text
                // blocks into this same message before the user taps Stop — those
                // blocks live past `committedBlockCount` and have NOT been committed
                // to agentHistory yet (the iteration's commit at the end of the loop
                // never ran). Without this flush, Case 1 returned immediately and that
                // post-tool text was dropped from history; since `committedBlockCount`
                // stayed behind it, a later resume/persist would also trim it from the
                // UI — i.e. the just-generated answer vanished on Stop. Commit the
                // uncommitted tail (text only — the cancelled tool blocks above are not
                // re-issued) so it's both kept on screen and written to history.
                let toolCancelStart = min(committedBlockCount, last.blocks.count)
                logger.info("⏹️[StopDiag] Case1 flush-scan range=[\(toolCancelStart)..<\(last.blocks.count)] (committed=\(self.committedBlockCount))")
                if toolCancelStart < last.blocks.count {
                    var tailTextParts: [AgentContentPart] = []
                    for i in toolCancelStart..<last.blocks.count {
                        let block = last.blocks[i]
                        if case .text = block.kind, !block.content.isEmpty {
                            tailTextParts.append(.text(block.content))
                            logger.info("⏹️[StopDiag]   Case1 flush-include block[\(i)] len=\(block.content.count)")
                        } else {
                            logger.info("⏹️[StopDiag]   Case1 flush-skip block[\(i)] (not non-empty text)")
                        }
                    }
                    if !tailTextParts.isEmpty {
                        tailTextParts.append(.text("<system-reminder>The user stopped this response. Content may be incomplete.</system-reminder>"))
                        let assistantMsg = AgentMessage(role: .assistant, parts: tailTextParts)
                        let asstIdx = agentHistory.count
                        agentHistory.append(assistantMsg)
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let pid = await self.persistAgentMessage(assistantMsg), asstIdx < self.agentHistory.count {
                                self.agentHistory[asstIdx].dbMessageId = pid
                            }
                        }
                        // Advance committed counts so the kept blocks survive a later
                        // resume's `removeSubrange(committedBlockCount...)` trim.
                        self.prevCommittedBlockCount = self.committedBlockCount
                        self.committedBlockCount = last.blocks.count
                        logger.info("⏹️ Case 1: flushed \(tailTextParts.count) post-tool text part(s) to agentHistory before stopping")
                    }
                }

                canResume = true
                logger.info("⏹️ Case 1 (tool cancel): preserved \(last.blocks.count) blocks, canResume=true")
                dumpCandidateState("cleanup-EXIT-case1")
                return
            }

            // Case 0 (T-stop-clear-thinking-and-partial-ios): Stop fired in
            // the pre-first-chunk thinking gap — the candidate has no real
            // content, no committed prior iteration, and history does not
            // end with a tool_result (would mean Case 1 owns it). The
            // placeholder ChatMessage runAgentLoop pushed would otherwise
            // render as a bare "Minis" header bubble with the typing
            // indicator hosted on it. Drop the placeholder so the UI snaps
            // back to idle. Boundary against #566/#569 8bb0bf83: a candidate
            // with any non-empty text block or any tool_use block is kept
            // (drops through to Case 2 below); only a thinking-only / 0-block
            // placeholder is removed here. The placeholder is not persisted
            // by runAgentLoop entry — agentHistory is written only when an
            // iteration commits — so removing from messages alone is enough;
            // no DB rollback needed.
            let hasNonEmptyText = last.blocks.contains { block in
                if case .text = block.kind, !block.content.isEmpty { return true }
                return false
            }
            let hasAnyToolUse = last.blocks.contains { $0.toolStatus != nil }
            if !hasNonEmptyText, !hasAnyToolUse, prevCommittedBlockCount == 0 {
                logger.info("⏹️[StopDiag] Case0 REMOVING thinking-only placeholder at idx=\(candidateIdx) blocks=\(last.blocks.count) (no text, no tool_use, prevCommitted=0)")
                messages.remove(at: candidateIdx)
                dumpCandidateState("cleanup-EXIT-case0")
                return
            }

            // Case 2: Cancel during text or parameter streaming.
            // Remove incomplete tool blocks (parameters still streaming).
            last.blocks.removeAll { block in
                if case .streaming = block.toolStatus { return true }
                return false
            }

            // A SSE chunk can flip a block from .streaming to .running between
            // the user's tap and this cleanup running. Any .running block left
            // here has no tool_result yet (Case 1 already returned) — mark it
            // cancelled so the shimmer overlay stops, regardless of whether
            // we keep or drop the surrounding blocks below.
            for block in last.blocks {
                if case .running = block.toolStatus {
                    block.toolStatus = .cancelled
                }
            }

            let hasVisibleContent = last.blocks.contains(where: { !$0.content.isEmpty })

            logger.info("⏹️[StopDiag] Case2 hasVisibleContent=\(hasVisibleContent) prevCommitted=\(self.prevCommittedBlockCount) committed=\(self.committedBlockCount) blocks=\(last.blocks.count)")
            if hasVisibleContent {
                // Collect text from current iteration's blocks
                var textParts: [AgentContentPart] = []
                let safeStart = min(prevCommittedBlockCount, last.blocks.count)
                for i in safeStart..<last.blocks.count {
                    let block = last.blocks[i]
                    if case .text = block.kind, !block.content.isEmpty {
                        textParts.append(.text(block.content))
                    }
                }

                // Commit partial text to agentHistory with a truncation marker
                // so the model knows the response was interrupted.
                let histLastIsAsst = agentHistory.last?.role == .assistant
                logger.info("⏹️[StopDiag] Case2 collect textParts=\(textParts.count) safeStart=\(safeStart) histLastIsAsst=\(histLastIsAsst) → \(!textParts.isEmpty && !histLastIsAsst ? "WILL COMMIT" : "SKIP commit")")
                if !textParts.isEmpty, agentHistory.last?.role != .assistant {
                    textParts.append(.text("<system-reminder>The user stopped this response. Content may be incomplete.</system-reminder>"))
                    let assistantMsg = AgentMessage(role: .assistant, parts: textParts)
                    let asstIdx = agentHistory.count
                    agentHistory.append(assistantMsg)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let pid = await self.persistAgentMessage(assistantMsg), asstIdx < self.agentHistory.count {
                            self.agentHistory[asstIdx].dbMessageId = pid
                        }
                    }
                    logger.info("⏹️ Case 2: committed partial text (\(textParts.count) parts) with truncation marker to agentHistory")
                }

                // Update committed counts to preserve current blocks
                self.prevCommittedBlockCount = self.committedBlockCount
                self.committedBlockCount = last.blocks.count

                canResume = true
                logger.info("⏹️ Case 2 (text cancel): preserved \(last.blocks.count) blocks, canResume=true")
            } else if prevCommittedBlockCount > 0 {
                // No visible content in current iteration but prior iterations exist.
                logger.info("⏹️[StopDiag] Case2-branchB no-visible-content, prevCommitted=\(self.prevCommittedBlockCount)>0 → trim blocks[\(self.prevCommittedBlockCount)...], drop trailing asst history if present")
                if prevCommittedBlockCount < last.blocks.count {
                    last.blocks.removeSubrange(prevCommittedBlockCount...)
                }
                committedBlockCount = prevCommittedBlockCount
                if agentHistory.last?.role == .assistant {
                    agentHistory.removeLast()
                }
                canResume = true
                logger.info("⏹️ No visible content but prior iterations exist — canResume=true")
            } else {
                logger.warning("⏹️[StopDiag] Case2-branchC REMOVING empty candidate message at idx=\(candidateIdx) (no visible content, prevCommitted=0)")
                // Remove the candidate by index — NOT removeLast() — because a
                // queued `.user` message may sit after it (enqueued mid-tool).
                messages.remove(at: candidateIdx)
                if agentHistory.last?.role == .assistant {
                    agentHistory.removeLast()
                }
                logger.info("⏹️ Removed empty assistant message")
            }
            dumpCandidateState("cleanup-EXIT")
        } else {
            // Non-user cancellation (e.g. concurrency gate) — just remove empty message
            if let last = messages.last, last.role == .assistant,
               !last.blocks.contains(where: { !$0.content.isEmpty }) {
                messages.removeLast()
            }
        }
    }

}
