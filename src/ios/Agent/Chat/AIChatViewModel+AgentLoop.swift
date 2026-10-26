//
//  AIChatViewModel+AgentLoop.swift
//  Minis - AIChatViewModel 扩展（Agent/Chat）
//
//  Agent 循环：请求模型、读流、执行工具、重复，直到本轮结束。
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

    /// Clear ONLY the uncommitted streaming tail of an assistant message after a
    /// mid-stream failure, preserving every block already committed+persisted in
    /// an earlier round of the same loop. [T-ios-stream-retry-text-disappear]
    ///
    /// Blocks at index `[0, committedBlockCount)` are the committed prefix (text
    /// and terminal tool results from prior rounds, already in the DB) and are
    /// kept verbatim. From `committedBlockCount` onward we drop the in-flight
    /// failed stream: text blocks (partial output that the retry will re-stream)
    /// and tool blocks stuck in `.streaming` / `.running` (which would otherwise
    /// stay orphaned in the UI, never reaching a terminal state). A completed
    /// tool block in the tail (rare) is left alone so its result still shows.
    @MainActor
    static func clearUncommittedStreamTail(_ message: ChatMessage, committedBlockCount: Int) {
        let lowerBound = max(0, min(committedBlockCount, message.blocks.count))
        guard lowerBound < message.blocks.count else { return }
        var kept = Array(message.blocks[0..<lowerBound])
        for block in message.blocks[lowerBound...] {
            if block.kind == .text { continue }
            // [T-dup-thinking-block] Drop uncommitted thinking blocks — not persisted, retry stream will regenerate them.
            if block.kind == .thinking { continue }
            if case .streaming = block.toolStatus { continue }
            if case .running = block.toolStatus { continue }
            kept.append(block)
        }
        message.blocks = kept
    }

    func runAgentLoop(resumingAt existingMsgIdx: Int? = nil, committedBlocks: Int? = nil) async throws {
        func scopeForUserRequest(anchoredAt anchor: Int) -> WebReadScope {
            let upperBound = min(max(0, anchor), max(0, messages.count - 1))
            let requestID = messages.indices.reversed().first { index in
                index <= upperBound && messages[index].role == .user && !messages[index].isQueued
            }.map { messages[$0].id.uuidString } ?? UUID().uuidString
            return WebReadScope(
                sessionID: sessionId ?? "unsaved-\(requestID)",
                userRequestID: requestID
            )
        }
        var requestScope = scopeForUserRequest(anchoredAt: existingMsgIdx ?? max(0, messages.count - 1))
        defer {
            // Stop/resume retains the anonymous document; a completed request releases it.
            if !canResume {
                webReadService.endRequest(scope: requestScope)
                webSearchService.endRequest(scope: requestScope)
            }
        }
        // REPRO-DIAG(2026-05-16): bump global round counter and emit a clear
        // BEGIN/END marker so the user can grep `ROUND \d+` to slice the log
        // by attempt. A "round" = one runAgentLoop invocation, which is
        // triggered by a new user message send or a retry.
        let _diagRound = Self.bumpDiagRound()
        AppLogger(category: "RoundMarker").warning("══════════════ ROUND BEGIN \(_diagRound) ══════════════ vm=\(self.vmInstanceId) session=\(self.sessionId ?? "nil") history=\(self.agentHistory.count) resuming=\(existingMsgIdx != nil)")
        defer { AppLogger(category: "RoundMarker").warning("══════════════ ROUND END \(_diagRound) ════════════════ vm=\(self.vmInstanceId) session=\(self.sessionId ?? "nil") history=\(self.agentHistory.count) estimated ~\(self.estimateContextTokens()) tokens") }
        logger.info("🔄SESSION [vm=\(self.vmInstanceId)] runAgentLoop START session=\(self.sessionId ?? "nil") history=\(self.agentHistory.count) resuming=\(existingMsgIdx != nil)")
        defer { logger.info("🔄SESSION [vm=\(self.vmInstanceId)] runAgentLoop END session=\(self.sessionId ?? "nil") history=\(self.agentHistory.count) estimated ~\(self.estimateContextTokens()) tokens") }

        let loopSetupStart = CFAbsoluteTimeGetCurrent()

        // [T-ios-empty-after-toolresult-reminder] Fresh turn → allow one reminder retry.
        didInjectEmptyToolReminderThisRun = false

        // Resolve provider from ProviderConfigStore
        guard let entry = resolveCurrentEntry() else {
            let errMsg = ChatMessage(role: .assistant, content: "", blocks: [])
            errMsg.error = AppLocalized("No model configured. Add a provider in Settings.")
            messages.append(errMsg)
            return
        }
        var provider = await makeAgentProvider(for: entry)

        // Set extended cache TTL globally for Anthropic request patching
        RequestBodyPatcher.setExtendedCacheTTL(self.enhancedCacheEnabled)

        // Restore persisted thought signatures for Gemini session resume
        if let geminiProvider = provider as? GeminiAgentProvider, !pendingThoughtSignatures.isEmpty {
            geminiProvider.restoreToolCallMetadata(pendingThoughtSignatures)
            pendingThoughtSignatures = [:]
        }

        var activeGroupId: String?  // non-nil when using a group (enables fallback)
        var activeEntryId: String? = entry.id

        // Check if this entry came from a group binding
        if let sid = sessionId,
           let binding = ProviderConfigStore.shared.binding(for: sid),
           case .group(let gid, _) = binding.primarySource {
            activeGroupId = gid
        }

        // When resolved via cachedSessionModelId (no binding at all — e.g. an
        // iCloud-synced session whose binding row didn't sync), the entry may
        // still belong to the default group. Enable fallback by discovering
        // the group. Deliberately NOT applied when a .directEntry binding
        // exists: that is an explicit user pin, and enabling group fallback
        // would both switch models behind the user's back and overwrite the
        // pin with a group binding on fallback success.
        if activeGroupId == nil,
           sessionId.flatMap({ ProviderConfigStore.shared.binding(for: $0) }) == nil {
            let store = ProviderConfigStore.shared
            if let gid = store.defaultPrimaryGroupId,
               let group = store.group(for: gid),
               group.memberEntryIds.contains(entry.id) {
                activeGroupId = gid
            }
        }
        let tools = makeAgentTools()

        var userSystemPrompt = baseSystemPrompt
        let activeModel = ProviderConfigStore.shared.entry(for: entry.id)?.model ?? selectedModel
        if let capFragment = activeModel.capabilityPromptFragment {
            userSystemPrompt += "\n\n" + capFragment
        }
        if let behaviorFragment = activeModel.agentBehaviorPromptFragment {
            userSystemPrompt += "\n\n" + behaviorFragment
        }

        // Inject enabled skill metadata into system prompt
        if let sid = sessionId,
           let skillFragment = SkillStore.shared.skillPromptFragment(for: sid) {
            userSystemPrompt += "\n\n" + skillFragment
        }

        // [T-mcp-integration-ios] Inject Top-20 enabled MCP server metadata.
        if let sid = sessionId,
           let mcpFragment = MCPStore.shared.systemPromptSnippet(for: sid) {
            userSystemPrompt += "\n\n" + mcpFragment
        }

        // [T-memory-toggle-gates-injection-and-tools-ios] Memory injection
        // (GLOBAL.md + recent daily logs) is gated by the per-session
        // memoryEnabled toggle. SOUL.md (identity / persona) is rendered
        // by SystemPromptBuilder.identitySection() above and is NOT
        // affected by this toggle.
        // [T-memory-enabled-new-session-bug DIAG] vm.memoryEnabled is the
        // value the injection actually keys off. Trace it against the
        // session so a repro shows whether loadSession seeded it from the
        // global default.
        AppLogger(category: "MemDiag").info("[MemDiag] inject-decision sid=\(self.sessionId?.prefix(8) ?? "nil") vm.memoryEnabled=\(self.memoryEnabled)")
        if memoryEnabled {
            if let memoryFragment = Self.loadGlobalMemoryFragment() {
                userSystemPrompt += "\n\n" + memoryFragment
            }
            if let dailyFragment = Self.loadRecentDailyMemoryFragment() {
                userSystemPrompt += "\n\n" + dailyFragment
            }
        }
        // Authoritative memory-status footer (overrides any earlier
        // baseSystemPrompt mentions when memory is disabled).
        userSystemPrompt += memoryStatusFragment

        let promptBuildMs = (CFAbsoluteTimeGetCurrent() - loopSetupStart) * 1000
        logger.info("⏱️ [runAgentLoop] prompt build elapsed=\(String(format: "%.1f", promptBuildMs))ms history=\(self.agentHistory.count)")
        await Task.yield()

        // When resuming after error, reuse the existing assistant message; otherwise create new
        var msgIdx: Int
        if let existingMsgIdx {
            msgIdx = existingMsgIdx
            let okBounds = existingMsgIdx >= 0 && existingMsgIdx < messages.count
            let role = okBounds ? (messages[existingMsgIdx].role == .assistant ? "assistant" : "user") : "OOB"
            let blocks = okBounds ? messages[existingMsgIdx].blocks.count : -1
            AppLogger(category: "RetryDiag").info("[RetryDiag] runAgentLoop RESUME existingMsgIdx=\(existingMsgIdx) role=\(role) blocks=\(blocks) committedBlocks=\(committedBlocks ?? -1) messagesCount=\(self.messages.count)")
        } else {
            messages.append(ChatMessage(role: .assistant, content: "", blocks: []))
            msgIdx = messages.count - 1
        }
        // Capture the assistant message's stable id so we can re-find it
        // when the `messages` array gets mutated mid-stream (user delete,
        // reloadMessagesFromDB rebuild, compactBefore removeAll, etc.). On
        // any retry / fallback catch path we resync `msgIdx` via this id
        // before touching `messages[msgIdx]`; if the message is gone we
        // bail out cleanly instead of crashing with Index out of range.
        var runMsgId: UUID = msgIdx < messages.count ? messages[msgIdx].id : UUID()
        /// Track how many blocks were already committed to agentHistory
        /// so subsequent iterations only add new blocks.
        var committedBlockCount = committedBlocks ?? 0
        self.committedBlockCount = committedBlockCount
        var turnUsage = TokenUsage()

        // Log context baseline for offload diagnostics
        let estimatedTokens = estimateContextTokens()
        logger.info("📐 Context baseline: agentHistory=\(self.agentHistory.count) msgs, estimated ~\(estimatedTokens) tokens, turnUsage.latestContextTokens=\(turnUsage.latestContextTokens) (model window: \(ProviderConfigStore.shared.entry(for: entry.id)?.model.contextWindowTokens ?? 0))")

        // Safety: scan the entire agentHistory for assistant messages with tool_use
        // that lack corresponding tool_result messages. This can happen when:
        // - User cancelled mid-tool-execution and cleanup missed an entry
        // - Session was restored from persistence with incomplete state
        // - A race condition between cancel cleanup and retry left orphaned tool_uses
        //
        // IMPORTANT: skip injection when the assistant message was stream-interrupted.
        // A mid-stream network drop leaves tool_use blocks with empty/partial inputs
        // (partialJson never completed). Injecting a tool_result for such a tool_use
        // causes API 400 "unexpected tool_use_id" or "invalid input" errors.
        // Instead, the interrupted assistant message is dropped so the model retries
        // cleanly from the previous user/tool_result turn.
        //
        // First handle the last message specially (may need to be dropped entirely if interrupted).
        if let lastAssistant = agentHistory.last, lastAssistant.role == .assistant, lastAssistant.isInterrupted {
            agentHistory.removeLast()
            logger.warning("Dropped interrupted assistant message with partial tool_use(s) — will retry from previous turn")
        }

        // [T-ios-retry-orphan-toolresult] Snapshot the pairing as runAgentLoop
        // sees it on entry — BEFORE the orphan-removal below mutates anything.
        // If this shows ORPHANS, the entry came in already-broken (the cut /
        // a prior cancel / merged-render reorder stranded a tool_result); the
        // removal pass is only papering over it. Compare against subcut-AFTER.
        dumpHistoryPairing("runAgentLoop-entry (pre-orphan-scan)")
        await Task.yield()

        // Now scan ALL messages for orphaned tool_uses and orphaned tool_results.
        // Build sets of all tool_use IDs and tool_result IDs.
        var allToolUseIds = Set<String>()
        var allToolResultIds = Set<String>()
        for msg in agentHistory {
            for part in msg.parts {
                if case .toolUse(let id, _, _) = part {
                    allToolUseIds.insert(id)
                }
                if case .toolResult(let id, _, _, _, _, _, _, _) = part {
                    allToolResultIds.insert(id)
                }
            }
        }

        // 1. Remove orphaned tool_results (tool_result without matching tool_use).
        //    These cause API 400: "unexpected tool_use_id found in tool_result blocks".
        var removedOrphanedResults = 0
        for i in (0..<agentHistory.count).reversed() {
            let msg = agentHistory[i]
            guard msg.role == .user else { continue }
            let beforeCount = msg.parts.count
            let cleanedParts = msg.parts.filter { part in
                if case .toolResult(let id, _, _, _, _, _, _, _) = part {
                    if !allToolUseIds.contains(id) {
                        logger.warning("Removing orphaned tool_result id=\(id) at history[\(i)]")
                        removedOrphanedResults += 1
                        return false
                    }
                }
                return true
            }
            if cleanedParts.count < beforeCount {
                if cleanedParts.isEmpty {
                    // All parts were orphaned tool_results — remove entire message
                    agentHistory.remove(at: i)
                } else {
                    agentHistory[i] = AgentMessage(role: .user, parts: cleanedParts)
                }
            }
        }
        if removedOrphanedResults > 0 {
            logger.warning("Removed \(removedOrphanedResults) orphaned tool_result(s) without matching tool_use")
        }

        // 2. Inject placeholder tool_results for orphaned tool_uses (tool_use without matching tool_result).
        // Rebuild allToolResultIds after removals above.
        allToolResultIds.removeAll()
        for msg in agentHistory {
            for part in msg.parts {
                if case .toolResult(let id, _, _, _, _, _, _, _) = part {
                    allToolResultIds.insert(id)
                }
            }
        }

        var insertions: [(index: Int, message: AgentMessage)] = []
        for (i, msg) in agentHistory.enumerated() {
            guard msg.role == .assistant else { continue }
            let orphanedToolUses = msg.parts.compactMap { part -> (String, String)? in
                if case .toolUse(let id, let name, _) = part, !allToolResultIds.contains(id) {
                    return (id, name)
                }
                return nil
            }
            guard !orphanedToolUses.isEmpty else { continue }

            let insertIdx = i + 1
            let placeholderParts = orphanedToolUses.map { (id, name) in
                AgentContentPart.toolResult(
                    id: id, name: name,
                    content: "Tool execution was interrupted by an unexpected error.",
                    isError: true
                )
            }
            let placeholderMsg = AgentMessage(role: .user, parts: placeholderParts)
            insertions.append((index: insertIdx, message: placeholderMsg))
            logger.warning("Found \(orphanedToolUses.count) orphaned tool_use(s) in assistant message at index \(i)")
        }
        for insertion in insertions.reversed() {
            agentHistory.insert(insertion.message, at: insertion.index)
        }
        if !insertions.isEmpty {
            logger.warning("Injected placeholder tool results for \(insertions.count) assistant message(s) with orphaned tool_use(s)")
        }

        let orphanScanMs = (CFAbsoluteTimeGetCurrent() - loopSetupStart) * 1000
        logger.info("⏱️ [runAgentLoop] setup complete elapsed=\(String(format: "%.1f", orphanScanMs))ms (prompt+orphanScan)")
        await Task.yield()

        // Counted instead of `while true` so we have a hard backstop against
        // runaway tool loops that slip past ToolLoopDetector. The post-loop
        // tail uses `hitTurnLimit` (not `turnCount >= maxAgentTurns`) to
        // distinguish "exhausted the ceiling" from any internal `break`:
        // the defer below increments turnCount on *every* iteration end,
        // including breaks, so a value-based check would false-positive
        // when the happy-path break fires on the last allowed iteration.
        // hitTurnLimit stays true only when the while-condition itself
        // becomes false, never set false by any break path.
        var turnCount = 0
        var hitTurnLimit = true
        // [T-chat-auto-compact-inloop] Count in-loop auto-compactions so a loop
        // that keeps hitting the threshold can't compact forever; when the cap
        // is reached and we're still near capacity, the loop stops as exhausted.
        var compactionsThisLoop = 0
        loopLabel: while turnCount < Self.maxAgentTurns {
            defer { turnCount += 1 }
            // [LoopHeartbeat] (#181) One line per loop iteration. If the loop
            // wedges on an await, the last heartbeat pins which iteration it
            // died in, even when every other diagnostic is missing.
            logger.info("[LoopHeartbeat] turnCount=\(turnCount) session=\(self.sessionId ?? "nil") time=\(Self.diagTimestamp(Date()))")
            try Task.checkCancellation()
            if let sid = self.sessionId {
                SessionActivityTracker.shared.updateLoopIteration(sid, iteration: turnCount + 1)
            }

            // [T-ios-inloop-compact-freeze] Re-anchor msgIdx by stable id every
            // iteration. External mutations while the loop runs — in-loop
            // compaction's divider insert / status-row removeAll, a mid-loop
            // reloadMessagesFromDB wholesale rebuild, user delete — shift or
            // replace array members; a raw index (or a bail-out `break`) then
            // silently streams every later round into the wrong / a detached
            // ChatMessage: the UI freezes on the last rendered block while the
            // DB keeps advancing (field case 2026-07-31, sessions 35D4D2B2 /
            // 7FDC5B52: vm froze at sortOrder≈130 while DB reached 138).
            if msgIdx < 0 || msgIdx >= messages.count || messages[msgIdx].id != runMsgId {
                if let resynced = messages.firstIndex(where: { $0.id == runMsgId }) {
                    AppLogger(category: "BlocksLost").warning("[BlocksLost] LOOP-RESYNC msgIdx \(msgIdx)→\(resynced) after external messages mutation (count=\(messages.count))")
                    msgIdx = resynced
                } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    // Array was rebuilt with fresh instances (reload) — adopt the
                    // trailing assistant message, which the rebuild reconstructed
                    // from the same rows this loop already persisted. Everything
                    // it now holds came from the DB, so it is all committed.
                    AppLogger(category: "BlocksLost").warning("[BlocksLost] LOOP-REBIND msgIdx \(msgIdx)→\(lastIdx) — streaming message instance gone, adopting trailing assistant (count=\(messages.count))")
                    msgIdx = lastIdx
                    runMsgId = messages[lastIdx].id
                    committedBlockCount = messages[lastIdx].blocks.count
                    self.committedBlockCount = committedBlockCount
                } else {
                    // No trailing assistant to adopt — append a fresh one so the
                    // rest of the turn stays visible instead of streaming into a
                    // detached object.
                    AppLogger(category: "BlocksLost").warning("[BlocksLost] LOOP-REAPPEND — streaming message gone and no trailing assistant (count=\(messages.count)); appending fresh assistant message")
                    messages.append(ChatMessage(role: .assistant, content: "", blocks: []))
                    msgIdx = messages.count - 1
                    runMsgId = messages[msgIdx].id
                    committedBlockCount = 0
                    self.committedBlockCount = 0
                }
            }

            // Trim old images: keep only the most recent `kImageContextKeepCount`
            // images in history; older ones become text placeholders so the model
            // can re-view them via read_image. Runs before token-based offload so
            // image bytes are removed first.
            trimOldImagesFromHistory()

            // Context window management: offload old tool content if approaching limit
            let activeModelForOffload = ProviderConfigStore.shared.entry(for: activeEntryId ?? "")?.model ?? selectedModel
            offloadContextIfNeeded(model: activeModelForOffload, lastContextTokens: turnUsage.latestContextTokens)

            // [T-chat-auto-compact-inloop] In-loop context guard. checkContext-
            // BeforeSend only runs at the SEND entry point; a single turn that
            // fans out into many tool iterations can blow past the compact/
            // exhausted thresholds mid-loop, where offload alone (which only
            // moves tool payloads to files) can't recover if the bulk is the
            // model's own text. Re-evaluate the policy each iteration, AFTER
            // offload had its chance:
            //   • .needsCompact → compact in place (allowDuringProcessing) and
            //     continue; the next API call reads the freshly-compacted
            //     effectiveAgentHistory() automatically, so no resume handoff.
            //   • .exhausted (compaction couldn't get us under the ceiling) →
            //     stop the loop with a resumable, user-visible notice; the loop
            //     cannot present a modal and wait for a tap.
            // Turn-budget rule: a compaction iteration is a space-management
            // step, NOT a task iteration, so it must NOT consume a turnCount
            // slot (`continue` runs the defer, so we pre-decrement to cancel
            // it) — but the overall maxAgentTurns ceiling is NEVER reset by a
            // compaction, or a loop that keeps compacting could run forever and
            // defeat the runaway backstop.
            switch checkContextBeforeSend() {
            case .ok:
                break
            case .needsCompact:
                let compactAnchorId = messages.last(where: {
                    $0.role != .compactDivider && $0.role != .systemInfo && !$0.isCompactedHistory
                })?.id
                if compactionsThisLoop < Self.maxInLoopCompactions,
                   let anchorId = compactAnchorId {
                    compactionsThisLoop += 1
                    logger.info("[Context] In-loop near capacity — auto-compacting (\(compactionsThisLoop)/\(Self.maxInLoopCompactions)) turnCount=\(turnCount)")
                    await compactBefore(anchorId, allowDuringProcessing: true)

                    // [T-ios-inloop-compact-divider-order] GH#235. Seal the
                    // bubble this run has been writing into and continue in a
                    // FRESH one below the divider.
                    //
                    // `compactBefore` inserts the divider immediately AFTER the
                    // anchor row and greys everything up to it. In the in-loop
                    // case the anchor resolves to `messages.last(active)` —
                    // which is this run's own still-streaming assistant bubble.
                    // So without this, the loop `continue`s and keeps appending
                    // thinking / tool blocks into a bubble that now sits ABOVE
                    // the divider and is flagged `isCompactedHistory`: new
                    // output appears greyed out inside the "already compacted"
                    // region, in the wrong chronological place. That is exactly
                    // the reported symptom.
                    //
                    // Starting a new bubble (rather than moving the divider) is
                    // what matches the user's mental model: everything produced
                    // before the compaction really is pre-compaction history,
                    // and everything after it belongs below the line. It also
                    // keeps `compactBefore` untouched — the user-initiated
                    // "Compact Above" path anchors on a finished message and is
                    // already correct.
                    //
                    // The sealed bubble keeps whatever it had; if it never
                    // produced anything (compaction fired before the first
                    // block landed) it would render as an empty grey row, so
                    // drop it in that case.
                    if let sealedIdx = messages.firstIndex(where: { $0.id == runMsgId }) {
                        let sealed = messages[sealedIdx]
                        sealed.isAwaitingModelResponse = false
                        if sealed.blocks.isEmpty && sealed.content.isEmpty {
                            messages.remove(at: sealedIdx)
                            logger.info("[Context] In-loop compact: dropped empty sealed bubble at \(sealedIdx)")
                        }
                    }
                    let fresh = ChatMessage(role: .assistant, content: "", blocks: [])
                    fresh.isAwaitingModelResponse = true
                    messages.append(fresh)
                    msgIdx = messages.count - 1
                    runMsgId = fresh.id
                    // Blocks already committed belong to the sealed bubble; the
                    // fresh one starts from zero or the next round would skip
                    // its first N blocks when syncing to agentHistory.
                    committedBlockCount = 0
                    self.committedBlockCount = 0
                    logger.info("[Context] In-loop compact: continuing in fresh bubble idx=\(msgIdx) id=\(runMsgId.uuidString.prefix(8)) below the divider")

                    turnCount -= 1   // cancel this iteration's defer increment
                    continue
                }
                // Already compacted the cap this loop and still near capacity —
                // fall through to the same stop path as exhaustion.
                logger.info("[Context] In-loop still near capacity after \(compactionsThisLoop) compaction(s) — stopping loop as exhausted")
                fallthrough
            case .exhausted:
                logger.info("[Context] In-loop exhausted — stopping loop with resumable notice (turnCount=\(turnCount))")
                appendSystemInfo(AppLocalized("Context is full and could not be compacted further. Start a new session or clear the chat to continue."), icon: "exclamationmark.triangle")
                canResume = true
                hitTurnLimit = false
                break loopLabel
            }

            CrashReporter.shared.setLastAPI(provider: provider.name, model: activeModelForOffload.id)
            logger.info("Calling \(provider.name) API (streaming) with \(self.agentHistory.count) messages")
            // [StreamDiag] (#181) Monotonic request sequence, so a
            // [StreamDiag][STALL] line can be matched against the request it
            // belongs to — or shown to belong to none, which would mean the
            // request never went out (candidate 1).
            Self.diagRequestSeq &+= 1
            let diagReqSeq = Self.diagRequestSeq
            logger.info("[StreamDiag] req#\(diagReqSeq) DISPATCH turnCount=\(turnCount) session=\(self.sessionId ?? "nil") provider=\(provider.name) model=\(activeModelForOffload.id) messages=\(self.agentHistory.count) at=\(Self.diagTimestamp(Date()))")

            #if DEBUG
            // Begin a new agent request trace
            AgentRequestTrace.shared.begin()
            AgentRequestTrace.shared.step("agentLoop.start", detail: "provider=\(provider.name) messages=\(agentHistory.count)")

            // Log agent history summary for debugging tool result delivery.
            // [T-ios-log-noise-reduction] The full dump ran on every agent-loop
            // API call, re-printing the entire (growing) history each iteration
            // — the single biggest Debug-log noise source (~13.6k lines). The
            // structured AgentRequestTrace still records every entry (cheap,
            // in-memory, not NSLog), but the NSLog `📋 agentHistory[i]` line now
            // only fires for entries NEW since the last dump (delta), preceded
            // by a one-line summary. `lastDumpedAgentHistoryCount` resets to 0
            // whenever the history shrinks (retry truncation / new session) so
            // the next dump re-prints from the cut point.
            if agentHistory.count < lastDumpedAgentHistoryCount {
                lastDumpedAgentHistoryCount = 0
            }
            let deltaStart = lastDumpedAgentHistoryCount
            logger.debug("📋 agentHistory dump: total=\(agentHistory.count) newSince=\(deltaStart)")
            for (i, msg) in agentHistory.enumerated() {
                var partSummaries: [String] = []
                for part in msg.parts {
                    switch part {
                    case .text(let t):
                        let preview = String(t.prefix(200))
                        partSummaries.append("text(\(t.count)ch): \"\(preview)\(t.count > 200 ? "..." : "")\"")
                    case .toolUse(let id, let name, _):
                        // Anthropic ids start with the literal 8-char prefix
                        // `toolu_01`, so `prefix(8)` collapses every Anthropic
                        // tool_use to the same string in the trace and masks
                        // real id differences between parallel tool_uses
                        // (T-ios-concurrent-toolcall-dup-id). Use prefix(20)
                        // so concurrent calls are visibly distinct.
                        partSummaries.append("tool_use(\(name), id:\(id.prefix(20)))")
                    case .toolResult(let id, let name, let content, let isError, let imgData, _, _, _):
                        let head = String(content.prefix(200))
                        let tail = content.count > 400 ? String(content.suffix(200)) : ""
                        let errTag = isError ? " [ERROR]" : ""
                        let imgTag = imgData != nil ? " [IMG]" : ""
                        // Same prefix(20) as the .toolUse branch above — see note there.
                        partSummaries.append("tool_result(\(name), id:\(id.prefix(20)), \(content.count)ch\(errTag)\(imgTag)): head=\"\(head)\(content.count > 200 ? "..." : "")\"" + (tail.isEmpty ? "" : " tail=\"...\(tail)\""))
                    case .imageData(_, let mime, _):
                        partSummaries.append("image(\(mime))")
                    }
                }
                AgentRequestTrace.shared.step("agentHistory[\(i)]", detail: "\(msg.role.rawValue): \(partSummaries.joined(separator: " | "))")
                if i >= deltaStart {
                    logger.debug("📋 agentHistory[\(i)] \(msg.role.rawValue): \(partSummaries.joined(separator: " | "))")
                }
            }
            lastDumpedAgentHistoryCount = agentHistory.count
            #endif

            #if DEBUG
            let iterationStart = Date()
            var iterationUsage = TokenUsage()
            AgentRequestTrace.shared.step("streamAgentMessage.call", detail: "maxTokens=\(provider.defaultMaxTokens)")
            #endif
            let iterationStreamStart = Date()
            let prevEntryId = activeEntryId
            fallbackReasons.removeAll()
            // Phase B: route through effectiveAgentHistory() so compact summary is
            // synthesized at inference time instead of baked into agentHistory.
            let contextHistory = effectiveAgentHistory()
            // [T-msgidx-oob] Re-resync before subscripting. The loop-top resync
            // (~line 4698) is not sufficient for this site: the in-loop
            // compaction guard above runs `await compactBefore(...)` in between,
            // and compaction deliberately mutates `messages` (removeAll of
            // status/divider rows, insert of the new divider) — so by the time
            // we build this request the index can be stale or point at a
            // different row. Cheap no-op on the overwhelmingly common path
            // (index valid + id matches).
            if msgIdx < 0 || msgIdx >= messages.count || messages[msgIdx].id != runMsgId {
                guard let resynced = messages.firstIndex(where: { $0.id == runMsgId }) else {
                    logger.error("🔀STREAM round-start: assistant message id=\(runMsgId) vanished (count=\(messages.count)) — aborting round")
                    throw LLMError.transientError(message: "The assistant message was removed while preparing the request.")
                }
                logger.warning("🔀STREAM round-start: msgIdx resynced → \(resynced) (count=\(messages.count))")
                msgIdx = resynced
            }
            let contextUsageRevision = beginContextUsageRequest()
            let contextUsageIdentities = captureContextUsageIdentities(
                activeEntryId: activeEntryId,
                activeGroupId: activeGroupId
            )
            let contextUsageInitialEntryId = activeEntryId
            var contextUsageStreamEntryId: String?
            var contextUsageStreamConfigRevision: UInt?
            let onContextUsageStreamOpened: (String?, UInt?) -> Void = { [self] entryID, _ in
                contextUsageStreamEntryId = entryID
                contextUsageStreamConfigRevision = entryID
                    .flatMap { ProviderConfigStore.shared.entry(for: $0) }
                    .map { contextUsageIdentity(for: $0).configRevision }
            }
            let stream = try await streamWithGroupFallback(
                provider: provider,
                messages: contextHistory,
                baseSystemPrompt: baseSystemPrompt,
                systemPrompt: userSystemPrompt,
                tools: tools,
                model: activeModel,
                lastContextTokens: turnUsage.latestContextTokens,
                chatMessage: messages[msgIdx],
                activeGroupId: &activeGroupId,
                activeEntryId: &activeEntryId,
                onStreamOpened: onContextUsageStreamOpened
            )
            // [StreamDiag] (#181) The stream object now exists. Note this is
            // "request accepted / stream handle obtained", NOT first byte — the
            // first actual SSE event is logged by [StreamDiag] event #1 in
            // processStreamEvents. If a stall is logged with a DISPATCH and this
            // line but no event #1, the connection produced no first byte; if
            // event #1 appeared and it stalled later, the stream died mid-flight.
            logger.info("[StreamDiag] req#\(diagReqSeq) STREAM-OPEN elapsed=\(String(format: "%.2f", Date().timeIntervalSince(iterationStreamStart)))s at=\(Self.diagTimestamp(Date()))")

            // Helper: update provider & system prompt when fallback switched entries.
            // Returns true if a switch occurred.
            @discardableResult
            func applyFallbackSwitch() async -> Bool {
                guard activeEntryId != prevEntryId, let newEntryId = activeEntryId,
                      let newEntry = ProviderConfigStore.shared.entry(for: newEntryId) else {
                    return false
                }
                logger.info("🔀AGENT_LOOP provider updated after fallback: \(prevEntryId ?? "nil") → \(newEntryId)")
                provider = await makeAgentProvider(for: newEntry)
                userSystemPrompt = baseSystemPrompt
                if let capFragment = newEntry.model.capabilityPromptFragment {
                    userSystemPrompt += "\n\n" + capFragment
                }
                if let behaviorFragment = newEntry.model.agentBehaviorPromptFragment {
                    userSystemPrompt += "\n\n" + behaviorFragment
                }
                if let sid = sessionId,
                   let skillFragment = SkillStore.shared.skillPromptFragment(for: sid) {
                    userSystemPrompt += "\n\n" + skillFragment
                }
                // [T-mcp-integration-ios] Inject Top-20 enabled MCP metadata.
                if let sid = sessionId,
                   let mcpFragment = MCPStore.shared.systemPromptSnippet(for: sid) {
                    userSystemPrompt += "\n\n" + mcpFragment
                }
                // [T-memory-toggle-gates-injection-and-tools-ios] Mirror
                // the gate from the first injection site — fallback to a
                // new provider must respect the per-session memoryEnabled
                // toggle the same way the initial system prompt did.
                if memoryEnabled {
                    if let memoryFragment = Self.loadGlobalMemoryFragment() {
                        userSystemPrompt += "\n\n" + memoryFragment
                    }
                    if let dailyFragment = Self.loadRecentDailyMemoryFragment() {
                        userSystemPrompt += "\n\n" + dailyFragment
                    }
                }
                userSystemPrompt += memoryStatusFragment
                fallbackTrigger += 1
                if !fallbackReasons.isEmpty {
                    // Resync the assistant message index by its stable id before
                    // mutating `messages`. applyFallbackSwitch performs several
                    // awaits above (makeAgentProvider, fragment loads), during
                    // which a concurrent path (user delete, reloadMessagesFromDB,
                    // compactBefore, session switch) may have shrunk the array —
                    // the captured `msgIdx` then points past the end and the raw
                    // `messages[msgIdx]` subscript traps with "Index out of range"
                    // (crash on AsyncRenderer-adjacent path, AIChatViewModel.swift
                    // 2855). Every other messages[msgIdx] write in this loop already
                    // resyncs-or-guards; this site was the lone unguarded one
                    // (T-ios-fallback-switch-msgidx-oob). If the message is gone,
                    // skip the notice — it's a non-critical UI hint.
                    if let resynced = messages.firstIndex(where: { $0.id == runMsgId }) {
                        msgIdx = resynced
                        let trailLines = fallbackReasons.map { "⚠️ \($0.model) (\($0.instance)): \($0.reason)" }
                        let instanceLabel = ProviderConfigStore.shared.instance(for: newEntry.providerInstanceId)?.label ?? newEntry.model.provider
                        let noticeText = trailLines.joined(separator: "\n") + "\n" + AppLocalized("Switched to \(newEntry.model.displayName) (\(instanceLabel))")
                        let infoBlock = AssistantBlock(kind: .info, content: noticeText)
                        messages[msgIdx].blocks.insert(infoBlock, at: 0)
                        fallbackReasons.removeAll()
                    } else {
                        logger.error("🔀AGENT_LOOP applyFallbackSwitch: assistant message id=\(runMsgId) no longer in messages (count=\(self.messages.count)) — skipping fallback notice")
                        fallbackReasons.removeAll()
                    }
                }
                return true
            }

            await applyFallbackSwitch()
            scrollToBottomSignal.send()

            // Helper: check if a StreamResult is empty (no content produced).
            // Catches both the nil-stopReason path (Anthropic SSE error inside
            // HTTP 200) and the endTurn-with-zero-output path (OpenAI gpt-5.5
            // on long contexts: `finish_reason=stop` with no text/tool/reasoning).
            func isEmptyResponse(_ r: StreamResult) -> Bool {
                let hasReasoning = !(r.reasoningContent ?? "").isEmpty
                return r.assistantText.isEmpty && r.toolEntries.isEmpty
                    && !hasReasoning && !r.isStreamInterrupted
                    && r.stopReason != .maxTokens
                    // A refusal (Anthropic safety classifier decline) is deterministic:
                    // the content is empty but retrying the identical request just gets
                    // declined again and burns tokens. Don't route it through the
                    // transient-retry / group-fallback path; let the .refusal branch in
                    // the stop-reason handler surface it directly. [T-ios-fable5-empty-response]
                    && r.stopReason != .refusal
            }

            // Process SSE stream events on a background thread to keep
            // CFNetwork HTTP/2 HPACK decoding off the main RunLoop.
            // If a retryable error (transient 5xx / network) occurs mid-stream,
            // retry the entire request via streamWithAutoRetry before giving up.
            // If auto-retry is also exhausted, re-enter streamWithGroupFallback
            // to try the next model in the group.
            let streamResult: StreamResult
            do {
                let result = try await processStreamEvents(
                    stream: stream,
                    msgIdx: msgIdx,
                    provider: provider
                )
                // Detect empty responses — the stream completed without producing any
                // content blocks or a stop reason.  This happens when the Anthropic API
                // returns an SSE `event: error` (e.g. overloaded_error) inside an HTTP 200
                // response: the SDK silently terminates the stream instead of throwing.
                // Treat as a transient error so it enters the auto-retry path below.
                if isEmptyResponse(result) {
                    // [T-ios-empty-after-toolresult-reminder] Special case: the
                    // server returned nothing right after we handed it a tool
                    // result. The model owes a follow-up (next tool call or a
                    // final answer) but stalled — from the user's side the chat
                    // "stops" with no explanation. Inject a one-shot
                    // <system-reminder> into the last tool result and retry a
                    // SINGLE round. The per-run flag ensures this fires at most
                    // once, so it can never loop; if the reminder round is also
                    // empty we report an error (below) instead of a silent stall.
                    guard !didInjectEmptyToolReminderThisRun, lastEffectiveMessageIsToolResult() else {
                        logger.error("🔁STREAM empty response (no content, no stop reason) — treating as transient error")
                        throw LLMError.transientError(message: "Server returned an empty response (overloaded or upstream error)")
                    }
                    didInjectEmptyToolReminderThisRun = true
                    logger.error("🔁STREAM empty after tool result — injecting <system-reminder> and retrying one round")
                    // [T-msgidx-oob] Re-resync before subscripting: the stream
                    // we just consumed is a suspension point, so `messages` may
                    // have been mutated meanwhile (iCloud inbound rebuild,
                    // compaction sweep, user delete) and `msgIdx` gone stale.
                    // Reproduced deterministically on device (mock provider
                    // stalls, chat.debugRemoveMessages drops a row, provider
                    // then returns empty): this exact subscript trapped, and the
                    // reminder request below was never sent — matching the
                    // field crash 1.11(15) .ips 2026-08-15 14:02, symbolicated
                    // to this line. Same guard shape as the fallback paths below.
                    if msgIdx < 0 || msgIdx >= messages.count || messages[msgIdx].id != runMsgId {
                        guard let resynced = messages.firstIndex(where: { $0.id == runMsgId }) else {
                            logger.error("🔁STREAM empty-reminder: assistant message id=\(runMsgId) vanished (count=\(messages.count)) — aborting round")
                            throw LLMError.transientError(message: "Server returned an empty response (overloaded or upstream error)")
                        }
                        logger.warning("🔁STREAM empty-reminder: msgIdx resynced → \(resynced) (count=\(messages.count))")
                        msgIdx = resynced
                    }
                    let reminderStream = try await streamWithAutoRetry(
                        provider: provider,
                        messages: applyRequestImageBudget(historyWithEmptyToolResultReminder()),
                        systemPrompt: userSystemPrompt,
                        tools: tools,
                        maxTokens: dynamicMaxTokens(provider: provider, model: activeModel, lastContextTokens: turnUsage.latestContextTokens),
                        chatMessage: messages[msgIdx],
                        onStreamOpened: onContextUsageStreamOpened
                    )
                    let reminderResult = try await processStreamEvents(
                        stream: reminderStream,
                        msgIdx: msgIdx,
                        provider: provider
                    )
                    if isEmptyResponse(reminderResult) {
                        // Still empty after the nudge — a genuine failure, not a
                        // transient blip. Surface it clearly instead of silently
                        // looping so the user knows why the chat stopped.
                        logger.error("🔁STREAM still empty after <system-reminder> retry — reporting error")
                        throw LLMError.providerError(message: "The model returned no response after a tool result, even after a reminder. It may be overloaded — please retry or switch models.")
                    }
                    // Recovered — proceed with the reminder round's content.
                    streamResult = reminderResult
                } else {
                    streamResult = result
                }
            } catch let streamError as LLMError where streamError.isRetryable {
                logger.error("🔁STREAM mid-stream retryable error, entering autoRetry: \(streamError.localizedDescription)")
                // Resync msgIdx by stable id before touching messages — the
                // array may have been shrunk by a concurrent path (user
                // delete, reloadMessagesFromDB, compactBefore) during the
                // failed stream. If the assistant message is gone, bail.
                if let resynced = messages.firstIndex(where: { $0.id == runMsgId }) {
                    msgIdx = resynced
                } else {
                    logger.error("🔁STREAM mid-stream catch: assistant message id=\(runMsgId) no longer in messages (count=\(messages.count)) — aborting retry")
                    throw streamError
                }
                // Clear text blocks AND incomplete tool blocks from the interrupted stream
                // before retrying. Tool blocks stuck in .streaming or .running would otherwise
                // remain orphaned in the UI forever (never transition to a terminal state).
                //
                // [T-ios-stream-retry-text-disappear] ONLY clear the UNCOMMITTED tail
                // (blocks at index >= committedBlockCount). Earlier rounds of this same
                // resumed loop already committed+persisted their text/tool blocks to the
                // DB (committedBlockCount marks that boundary). The old unbounded
                // `removeAll { kind == .text }` wiped those committed text blocks from the
                // UI too, so a mid-stream retry made all prior post-tool text vanish on
                // screen even though it was still in the DB (reappearing only on reload).
                // Mirror resume()/Stop's `removeSubrange(committedBlockCount...)` boundary.
                await MainActor.run {
                    guard msgIdx < messages.count else { return }
                    Self.clearUncommittedStreamTail(messages[msgIdx], committedBlockCount: committedBlockCount)
                    messages[msgIdx].streamInterruptCount += 1
                }
                // If group uses "always" fallback strategy, skip auto-retry and go straight
                // to group fallback for mid-stream errors too.
                let midStreamFbStrategy = activeGroupId
                    .flatMap { ProviderConfigStore.shared.group(for: $0) }?.fallbackStrategy ?? .limited
                if midStreamFbStrategy == .always {
                    logger.error("🔀STREAM always-strategy, skipping autoRetry — direct group fallback: \(streamError.localizedDescription)")
                    if let eid = activeEntryId, let entry = ProviderConfigStore.shared.entry(for: eid) {
                        let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
                        fallbackReasons.append((model: entry.model.displayName, instance: inst, reason: streamError.fallbackReason))
                    }
                    // Re-resync after the await above — another task may have
                    // mutated `messages` during the MainActor.run suspension.
                    guard let resynced = messages.firstIndex(where: { $0.id == runMsgId }) else {
                        logger.error("🔀STREAM always-strategy: assistant message id=\(runMsgId) vanished post-await (count=\(messages.count)) — aborting fallback")
                        throw streamError
                    }
                    msgIdx = resynced
                    streamResult = try await streamWithGroupFallbackUntilContent(
                        provider: provider,
                        messages: applyRequestImageBudget(effectiveAgentHistory()),
                        baseSystemPrompt: baseSystemPrompt,
                        systemPrompt: userSystemPrompt,
                        tools: tools,
                        model: activeModel,
                        lastContextTokens: turnUsage.latestContextTokens,
                        chatMessage: messages[msgIdx],
                        msgIdx: msgIdx,
                        activeGroupId: &activeGroupId,
                        activeEntryId: &activeEntryId,
                        onStreamOpened: onContextUsageStreamOpened
                    )
                    await applyFallbackSwitch()
                } else {
                    // Re-resync after the MainActor.run above before the next
                    // messages[msgIdx] read in the retry call.
                    guard let resynced = messages.firstIndex(where: { $0.id == runMsgId }) else {
                        logger.error("🔁STREAM autoRetry path: assistant message id=\(runMsgId) vanished post-await (count=\(messages.count)) — aborting retry")
                        throw streamError
                    }
                    msgIdx = resynced
                    do {
                        let retryStream = try await streamWithAutoRetry(
                            provider: provider,
                            messages: applyRequestImageBudget(effectiveAgentHistory()),
                            systemPrompt: userSystemPrompt,
                            tools: tools,
                            maxTokens: dynamicMaxTokens(provider: provider, model: activeModel, lastContextTokens: turnUsage.latestContextTokens),
                            chatMessage: messages[msgIdx],
                            onStreamOpened: onContextUsageStreamOpened
                        )
                        let retryResult = try await processStreamEvents(
                            stream: retryStream,
                            msgIdx: msgIdx,
                            provider: provider
                        )
                        // If the retried stream is also empty, the provider is persistently
                        // failing (e.g. Anthropic overloaded).  Trigger group fallback.
                        if isEmptyResponse(retryResult) {
                            logger.error("🔁STREAM autoRetry also returned empty — triggering group fallback")
                            throw LLMError.providerError(message: "Server is overloaded")
                        }
                        streamResult = retryResult
                    } catch let retryError as LLMError where retryError.isFallbackable || retryError.isRetryable {
                        // Auto-retry exhausted or still empty — attempt group fallback.
                        logger.error("🔀STREAM retries exhausted, attempting group fallback: \(retryError.localizedDescription)")
                        if let eid = activeEntryId, let entry = ProviderConfigStore.shared.entry(for: eid) {
                            let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
                            fallbackReasons.append((model: entry.model.displayName, instance: inst, reason: retryError.fallbackReason))
                        }
                        // Resync before mutating — same rationale as outer catch.
                        if let resynced = messages.firstIndex(where: { $0.id == runMsgId }) {
                            msgIdx = resynced
                        } else {
                            logger.error("🔀STREAM retry-exhausted catch: assistant message id=\(runMsgId) gone (count=\(messages.count)) — aborting fallback")
                            throw retryError
                        }
                        await MainActor.run {
                            guard msgIdx < messages.count else { return }
                            // [T-ios-stream-retry-text-disappear] Same committed-tail
                            // guard as the outer catch — preserve persisted prior-round
                            // blocks, clear only the failed in-flight tail.
                            Self.clearUncommittedStreamTail(messages[msgIdx], committedBlockCount: committedBlockCount)
                            messages[msgIdx].streamInterruptCount += 1
                        }
                        // Re-resync after MainActor.run before the messages[msgIdx]
                        // read below — see outer catch for rationale.
                        guard let resynced2 = messages.firstIndex(where: { $0.id == runMsgId }) else {
                            logger.error("🔀STREAM retry-exhausted fallback: assistant message id=\(runMsgId) vanished post-await (count=\(messages.count)) — aborting")
                            throw retryError
                        }
                        msgIdx = resynced2
                        // Use streamWithGroupFallbackUntilContent to keep cycling through
                        // group entries until one returns non-empty content.
                        streamResult = try await streamWithGroupFallbackUntilContent(
                            provider: provider,
                            messages: applyRequestImageBudget(effectiveAgentHistory()),
                            baseSystemPrompt: baseSystemPrompt,
                            systemPrompt: userSystemPrompt,
                            tools: tools,
                            model: activeModel,
                            lastContextTokens: turnUsage.latestContextTokens,
                            chatMessage: messages[msgIdx],
                            msgIdx: msgIdx,
                            activeGroupId: &activeGroupId,
                            activeEntryId: &activeEntryId,
                            onStreamOpened: onContextUsageStreamOpened
                        )
                        await applyFallbackSwitch()
                    }
                }
            }

            // await 表示等待异步操作完成，这里是等待流处理完成并返回结果。
            // 异步指的是在后台线程执行的操作，不会阻塞主线程，允许其他操作继续进行。

            let streamEnd = Date()
            let assistantText = streamResult.assistantText
            let toolEntries = streamResult.toolEntries
            let stopReason = streamResult.stopReason
            turnUsage = streamResult.turnUsage
            await recordContextUsage(
                streamResult.turnUsage,
                initialEntryId: contextUsageInitialEntryId,
                streamEntryId: contextUsageStreamEntryId,
                streamConfigRevision: contextUsageStreamConfigRevision,
                identities: contextUsageIdentities,
                requestRevision: contextUsageRevision
            )
            logger.info("📐 Context after API: latestContextTokens=\(turnUsage.latestContextTokens) (in:\(turnUsage.inputTokens) cache_read:\(turnUsage.cacheReadTokens) cache_create:\(turnUsage.cacheCreationTokens))")

            // Track session-level token stats
            let iterationStreamDuration = streamEnd.timeIntervalSince(iterationStreamStart)
            let iterUsage = streamResult.turnUsage
            sessionInputTokens += iterUsage.inputTokens
            sessionOutputTokens += iterUsage.outputTokens
            sessionCacheReadTokens += iterUsage.cacheReadTokens
            sessionCacheWriteTokens += iterUsage.cacheCreationTokens
            if iterationStreamDuration > 0 && iterUsage.outputTokens > 0 {
                sessionStreamDuration += iterationStreamDuration
                sessionStreamOutputTokens += iterUsage.outputTokens
            }
            #if DEBUG
            iterationUsage = streamResult.iterationUsage
            #endif

            // Flush any throttled text delta that hasn't been pushed to the UI yet.
            // Find the last text block (processStreamEvents may have left un-flushed text).
            // Must also update cachedMarkdown — the render path uses it when present,
            // so stale cachedMarkdown causes the final tokens to not display.
            // Guard msgIdx again — messages may have been mutated during streaming.
            if !assistantText.isEmpty, msgIdx >= 0, msgIdx < messages.count,
               let textBlockIdx = messages[msgIdx].blocks.indices.last(where: { messages[msgIdx].blocks[$0].kind == .text }),
               messages[msgIdx].blocks[textBlockIdx].content != assistantText {
                // [DIAG-FINAL-1] Final text flush — this is the last chance to push
                // content to the UI before streaming ends. If this is skipped or
                // deferred (e.g. streamingUIUpdatesSuspended), the cell stays empty.
                logger.info("[StreamEnd] FINAL FLUSH text len=\(assistantText.count) blockContent len=\(messages[msgIdx].blocks[textBlockIdx].content.count) uiSuspended=\(streamingUIUpdatesSuspended) appState=\(UIApplication.shared.applicationState.rawValue)")
                setStreamingTextBlockContent(
                    msgIdx: msgIdx,
                    blockIdx: textBlockIdx,
                    text: assistantText,
                    parsedMarkdown: MarkdownContent(prepareMarkdownForRender(assistantText)),
                    cacheAttributedString: true,
                    requestScroll: true
                )
            } else if !assistantText.isEmpty, msgIdx >= 0, msgIdx < messages.count {
                // [DIAG-FINAL-2] Text already matches — no flush needed.
                // But if the cell is visually empty despite content being set,
                // it means SwiftUI/UIKit didn't re-render after the last @Published update.
                let textBlockIdx = messages[msgIdx].blocks.indices.last(where: { messages[msgIdx].blocks[$0].kind == .text })
                let blockContent = textBlockIdx.map { messages[msgIdx].blocks[$0].content } ?? "<no text block>"
                logger.info("[StreamEnd] SKIP FLUSH — content already matches. text len=\(assistantText.count) blockContent len=\(blockContent.count) hasCachedAttr=\(textBlockIdx.map { messages[msgIdx].blocks[$0].cachedAttributedString != nil } ?? false) hasCachedMD=\(textBlockIdx.map { messages[msgIdx].blocks[$0].cachedMarkdown != nil } ?? false)")
            } else if assistantText.isEmpty {
                // [DIAG-FINAL-3] No assistant text at all — tool-only response.
                logger.info("[StreamEnd] NO TEXT — tool-only response, nothing to flush")
            }

            // Auto-play: scan assistant text for audio URLs with ?auto_play=true
            // This works even when the app is in the background (e.g. Shortcuts intent)
            // because it triggers GlobalAudioPlayer directly, bypassing UI rendering.
            Self.triggerAutoPlayAudio(in: assistantText)

            #if DEBUG
            logger.debug("📊 Turn usage — in: \(turnUsage.inputTokens), out: \(turnUsage.outputTokens), cache_create: \(turnUsage.cacheCreationTokens), cache_read: \(turnUsage.cacheReadTokens)")
            let elapsed = Int(Date().timeIntervalSince(iterationStart) * 1000)
            LastAPIRequestBody.shared.updateLatest(
                usage: CapturedUsage(
                    inputTokens: iterationUsage.inputTokens,
                    outputTokens: iterationUsage.outputTokens,
                    cacheCreationTokens: iterationUsage.cacheCreationTokens,
                    cacheReadTokens: iterationUsage.cacheReadTokens
                ),
                durationMs: elapsed
            )
            #endif

            // Generate session title early — after first LLM response (text or tool call)
            generateSessionTitleIfNeeded(toolEntries: toolEntries.map { (name: $0.name, args: $0.args) })

            // Re-check bounds — messages may have been mutated during streaming.
            guard msgIdx >= 0, msgIdx < messages.count else {
                logger.error("⚠️ Agent loop: msgIdx \(msgIdx) out of bounds after streaming, breaking")
                hitTurnLimit = false
                break
            }

            // Flush any deferred UI updates so block.content is up-to-date before
            // we read it for persistence. Without this, content deferred due to
            // streamingUIUpdatesSuspended would be lost from the saved message.
            flushDeferredStreamingTextUpdateIfNeeded()

            // Build assistant content for agentHistory — only new blocks from this iteration
            var assistantParts: [AgentContentPart] = []
            let allBlocks = messages[msgIdx].blocks
            for i in min(committedBlockCount, allBlocks.count)..<allBlocks.count {
                let block = allBlocks[i]
                if case .text = block.kind {
                    // Prefer the fully-accumulated assistantText over block.content for the
                    // LAST text block — block.content may be stale due to throttled UI updates.
                    let isLastTextBlock = !allBlocks[(i+1)..<allBlocks.count].contains(where: { $0.kind == .text })
                    let content = (isLastTextBlock && assistantText.count > block.content.count)
                        ? assistantText : block.content
                    if !content.isEmpty {
                        assistantParts.append(.text(content))
                        // Also fix up the block so UI and persistence stay in sync
                        if content.count > block.content.count {
                            block.content = content
                        }
                    }
                }
            }
            for tu in toolEntries {
                assistantParts.append(.toolUse(id: tu.id, name: tu.name, input: tu.args))
            }
            self.prevCommittedBlockCount = self.committedBlockCount
            committedBlockCount = allBlocks.count
            self.committedBlockCount = committedBlockCount
            var assistantMessage = AgentMessage(role: .assistant, parts: assistantParts)
            assistantMessage.isInterrupted = streamResult.isStreamInterrupted
            assistantMessage.reasoningContent = streamResult.reasoningContent
            assistantMessage.reasoningEcho = streamResult.reasoningEcho
            let assistantAgentIdx = agentHistory.count
            agentHistory.append(assistantMessage)

            // Snapshot state for cache keep-alive warmup requests.
            // Phase B: must use effectiveAgentHistory so the keep-alive prefix matches
            // what we actually send to Anthropic (summary-prepended view).
            if provider is AnthropicAgentProvider, let sid = sessionId {
                keepAliveHistory = effectiveAgentHistory()
                keepAliveSystemPrompt = userSystemPrompt
                keepAliveTools = tools
                keepAliveEntry = ProviderConfigStore.shared.entry(for: activeEntryId ?? "")
                logger.info("🔥 cache keep-alive: snapshot updated — session=\(sid.prefix(8)) history=\(self.agentHistory.count) tools=\(tools.count) sysPromptLen=\(userSystemPrompt.count) enhancedCache=\(self.enhancedCacheEnabled) cacheRead=\(turnUsage.cacheReadTokens) cacheCreate=\(turnUsage.cacheCreationTokens)")
                CacheKeepAliveManager.shared.recordRequest(sessionId: sid, vm: self)
            }

            // Build thoughtSignature map from tool entries for persistence
            var sigMap: [String: String] = [:]
            for tu in toolEntries {
                if let sig = tu.metadata?.thoughtSignature { sigMap[tu.id] = sig }
            }

            // If no tool uses, this turn is done — persist and break.
            guard !toolEntries.isEmpty else {
                logger.info("Agent loop ending — no tool calls. stopReason=\(String(describing: stopReason))")

                // [T-ios-stale-resume-banner] This turn produced a complete
                // assistant reply, so the conversation is no longer in an
                // interrupted/resumable state. canResume is only cleared at the
                // send/retry ENTRY points — if an earlier turn in this session
                // set it true (a prior interruption, a Stop, a transient empty
                // response) and was then continued, a normally-finished turn
                // never reset it, leaving the "Interrupted — tap Resume" banner
                // dangling under a fully-answered message (seen on the weibo
                // hot-search turn). Clear it here; the genuinely-incomplete
                // sub-cases below re-set it to true.
                canResume = false

                // Surface unexpected stops: nil stopReason or maxTokens with no text
                if stopReason == nil {
                    logger.warning("Agent loop ended with nil stopReason (stream closed unexpectedly)")
                    // [T-stream-drop-silent] A nil stopReason on the no-tool exit
                    // means the SSE ended WITHOUT the server sending a terminal
                    // finish_reason/message_stop — the stream returned instead of
                    // throwing (a mid-flight throw would go through the fallback/
                    // retry path, not here). This is an abnormal interruption, not a
                    // normal completion: a normally-finished turn always carries a
                    // concrete stopReason (endTurn/stop/…). Previously we only
                    // surfaced this when the text was empty, so a *partial* reply
                    // (bytes arrived, then the connection dropped on weak/handoff
                    // cellular — the "断流无提示" report) was persisted silently as if
                    // complete. Surface BOTH sub-cases now with a Resume entry, and
                    // distinguish the wording so a partial reply reads as truncated
                    // rather than empty.
                    if assistantText.isEmpty {
                        messages[msgIdx].error = AppLocalized("Response ended unexpectedly (no content received)")
                    } else {
                        messages[msgIdx].error = AppLocalized("The connection dropped — this reply may be incomplete. Tap Resume to continue.")
                    }
                    canResume = true
                } else if stopReason == .maxTokens {
                    logger.warning("Agent loop ended at max_tokens with no tool calls")
                    messages[msgIdx].error = AppLocalized("Response truncated (max tokens reached)")
                    canResume = true
                } else if stopReason == .refusal {
                    // [T-ios-fable5-empty-response] Anthropic safety classifier declined the
                    // request (HTTP 200, stop_reason="refusal", input tokens billed, empty
                    // content). On Fable 5 this fires as a false-positive on ordinary turns
                    // that carry the large Claude Code agentic system prompt + tool set — the
                    // exact reason the model detail page's Quick Test (no system prompt, no
                    // tools) succeeds while a real conversation returns empty. Retrying the
                    // identical request just gets declined again, so we surface it directly
                    // and steer the user to switch models rather than looping.
                    logger.warning("Agent loop ended with stop_reason=refusal — model declined the request")
                    messages[msgIdx].error = AppLocalized("The model declined to respond to this request. Try rephrasing, or switch to a different model.")
                    canResume = true
                } else if stopReason == .endTurn && assistantText.isEmpty
                            && (streamResult.reasoningContent ?? "").isEmpty {
                    // Empty endTurn that survived all upstream retries — typically
                    // OpenAI gpt-5.5 on long contexts returning `finish_reason=stop`
                    // with no text/tool/reasoning. Surface it instead of silently
                    // dropping (ChatStore's empty-assistant filter would otherwise
                    // erase the row entirely).
                    logger.warning("Agent loop ended at endTurn with empty content")
                    // [T-error-persist-ios] If the context is nearly full, the empty
                    // response is most likely a context-overflow symptom — steer the
                    // user toward compacting rather than a blind retry.
                    // Re-fetch the entry from the store: `entry` was captured at
                    // loop start, so a context-window edit made during a long
                    // agent run would otherwise judge by the stale value here.
                    let freshModel = ProviderConfigStore.shared.entry(for: entry.id)?.model ?? entry.model
                    let maxCtx = effectiveContextWindow(for: freshModel)
                    let curCtx = estimateContextTokens()
                    if maxCtx > 0 && curCtx > Int(Double(maxCtx) * 0.7) {
                        messages[msgIdx].error = AppLocalized("The model returned an empty response. The conversation context may be too large — try compacting or starting a new session.")
                    } else {
                        messages[msgIdx].error = AppLocalized("Model returned an empty response. Please try again or switch models.")
                    }
                    canResume = true
                }

                // Flush any remaining unspoken text (streaming TTS already spoke most sentences)
                let remainingSpeak: String
                if streamResult.spokenTextOffset < streamResult.assistantText.count {
                    let startIdx = streamResult.assistantText.index(streamResult.assistantText.startIndex, offsetBy: streamResult.spokenTextOffset)
                    remainingSpeak = String(streamResult.assistantText[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    remainingSpeak = ""
                }
                if !remainingSpeak.isEmpty { speakQueued(remainingSpeak) }
                let interruptCount = await MainActor.run { messages[msgIdx].streamInterruptCount }
                let uiBlockCount = await MainActor.run { msgIdx < messages.count ? messages[msgIdx].blocks.count : -1 }
                logger.info("[BlocksLost] PERSIST final (no-tool) sid=\(sessionId?.prefix(8) ?? "nil") agentParts=\(assistantMessage.parts.count) uiBlocks=\(uiBlockCount)")
                if turnCount > 0 && streamResult.assistantText.count < 10 {
                    // [T-log-noise-privacy 2026-07-18] Content excerpt dropped —
                    // the char count + token counts carry the diagnostic signal.
                    logger.warning("[ModelDiag] SUSPICIOUS short final text after \(turnCount) tool turn(s): \(streamResult.assistantText.count) chars, sid=\(sessionId?.prefix(8) ?? "nil") outputTokens=\(turnUsage.outputTokens) contextTokens=\(turnUsage.latestContextTokens ?? 0)")
                }
                // [T-token-attribution-snapshot] activeEntryId is the entry that
                // actually served this turn — failover reassigns it in place, so
                // it names the backup model when one took over. Passing it here
                // (rather than letting the persist layer look up the session) is
                // what keeps attribution correct across a silent switch.
                if let persistedId = await persistAgentMessage(assistantMessage, tokenUsage: turnUsage, thoughtSignatures: sigMap, streamInterruptCount: interruptCount, modelEntryId: activeEntryId),
                   assistantAgentIdx < agentHistory.count {
                    agentHistory[assistantAgentIdx].dbMessageId = persistedId
                    // [T-error-persist-ios] Persist this turn's error state AFTER the
                    // row exists + dbMessageId is assigned, keyed by that id, so the
                    // indicator survives reload. Write UNCONDITIONALLY (incl. nil) so a
                    // successful (re)stream CLEARS a previously-persisted error rather
                    // than leaving the stale one in the DB (retry-then-succeed, edge #5).
                    if msgIdx < messages.count {
                        await ChatStore.shared.updateMessageErrorInfo(messageId: persistedId, errorInfo: messages[msgIdx].error)
                    }
                }
                hitTurnLimit = false

                // [T-ios-queued-message-continues-prev-turn] The current turn's
                // tool loop has fully converged (no tool calls this iteration) and
                // its final assistant reply is now persisted. If the user queued a
                // message mid-run, NOW inject it as a clean standalone user turn and
                // keep looping so the model produces a dedicated response — instead
                // of the old mid-loop drain that folded it into a tool_result and
                // made it read as in-loop context for this turn. Errors above
                // (canResume true) still inject: the user's new message takes
                // precedence over a stale interrupted-banner from this finished turn.
                if await injectQueuedPromptsAsNewTurn(
                    msgIdx: &msgIdx,
                    committedBlockCount: &committedBlockCount,
                    turnUsage: turnUsage
                ) {
                    // We're continuing with the user's new turn, so this session is
                    // no longer in an interrupted/resumable state. Reset per-turn
                    // usage for the fresh assistant message.
                    // [T-ios-inloop-compact-freeze] msgIdx now points at the fresh
                    // assistant message — retarget the stable anchor with it.
                    if msgIdx < messages.count {
                        webReadService.endRequest(scope: requestScope)
                        webSearchService.endRequest(scope: requestScope)
                        requestScope = scopeForUserRequest(anchoredAt: msgIdx)
                        runMsgId = messages[msgIdx].id
                    }
                    canResume = false
                    turnUsage = TokenUsage()
                    continue
                }
                break
            }

            // Build assistant RawMessage now but defer DB write until tool results
            // are ready, so both can be persisted in a single SQLite transaction.
            let deferredAssistantRaw = await buildRawMessage(assistantMessage, thoughtSignatures: sigMap)
            // Phase B: write the DB id back into agentHistory immediately — even though
            // we defer the actual appendMessages to batch with the tool results below,
            // the id is deterministic and compact lookups rely on it.
            if let raw = deferredAssistantRaw, assistantAgentIdx < agentHistory.count {
                agentHistory[assistantAgentIdx].dbMessageId = raw.id
            }
            // Flush any remaining unspoken text (streaming TTS already spoke most sentences)
            do {
                let remainingSpeak: String
                if streamResult.spokenTextOffset < streamResult.assistantText.count {
                    let startIdx = streamResult.assistantText.index(streamResult.assistantText.startIndex, offsetBy: streamResult.spokenTextOffset)
                    remainingSpeak = String(streamResult.assistantText[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    remainingSpeak = ""
                }
                if !remainingSpeak.isEmpty { speakQueued(remainingSpeak) }
            }

            // Execute each tool use and collect results
            var toolResultParts: [AgentContentPart] = []
            var pendingSnapshots: [String: (toolName: String, snapshot: ToolSnapshot)] = [:]
            var cancelledDuringToolExecution = false
            let webReadBatchEnteredAt = Date()
            let containsWebRead = toolEntries.contains { $0.name == "web_read" }
            let containsWebSearch = toolEntries.contains { $0.name == "web_search" }
            let webReadBatchID = containsWebRead ? UUID().uuidString.lowercased() : nil
            let webReadScope: WebReadScope? = containsWebRead ? requestScope : nil
            let webReadDeadline = containsWebRead
                ? webReadBatchEnteredAt.addingTimeInterval(webReadService.configuration.totalTimeout)
                : nil
            let webSearchBatchID = containsWebSearch ? UUID().uuidString.lowercased() : nil
            let webSearchScope: WebReadScope? = containsWebSearch ? requestScope : nil
            let webSearchDeadline = containsWebSearch
                ? webReadBatchEnteredAt.addingTimeInterval(webSearchService.configuration.totalTimeout)
                : nil
            if let webReadBatchID, let webReadScope {
                activeWebReadBatchID = webReadBatchID
                webReadService.beginBatch(id: webReadBatchID, sessionID: webReadScope.sessionID, scope: webReadScope)
            }
            if let webSearchBatchID, let webSearchScope {
                activeWebSearchBatchID = webSearchBatchID
                webSearchService.beginBatch(id: webSearchBatchID, sessionID: webSearchScope.sessionID, scope: webSearchScope)
            }

            // Image budget for this batch of tool results.
            //
            // Was: `kImageContextKeepCount - existingImages` (double-count with
            // trimOldImagesFromHistory). When trim left agentHistory near the
            // 20-image cap, a fan-out batch of 5+ read_image calls would race
            // for the few remaining slots and emit text placeholders for the
            // losers — even though the next turn's trim would have evicted
            // the old images anyway. Net effect: concurrent read_image
            // silently lost frames for the user.
            //
            // Now: budget the full `kImageContextKeepCount` per batch. The
            // single-turn cap is still 20 (worst case), and
            // trimOldImagesFromHistory() at the top of the next turn handles
            // historical pressure. [T-image-budget-double-count]
            let imageBudgetActor = BatchImageBudget(initial: Self.kImageContextKeepCount)

            #if DEBUG
            // [T-ios-concurrent-toolcall-dup-id] Per-batch dispatch trace —
            // logs each tool_use's full id + blockIdx so we can see whether
            // parallel calls share ids or have collisions on toolUseId
            // when the cancel-bubble bug reproduces.
            let _batchBlockCount = (msgIdx >= 0 && msgIdx < self.messages.count) ? self.messages[msgIdx].blocks.count : -1
            logger.info("[ConcurrentTools] BATCH START — entries=\(toolEntries.count) msgIdx=\(msgIdx) blocks=\(_batchBlockCount)")
            for (idx, tu) in toolEntries.enumerated() {
                logger.info("[ConcurrentTools]   DISPATCH [\(idx)] tu.id=\(tu.id) name=\(tu.name) blockIdx=\(tu.blockIdx)")
            }
            // toolUseId collision check across blocks in this assistant msg
            if msgIdx < self.messages.count {
                var seen: [String: Int] = [:]
                for blk in self.messages[msgIdx].blocks {
                    guard let tid = blk.toolUseId else { continue }
                    seen[tid, default: 0] += 1
                }
                let dupes = seen.filter { $0.value > 1 }
                if !dupes.isEmpty {
                    logger.error("[ToolUseId] COLLISION! Duplicate toolUseId across blocks: \(dupes)")
                }
            }
            #endif

            // Reset the global stop-signal once for the whole batch.
            // Concurrent tool tasks (below) only READ this flag; resetting
            // inside any single task would race-clear a stop initiated for
            // a sibling. [T-concurrent-tools 2026-05-25]
            commandCancelledByUser = false

            // Concurrent tool dispatch with maxConcurrentTools in-flight cap.
            // Anthropic requires tool_result blocks in the same order as
            // the originating tool_use blocks, so we tag each child task
            // with its source index and stitch results back in order after
            // every task completes.
            let toolsSnapshot = tools
            var outcomesByIndex: [Int: ToolExecOutcome] = [:]
            await withTaskGroup(of: (Int, ToolExecOutcome).self) { group in
                var added = 0
                var harvested = 0
                for (idx, tu) in toolEntries.enumerated() {
                    // Rate-limit: hold here until we're below the in-flight cap.
                    while added - harvested >= Self.maxConcurrentTools {
                        if let pair = await group.next() {
                            outcomesByIndex[pair.0] = pair.1
                            harvested += 1
                        } else {
                            break
                        }
                    }
                    logger.info("[ToolLifecycle] DISPATCHED toolId=\(tu.id.prefix(20)) tool=\(tu.name) sid=\(self.sessionId?.prefix(8) ?? "nil") appState=\(UIApplication.shared.applicationState == .active ? "fg" : "bg") suspended=\(self.streamingUIUpdatesSuspended) isProcessing=\(self.isProcessing)")
                    group.addTask { [weak self] in
                        guard let self else {
                            // Self torn down mid-batch: keep anonymous web payloads parseable.
                            let cancelMsg = tu.name == "web_search"
                                ? WebSearchService.immediateOutcome(
                                    query: tu.args["query"] as? String ?? "",
                                    status: .cancelled,
                                    limitation: "会话在搜索期间结束。"
                                ).json
                                : tu.name == "web_read"
                                ? await WebReadService.immediateOutcome(
                                    request: WebReadRequest(url: tu.args["url"] as? String),
                                    status: .cancelled, limitation: "会话在读取期间结束。"
                                ).json
                                : "<system-reminder>The session was torn down before this tool could execute.</system-reminder>"
                            return (idx, ToolExecOutcome(
                                toolId: tu.id, toolName: tu.name,
                                resultPart: .toolResult(id: tu.id, name: tu.name, content: cancelMsg, isError: tu.name != "web_read" && tu.name != "web_search"),
                                snapshotEntry: nil, snapshotItem: nil, cancelled: true
                            ))
                        }
                        let outcome = await self.executeSingleToolUse(
                            tu: tu, msgIdx: msgIdx, tools: toolsSnapshot, batchBudget: imageBudgetActor,
                            webReadBatchID: webReadBatchID, webReadScope: webReadScope,
                            webReadDeadline: webReadDeadline,
                            webSearchBatchID: webSearchBatchID, webSearchScope: webSearchScope,
                            webSearchDeadline: webSearchDeadline
                        )
                        return (idx, outcome)
                    }
                    added += 1
                }
                // Drain the remainder.
                for await pair in group {
                    outcomesByIndex[pair.0] = pair.1
                    harvested += 1
                }
            }
            if let webReadBatchID {
                webReadService.finishBatch(id: webReadBatchID)
                if activeWebReadBatchID == webReadBatchID {
                    activeWebReadBatchID = nil
                }
            }
            if let webSearchBatchID {
                webSearchService.finishBatch(id: webSearchBatchID)
                if activeWebSearchBatchID == webSearchBatchID {
                    activeWebSearchBatchID = nil
                }
            }

            // Stitch outcomes back in original tool_use order so the
            // tool_result blocks pair correctly with the assistant
            // message's tool_use blocks for the next API call.
            for idx in 0..<toolEntries.count {
                guard let outcome = outcomesByIndex[idx] else { continue }
                toolResultParts.append(outcome.resultPart)
                if let se = outcome.snapshotEntry {
                    pendingSnapshots[outcome.toolId] = se
                }
                if let si = outcome.snapshotItem {
                    toolSnapshots.append(si)
                }
                if outcome.cancelled {
                    cancelledDuringToolExecution = true
                }
            }

            // If any tool images were stripped due to budget, append a batch-reading tip
            let strippedImageCount = await imageBudgetActor.strippedSoFar
            if strippedImageCount > 0 {
                toolResultParts.append(.text(
                    "<system-reminder>\(strippedImageCount) image(s) from read_image were replaced with text placeholders"
                    + " because the context image limit (\(Self.kImageContextKeepCount)) was reached."
                    + " Summarize your findings so far, then use read_image again"
                    + " to view the remaining images in a new batch.</system-reminder>"
                ))
            }

            // Add tool results as a user message
            let toolResultMessage = AgentMessage(role: .user, parts: toolResultParts)
            logger.info("Appending tool result message with \(toolResultParts.count) part(s) to agentHistory (now \(self.agentHistory.count + 1) messages)")
            let toolResultAgentIdx = agentHistory.count
            agentHistory.append(toolResultMessage)

            // Collect terminal tool statuses from the assistant blocks so persistence can
            // distinguish failed vs cancelled (both have success == false).
            var toolStatusStrings: [String: String] = [:]
            if msgIdx < messages.count {
                for block in messages[msgIdx].blocks {
                    guard let id = block.toolUseId, let status = block.toolStatus else { continue }
                    switch status {
                    case .success: toolStatusStrings[id] = "success"
                    case .failed: toolStatusStrings[id] = "failed"
                    case .cancelled: toolStatusStrings[id] = "cancelled"
                    case .streaming, .running: break
                    }
                }
            }

            // Batch-persist the deferred assistant message + tool results in one transaction
            let uiBlockCountMid = await MainActor.run { msgIdx < messages.count ? messages[msgIdx].blocks.count : -1 }
            logger.info("[BlocksLost] PERSIST mid-loop (tool) sid=\(sessionId?.prefix(8) ?? "nil") agentParts=\(assistantMessage.parts.count) uiBlocks=\(uiBlockCountMid)")
            if let toolResultRaw = await buildRawMessage(toolResultMessage, snapshots: pendingSnapshots, toolStatuses: toolStatusStrings) {
                var batch: [RawMessage] = []
                if let assistantRaw = deferredAssistantRaw { batch.append(assistantRaw) }
                batch.append(toolResultRaw)
                await ChatStore.shared.appendMessages(batch)
                // Phase B: write the DB id back into agentHistory entries so compact
                // can resolve boundaries by id.
                if toolResultAgentIdx < agentHistory.count {
                    agentHistory[toolResultAgentIdx].dbMessageId = toolResultRaw.id
                }
            } else if let assistantRaw = deferredAssistantRaw {
                await ChatStore.shared.appendMessage(assistantRaw)
                // (assistantAgentIdx was already populated above via deferredAssistantRaw path)
            }

            // Signal that tools are done and we're waiting for the model's next response.
            guard msgIdx < messages.count else { break }
            messages[msgIdx].isAwaitingModelResponse = true

            // If user cancelled during tool execution, commit everything and stop.
            // History is now properly paired: assistant(tool_use) + user(tool_result).
            if cancelledDuringToolExecution || self.userDidCancel {
                logger.info("⏹️ User cancelled during tool execution — committed \(toolResultParts.count) tool result(s), stopping agent loop")
                self.prevCommittedBlockCount = self.committedBlockCount
                committedBlockCount = messages[msgIdx].blocks.count
                self.committedBlockCount = committedBlockCount
                messages[msgIdx].usage = turnUsage
                hitTurnLimit = false
                break
            }

            // [T-ios-queued-message-interrupt-on-toolclose] If the user queued a
            // prompt while tools were running, interrupt as soon as the CURRENT
            // tool call closes (its tool_result is now built + persisted) — don't
            // keep grinding through the rest of the running plan. We break out of
            // the tool loop here; the post-loop drainQueuedPrompts() then lands the
            // queued prompt as a clean STANDALONE user turn and the model responds
            // to it next.
            //
            // Why break instead of appending inline: appending the queued user
            // message right after the tool_result lets mergeConsecutiveSameRole
            // fold it into that tool_result as a trailing text block (Anthropic
            // requires consecutive same-role messages merged), so the model read
            // it as in-loop context for the previous turn and never gave it its
            // own response (the #579 bug). Breaking → fresh turn avoids the merge
            // entirely while still inserting/un-queuing the message immediately.
            if !promptQueue.isEmpty {
                logger.info("📨[QueueInterrupt] \(self.promptQueue.count) queued prompt(s) — interrupting after current tool call to start a standalone turn")
                self.prevCommittedBlockCount = self.committedBlockCount
                committedBlockCount = messages[msgIdx].blocks.count
                self.committedBlockCount = committedBlockCount
                // injectQueuedPromptsAsNewTurn un-queues the on-screen message
                // (drops dashed border + X) so it appears inserted immediately,
                // persists it as a standalone user turn, caches the just-finished
                // assistant blocks, and starts a fresh assistant message. We then
                // `continue` so the next iteration produces a dedicated response to
                // the queued prompt — abandoning the rest of the running plan.
                if await injectQueuedPromptsAsNewTurn(
                    msgIdx: &msgIdx,
                    committedBlockCount: &committedBlockCount,
                    turnUsage: turnUsage
                ) {
                    // [T-ios-inloop-compact-freeze] Retarget the stable anchor
                    // alongside msgIdx (fresh assistant message for the new turn).
                    if msgIdx < messages.count {
                        webReadService.endRequest(scope: requestScope)
                        webSearchService.endRequest(scope: requestScope)
                        requestScope = scopeForUserRequest(anchoredAt: msgIdx)
                        runMsgId = messages[msgIdx].id
                    }
                    canResume = false
                    turnUsage = TokenUsage()
                    continue
                }
            }

            // If the background task expired while executing tools, pause here
            // until the app returns to the foreground before making the next API call.
            await waitIfBackgroundSuspended()

            // If the user activated browser takeover, pause until they're done.
            await waitIfBrowserTakeover()

            // If stop reason was end_turn (not tool_use), break
            if stopReason != .toolUse {
                // maxTokens: the model ran out of output tokens mid-response.
                // Show a warning and enable Resume so the user can continue.
                if stopReason == .maxTokens {
                    logger.warning("Agent loop stopped: max_tokens reached")
                    messages[msgIdx].error = AppLocalized("Response truncated (max tokens reached)")
                    canResume = true
                }
                // [T-stream-drop-silent] nil stopReason after tool turns means the
                // stream ended without a proper terminal event — same abnormal
                // interruption as the no-tool exit above. Surface with content-aware
                // wording + Resume instead of the old bare "ended unexpectedly".
                if stopReason == nil && toolEntries.isEmpty {
                    logger.warning("Agent loop stopped: stream ended without stop reason")
                    if assistantText.isEmpty {
                        messages[msgIdx].error = AppLocalized("Response ended unexpectedly (no content received)")
                    } else {
                        messages[msgIdx].error = AppLocalized("The connection dropped — this reply may be incomplete. Tap Resume to continue.")
                    }
                    canResume = true
                }
                hitTurnLimit = false
                break
            }
        }

        // hitTurnLimit stays true only when the while-condition itself failed
        // — meaning the model kept producing tool calls for maxAgentTurns
        // iterations straight. Surface why we stopped + arm canResume so the
        // user can continue from here. Mirrors Android ChatViewModel.
        // finalizeAtTurnLimit. (Earlier draft used `turnCount >= max` which
        // false-positived: the `defer { turnCount += 1 }` runs even on break,
        // so a happy-path break on the final allowed iteration would inflate
        // turnCount to max and slap a fake "200 turns hit" error on every
        // ordinary completion — exactly the v1.4.0-dev bug user hit.)
        if hitTurnLimit, msgIdx >= 0, msgIdx < messages.count {
            logger.warning("⚠️ runAgentLoop hit maxAgentTurns=\(Self.maxAgentTurns) — finalizing as resumable")
            messages[msgIdx].error =
                "Stopped after \(Self.maxAgentTurns) agent turns to prevent runaway tool use. " +
                "The model kept calling tools without finishing — tap Resume to continue from here, " +
                "or send a new message to start over."
            canResume = true
        }

        // Store accumulated usage on the assistant message
        guard msgIdx < messages.count else { return }
        messages[msgIdx].isAwaitingModelResponse = false
        messages[msgIdx].usage = turnUsage

        // Safety net: force-close any tool blocks still stuck in non-terminal status.
        // This can happen when stream interruptions, retries, or edge cases leave
        // tool blocks in .streaming or .running without transitioning to success/failed/cancelled.
        for block in messages[msgIdx].blocks {
            switch block.toolStatus {
            case .streaming:
                // [T-ios-concurrent-toolcall-dup-id] PRIMARY SUSPECT for the
                // concurrent cancel-bubble bug: if outcome stitching drops an
                // entry, that block stays .streaming and lands here.
                logger.warning("[SafetyNet] force-closing .streaming → .cancelled toolUseId=\(block.toolUseId ?? "nil") kind=\(block.kind) content_len=\(block.content.count)")
                block.toolStatus = .cancelled
            case .running:
                logger.warning("[SafetyNet] force-closing .running → .cancelled toolUseId=\(block.toolUseId ?? "nil") kind=\(block.kind) content_len=\(block.content.count)")
                block.toolStatus = .cancelled
            default:
                break
            }
        }

        // Cache parsed MarkdownContent and NSAttributedString on completed text blocks
        // to avoid re-parsing and re-rendering on cell recycling / SwiftUI refreshes.
        for i in messages[msgIdx].blocks.indices {
            if case .text = messages[msgIdx].blocks[i].kind, !messages[msgIdx].blocks[i].content.isEmpty {
                messages[msgIdx].blocks[i].cachedMarkdown = MarkdownContent(prepareMarkdownForRender(messages[msgIdx].blocks[i].content))
                cacheAttributedString(for: messages[msgIdx].blocks[i])
            }
        }

    }

}
