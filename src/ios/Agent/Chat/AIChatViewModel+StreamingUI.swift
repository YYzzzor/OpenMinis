//
//  AIChatViewModel+StreamingUI.swift
//  Minis - AIChatViewModel 扩展（Agent/Chat）
//
//  流式输出期间的 UI 闸门（暂停刷新、转场暂停）和流式文本写入。
//  shortFrame 是 MinisX 现有的辅助函数，跟随它的调用方放在这里。
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

    /// Single chokepoint for clearing `streamingUIUpdatesSuspended`. Sets the
    /// flag false (idempotent) and, if it actually transitioned, fires the
    /// resume hook so deferred consumers (the Coordinator snapshot) can catch
    /// up. Callers that need the VM-side deferred-text flush still call it
    /// themselves; this only owns the flag + hook.
    private func clearStreamingUIUpdatesSuspended() {
        guard streamingUIUpdatesSuspended else { return }
        streamingUIUpdatesSuspended = false
        onStreamingUIUpdatesResumed?()
        if needsSnapshotReloadOnResume {
            needsSnapshotReloadOnResume = false
            let totalBlocks = messages.reduce(0) { $0 + $1.blocks.count }
            let lastBlocks = messages.last?.blocks.count ?? 0
            logger.info("[BlocksLost] REPLAY retrySnapshot — suspend cleared. sid=\(sessionId?.prefix(8) ?? "nil") totalBlocks=\(totalBlocks) lastMsgBlocks=\(lastBlocks) msgCount=\(messages.count)")
            retrySnapshotReloadSignal.send()
        }
    }

    /// Called from AIChatView.onAppear REUSING path. When the agent loop ended
    /// while the user was away (no CollectionView subscriber), the
    /// `retrySnapshotReloadSignal` fired into the void and
    /// `needsSnapshotReloadOnResume` may still be set. The `didBecomeActive`
    /// observer only covers background→foreground; this covers the in-app
    /// navigation case (user switches between sessions while the app stays
    /// active). Sends `retrySnapshotReloadSignal` after a short delay so the
    /// newly-mounted CollectionView's `bindViewModel` subscription is already
    /// installed when the signal arrives.
    @MainActor
    func consumeDeferredSnapshotIfNeeded() {
        // [T-blockslost-defensive] Entry state is logged even when there is
        // nothing to consume — a silent no-op here is indistinguishable from
        // "flag was consumed into the void earlier" (defect ②'s signature)
        // when triaging from device logs.
        logger.info("[BlocksLost] consumeDeferred onAppear-reuse sid=\(sessionId?.prefix(8) ?? "nil") vm=\(vmInstanceId) needsFlag=\(needsSnapshotReloadOnResume)")
        guard needsSnapshotReloadOnResume else { return }
        needsSnapshotReloadOnResume = false
        let totalBlocks = messages.reduce(0) { $0 + $1.blocks.count }
        let lastBlocks = messages.last?.blocks.count ?? 0
        logger.info("[BlocksLost] REPLAY retrySnapshot — onAppear reuse consumed deferred. sid=\(sessionId?.prefix(8) ?? "nil") totalBlocks=\(totalBlocks) lastMsgBlocks=\(lastBlocks) msgCount=\(messages.count)")
        DispatchQueue.main.async { [weak self] in
            self?.retrySnapshotReloadSignal.send()
        }
    }

    /// [T-ios-scroll-suspend-leak] Compress a `Thread.callStackSymbols` frame to
    /// just the demangled Swift function name (drops the module load address,
    /// index, and image name that make raw frames unreadable in logs). Used only
    /// for the [SuspendState] transition trace.
    private static func shortFrame(_ raw: String) -> String {
        // Raw frame looks like:
        // "3   Minis   0x0000000104abcd12 $s5Minis... mangled ... + 40"
        // Prefer the human name after the mangled symbol if present, else the
        // whitespace-collapsed tail.
        let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
        // The mangled/demangled symbol is typically the 4th token onward.
        guard parts.count >= 4 else { return raw.trimmingCharacters(in: .whitespaces) }
        let symbol = parts[3...].joined(separator: " ")
        // Strip the trailing " + <offset>" and cap length.
        let trimmed = symbol.split(separator: "+").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? symbol
        return String(trimmed.prefix(80))
    }

    /// Public read so the manual `objectWillChange.send()` call sites can gate.
    var isTransitionSuspended: Bool { transitionSuspended }

    /// [T-ios-stream-publish-transition-gap] Publish unless this vm is the
    /// outgoing side of a navigation transition.
    ///
    /// Every manual `objectWillChange.send()` on a STREAMING path must go
    /// through this. The audit that added it found the mitigation only half
    /// wired: `setSuspendedForTransition` was being set correctly by both
    /// ContentView observers (4300d0a29 iPad, db9fc144f iPhone), and the four
    /// low-frequency publishers (retry / edit / cache-invalidate /
    /// thinking-level) consulted `transitionSuspended` — but the four
    /// HIGHEST-frequency ones, all in `+SSEStream.swift`, published
    /// unconditionally. Those are precisely the mutations the 2026-08-10 crash
    /// log shows still running during (and after) the hosting-view teardown:
    /// `[TOOL:STREAMING]` at 19:23:26.735 / 27.138 / 27.349 is the `:718` site,
    /// firing across a transition that completed at 27.213.
    ///
    /// Eliding is safe because a suspended vm is off-screen by construction:
    /// SwiftUI re-reads the whole model when the view is next displayed, the
    /// resume path (`setSuspendedForTransition(false)`) publishes explicitly,
    /// and the underlying `messages` mutation has already happened — only the
    /// notification is dropped, never data.
    func publishUnlessTransitioning() {
        guard !transitionSuspended else { return }
        objectWillChange.send()
    }

    /// Builds the final NSAttributedString for a completed text block and stores it
    /// on the block. Must be called on the MainActor. No-op if content is empty.
    @MainActor
    func cacheAttributedString(for block: AssistantBlock) {
        guard !block.content.isEmpty else { return }
        // [T-ios-markdown-rerender-burst] Persist the parsed MarkdownContent back
        // onto the block, not just the rendered attributed string. Previously
        // this parsed `MarkdownContent(prepared)` to render the attributed
        // string but threw the parse away, leaving `block.cachedMarkdown` nil
        // for messages loaded from DB (loadSession calls this for every text
        // block). The SelectableMarkdownView render path then re-ran cmark on
        // EVERY updateUIView — and for table-containing messages (which
        // [TablePathFix] forces through fresh render, bypassing
        // cachedAttributedString) that re-parse fired 6–12× per scroll-decel
        // second, dropping 5–8 frames. Caching the parse makes the render path
        // hit `cachedContent` (skip re-parse) AND keys its content-hash off the
        // stable `blocks.hashValue` so the per-coordinator hash-skip can land.
        // No extra work: we were already computing this MarkdownContent here.
        let content = block.cachedMarkdown ?? MarkdownContent(prepareMarkdownForRender(block.content))
        block.cachedMarkdown = content
        block.cachedAttributedString = autoreleasepool {
            renderMarkdownBlocks(content.blocks)
        }
    }

    @MainActor
    func setStreamingUIUpdatesSuspended(_ suspended: Bool) {
        guard streamingUIUpdatesSuspended != suspended else { return }
        // [T-ios-scroll-suspend-leak] Full lifecycle trace of every true↔false
        // transition. When UI/DB inconsistency is reported, this lets us see
        // whether a SUSPEND ever got a matching RESUME (the leak = a SUSPEND with
        // no RESUME before the session was switched away). `caller` is the direct
        // caller frame (scrollViewWillBeginDragging / scenePhase / openSession …).
        let caller = Thread.callStackSymbols.count > 1 ? Self.shortFrame(Thread.callStackSymbols[1]) : "?"
        logger.info("[SuspendState] \(suspended ? "SUSPEND" : "RESUME") sid=\(sessionId?.prefix(8).description ?? "nil") caller=\(caller)")
        if suspended {
            streamingUIUpdatesSuspended = true
        } else {
            // [T-ios-ui-blocks-lost-suspend-resume] Flush VM-side deferred text
            // FIRST so `messages` holds the freshest content, then clear the
            // flag + fire the resume hook so the Coordinator rebuilds any
            // snapshot it deferred during the suspend window.
            flushDeferredStreamingTextUpdateIfNeeded()
            clearStreamingUIUpdatesSuspended()
            // [T-ios-tool-status-desync] Republish so tool-status views
            // (FloatingToolBar, ToolStatusBar) pick up any toolBlocks /
            // tool_use mutations that landed while suspended. Without this,
            // @Published only fires on assignment — in-place mutations to
            // `messages` during the suspend window are invisible to
            // subscribers. Mirrors setSuspendedForTransition(false).
            objectWillChange.send()
        }
    }

    /// Gate UI invalidation while this vm is on the outgoing side of a
    /// session-switch. ContentView calls `setSuspendedForTransition(true)` on
    /// the previously-selected vm immediately before `selectedSessionId`
    /// flips, then schedules a `setSuspendedForTransition(false)` after a
    /// short delay so the next time the user comes back to this session the
    /// streaming UI catches up.
    /// See `transitionSuspended` doc-comment for the full crash motivation.
    @MainActor
    func setSuspendedForTransition(_ suspended: Bool) {
        guard transitionSuspended != suspended else { return }
        transitionSuspended = suspended
        // While transition-suspended, also keep the streaming text path in
        // defer mode. On resume, fall back to whatever explicit value the
        // scroll-suppression callers had requested (we conservatively clear,
        // since the most common case during a transition is no scroll).
        if suspended {
            streamingUIUpdatesSuspended = true
        } else {
            flushDeferredStreamingTextUpdateIfNeeded()
            // [T-ios-ui-blocks-lost-suspend-resume] Clear via the chokepoint so
            // the Coordinator's resume hook fires too (rebuilds any deferred
            // snapshot), in addition to the republish below.
            clearStreamingUIUpdatesSuspended()
            // Republish so the new (or returning) message-list binding picks
            // up the current `messages` snapshot — Published only fires on
            // assignment, so any mutations that occurred during suspend are
            // now reflected in `messages` but no subscriber has been notified.
            objectWillChange.send()
        }
    }

    @MainActor
    func setStreamingTextBlockContent(
        msgIdx: Int,
        blockIdx: Int,
        text: String,
        parsedMarkdown: MarkdownContent?,
        cacheAttributedString shouldCacheAttributedString: Bool,
        requestScroll: Bool
    ) {
        guard msgIdx >= 0, msgIdx < messages.count,
              blockIdx >= 0, blockIdx < messages[msgIdx].blocks.count else { return }
        let message = messages[msgIdx]
        let block = message.blocks[blockIdx]

        // Record the streaming flush into the hang-logger's ring buffer so
        // any main-thread stall that occurs during streaming is logged
        // together with the most recent on-screen content tail. Cheap: a
        // substring + struct push on a background queue. No-op when no
        // streaming session is currently active.
        StreamingHangLogger.shared.recordStreamingFlush(
            messageId: message.id,
            blockId: block.id,
            text: text,
            finalFlush: shouldCacheAttributedString
        )

        if streamingUIUpdatesSuspended {
            // [DIAG-SUSPEND] UI updates are suspended (e.g. tool detail sheet is presented).
            // If this is the FINAL flush (cacheAttributedString=true), the content will be
            // deferred until the sheet is dismissed. If the sheet never dismisses properly,
            // the cell stays empty.
            logger.info("[StreamText] DEFERRED — uiSuspended=true text len=\(text.count) cacheAttr=\(shouldCacheAttributedString) blockId=\(block.id)")
            let existing = deferredStreamingTextUpdates.first(where: {
                $0.messageId == message.id && $0.blockId == block.id
            })
            let mergedCacheFlag = shouldCacheAttributedString || (existing?.cacheAttributedString == true)
            let pending = DeferredStreamingTextUpdate(
                messageId: message.id,
                blockId: block.id,
                text: text,
                parsedMarkdown: parsedMarkdown,
                cacheAttributedString: mergedCacheFlag
            )
            if let existingIdx = deferredStreamingTextUpdates.firstIndex(where: {
                $0.messageId == message.id && $0.blockId == block.id
            }) {
                deferredStreamingTextUpdates[existingIdx] = pending
            } else {
                deferredStreamingTextUpdates.append(pending)
            }
            return
        }

        applyStreamingTextBlockContent(
            block,
            text: text,
            parsedMarkdown: parsedMarkdown,
            cacheAttributedString: shouldCacheAttributedString
        )
        if requestScroll && isNearBottom {
            scrollToBottomSignal.send()
        }
    }

    @MainActor
    private func applyStreamingTextBlockContent(
        _ block: AssistantBlock,
        text: String,
        parsedMarkdown: MarkdownContent?,
        cacheAttributedString shouldCacheAttributedString: Bool
    ) {
        let wasEmpty = block.content.isEmpty
        block.content = text
        if let parsedMarkdown {
            block.cachedMarkdown = parsedMarkdown
        } else if block.cachedMarkdown == nil {
            block.cachedMarkdown = MarkdownContent(prepareMarkdownForRender(text))
        }
        if shouldCacheAttributedString {
            cacheAttributedString(for: block)
        }
        // When content transitions from empty to non-empty, signal the collection
        // view to reconfigure the cell. UIHostingConfiguration doesn't always
        // trigger preferredLayoutAttributesFitting when the SwiftUI body changes
        // from emitting nothing (EmptyView) to emitting content — the cell can
        // stay at ~0 height indefinitely without this explicit nudge.
        if wasEmpty && !text.isEmpty,
           let message = messages.first(where: { $0.blocks.contains(where: { $0.id == block.id }) }) {
            let prefix = String(text.prefix(30))
            let blockIdx = message.blocks.firstIndex(where: { $0.id == block.id }) ?? -1
            let prevBlockKind: String = blockIdx > 0 ? "\(message.blocks[blockIdx - 1].kind)" : "none"
            logger.info("[TextDrift] empty→filled blockIdx=\(blockIdx) prevBlockKind=\(prevBlockKind) len=\(text.count) text=\"\(prefix)\"")
            blockContentFilledSignal.send((messageId: message.id, blockId: block.id))
        }
    }

    @MainActor
    func flushDeferredStreamingTextUpdateIfNeeded() {
        guard !deferredStreamingTextUpdates.isEmpty else { return }
        let pendingUpdates = deferredStreamingTextUpdates
        deferredStreamingTextUpdates.removeAll()
        for pending in pendingUpdates {
            guard let message = messages.first(where: { $0.id == pending.messageId }),
                  let block = message.blocks.first(where: { $0.id == pending.blockId }) else { continue }
            applyStreamingTextBlockContent(
                block,
                text: pending.text,
                parsedMarkdown: pending.parsedMarkdown,
                cacheAttributedString: pending.cacheAttributedString
            )
        }
        if isNearBottom {
            scrollToBottomSignal.send()
        }
    }

}
