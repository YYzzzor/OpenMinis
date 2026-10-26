//
//  MessageListV3Coordinator+Scroll.swift
//  Minis - V3 聊天消息列表（Agent/MessageList/CollectionViewMessageListV3）
//
//  滚动状态、跳转、底部固定、不足视口时的 inset 补偿。
//
//  文件地图与拆分规则：CollectionViewMessageListV3.swift（本目录）。
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Scroll


        /// Whether a list item is part of the given assistant message's span
        /// (block or footer — the header is the span's start, matched
        /// separately). [T-stream-hover-earlier-streaming]
        static func item(_ item: MessageListItem, belongsTo messageId: UUID) -> Bool {
            switch item {
            case .assistantBlock(let mid, _): return mid == messageId
            case .assistantFooter(let mid): return mid == messageId
            case .wholeMessage, .assistantHeader: return false
            }
        }

        func isNearBottom() -> Bool {
            return isWithinBottom(nearBottomThreshold)
        }

        /// True when the viewport is at (or within `threshold` of) the very top
        /// of the content — the first message's top is showing. Drives the
        /// up-button's hide: once the user has walked all the way up, there's
        /// nowhere further to jump. The top resting offset is
        /// -adjustedContentInset.top (content pinned under the nav bar).
        func isAtContentTop(_ threshold: CGFloat = 8) -> Bool {
            guard let cv = viewController?.collectionView else { return false }
            return cv.contentOffset.y <= -cv.adjustedContentInset.top + threshold
        }

        /// True when the content offset is within `threshold` pt of the
        /// maximum (bottom) offset.
        func isWithinBottom(_ threshold: CGFloat) -> Bool {
            guard let cv = viewController?.collectionView else { return true }
            // Use adjustedContentInset to account for input bar + tool bar overlay insets.
            let maxOffset = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
            return maxOffset - cv.contentOffset.y < threshold
        }

        func scrollToLastItem(animated: Bool = false) {
            guard let cv = viewController?.collectionView else { return }
            let section = cv.numberOfSections - 1
            guard section >= 0 else { return }
            let item = cv.numberOfItems(inSection: section) - 1
            guard item >= 0 else { return }
            cv.scrollToItem(at: IndexPath(item: item, section: section), at: .bottom, animated: animated)
        }


        /// Diagnostics: which user turn the current viewport TOP is in.
        /// Returns (turnIndex, totalTurns); turnIndex is 0-based into the ordered
        /// list of user messages, -1 if unresolved. Cheap enough to call from a
        /// throttled scroll sampler.
        func currentViewportUserTurn() -> (index: Int, total: Int) {
            guard let cv = viewController?.collectionView,
                  let vm, let ds = dataSource else { return (-1, 0) }
            let msgs = vm.messages
            let userIds = msgs.compactMap { $0.role == .user ? $0.id : nil }
            guard !userIds.isEmpty else { return (-1, 0) }
            let topItemMsgId: UUID? = cv.indexPathsForVisibleItems.min()
                .flatMap { ds.itemIdentifier(for: $0) }
                .flatMap { Self.messageId(of: $0) }
            let topMsgIdx = topItemMsgId.flatMap { id in msgs.firstIndex(where: { $0.id == id }) } ?? 0
            let anchor = msgs[...topMsgIdx].reversed().first(where: { $0.role == .user })?.id ?? userIds.first!
            return (userIds.firstIndex(of: anchor) ?? -1, userIds.count)
        }

        /// Up-button action: walk backwards through the conversation one user
        /// turn at a time. Replaces the old "jump to the very first message":
        ///   - First tap: scroll to the user message of the turn the viewport is
        ///     currently in (nearest role==.user at or above the top visible item).
        ///   - Repeated taps (no intervening drag / new message / etc): each tap
        ///     goes to the PREVIOUS turn's user message.
        ///   - At the first turn already: stay put, no overscroll.
        /// A browse action — must NOT touch scrollMode (same rationale as the old
        /// scrollToTopNow: leave auto-scroll as-is so streaming doesn't yank the
        /// user back down after they jump up).
        func scrollToPreviousUserTurn(animated: Bool = true) {
            guard let cv = viewController?.collectionView,
                  let vm, let ds = dataSource else { return }
            let msgs = vm.messages
            guard !msgs.isEmpty else { return }

            // Ordered list of user-message ids as they appear in the conversation.
            let userIds = msgs.compactMap { $0.role == .user ? $0.id : nil }
            guard !userIds.isEmpty else {
                // No user turns (rare) — fall back to the top of the list.
                if cv.numberOfSections > 0, cv.numberOfItems(inSection: 0) > 0 {
                    cv.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: animated)
                }
                return
            }

            // Resolve the message id at the top of the viewport → its message
            // index → the nearest user message at or above it (the current turn's
            // anchor).
            let topItemMsgId: UUID? = cv.indexPathsForVisibleItems.min()
                .flatMap { ds.itemIdentifier(for: $0) }
                .flatMap { Self.messageId(of: $0) }
            let topMsgIdx = topItemMsgId.flatMap { id in msgs.firstIndex(where: { $0.id == id }) } ?? 0
            let currentAnchor = msgs[...topMsgIdx].reversed().first(where: { $0.role == .user })?.id ?? userIds.first!

            // Decide the target: if the viewport is already at the anchor we last
            // jumped to (user has seen this turn's start), step to the previous
            // turn; otherwise land on the current turn's anchor first.
            let target: UUID
            if lastJumpedUserId == currentAnchor,
               let pos = userIds.firstIndex(of: currentAnchor), pos > 0 {
                target = userIds[pos - 1]
            } else {
                target = currentAnchor
            }

            guard let targetItem = ds.snapshot().itemIdentifiers.first(where: {
                if case .wholeMessage(let id) = $0, id == target { return true }
                return false
            }), let ip = ds.indexPath(for: targetItem) else {
                AppLogger(category: "ScrollDiag").info("[ScrollDiag][prevUserTurn] ABORT target item not found target=\(target.uuidString.prefix(8))")
                return
            }

            lastJumpedUserId = target
            let curTurn = userIds.firstIndex(of: currentAnchor) ?? -1
            let tgtTurn = userIds.firstIndex(of: target) ?? -1
            AppLogger(category: "ScrollDiag").info("[ScrollDiag][prevUserTurn][CALL] curTurn=\(curTurn) targetTurn=\(tgtTurn)/\(userIds.count) topMsgIdx=\(topMsgIdx) currentAnchor=\(currentAnchor.uuidString.prefix(8)) target=\(target.uuidString.prefix(8)) ip=\(ip.section).\(ip.item) \(Self.nbDump(cv))")
            // Also record to the in-memory ring (debug.scrollMetrics) — the
            // on-device FILE log pipeline can stall, but the ring is live.
            // idx=target user-turn index, a=current viewport turn, b=total turns,
            // pos encodes the resulting button visibility for this frame.
            #if DEBUG
            let nbNow = isNearBottom()
            ScrollMetricsRecorder.shared.record(kind: "prevUserTurn", idx: tgtTurn,
                a: Double(curTurn), b: Double(userIds.count),
                pos: "call buttonsVisible=\(!msgs.isEmpty && !nbNow)",
                offset: Double(cv.contentOffset.y), note: Self.nbDump(cv))
            #endif
            cv.scrollToItem(at: ip, at: .top, animated: animated)
            // Re-sync isNearBottom so the up/down buttons reflect the new
            // position. Two syncs on purpose:
            //  - the immediate main.async catches the common case;
            //  - the delayed one covers UIKit's animated scrollToItem, whose
            //    internal animation may not fire a terminal scrollViewDidScroll
            //    at the settled offset. 0.4s covers the default scroll animation.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let cv2 = self.viewController?.collectionView
                let nb = self.isNearBottom()
                #if DEBUG
                ScrollMetricsRecorder.shared.record(kind: "prevUserTurn",
                    a: nb ? 1 : 0, b: (self.vm?.isNearBottom == true) ? 1 : 0,
                    pos: "sync-immediate", offset: Double(cv2?.contentOffset.y ?? -9999),
                    note: Self.nbDump(cv2))
                #endif
                _ = nb
                self.syncScrollFlags()
            }
            if animated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self else { return }
                    let cv2 = self.viewController?.collectionView
                    let nb = self.isNearBottom()
                    #if DEBUG
                    ScrollMetricsRecorder.shared.record(kind: "prevUserTurn",
                        a: nb ? 1 : 0, b: (self.vm?.isNearBottom == true) ? 1 : 0,
                        pos: "sync-0.4s", offset: Double(cv2?.contentOffset.y ?? -9999),
                        note: Self.nbDump(cv2))
                    #endif
                    _ = nb
                    self.syncScrollFlags()
                }
            }
        }

        /// Compact dump of the isWithinBottom inputs for ScrollDiag logs.
        static func nbDump(_ cv: UICollectionView?) -> String {
            guard let cv else { return "cv=nil→isWithinBottom RETURNS TRUE" }
            let maxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
            let diff = maxOff - cv.contentOffset.y
            return "off=\(String(format: "%.0f", cv.contentOffset.y)) cs=\(String(format: "%.0f", cv.contentSize.height)) bh=\(String(format: "%.0f", cv.bounds.height)) adjBot=\(String(format: "%.0f", cv.adjustedContentInset.bottom)) maxOff=\(String(format: "%.0f", maxOff)) diff=\(String(format: "%.0f", diff))"
        }

        /// Base contentInset.top (without sub-viewport overflow compensation).
        /// iOS 26+ relies on system; older iOS uses an 8pt manual padding.
        var baseContentInsetTop: CGFloat {
            if #available(iOS 26, *) { return 0 } else { return 8 }
        }


        /// When content overflows the visible area but is still smaller than the
        /// UIKit-scrollable threshold, UIKit clamps maxOffset at 0 and the
        /// bottom of the content gets hidden behind the bottom overlay.
        ///
        /// Compensate by inflating `contentInset.bottom` by the overflow
        /// amount so UIKit's natural maxOffset moves down (= contentSize -
        /// bounds + bottomInset becomes positive). The user can then scroll
        /// up to reveal the bottom rows that were hidden by the floating bar.
        /// `contentInset.top` stays at `baseContentInsetTop` so the first row
        /// is always glued to the safe area — no blank above the user message.
        ///
        /// `applySubViewportCompensation` is the only writer of
        /// `cv.contentInset.bottom`. updateUIViewController writes
        /// `coord.baseBottomInset`; this function reads it and applies
        /// `baseBottomInset + (needs ? overflow : 0)`.
        ///
        /// Returns true if compensation is currently active.
        @discardableResult
        func applySubViewportCompensation(caller: String = "?", forceRelax: Bool = false) -> Bool {
            guard let cv = viewController?.collectionView else { return false }
            let safeAreaTop = cv.safeAreaInsets.top
            // Use baseBottomInset (set by updateUIViewController) as the truth
            // for the non-compensated bottom. Reading cv.adjustedContentInset.bottom
            // here would create a feedback loop: we'd be measuring the inset we
            // just inflated and concluding we don't need to inflate any more.
            let bottomInsetBase = baseBottomInset
            let visibleH = cv.bounds.height - safeAreaTop - bottomInsetBase
            let overflow = cv.contentSize.height - visibleH
            // Active compensation: content overflows but UIKit thinks no scroll
            // is needed. UIKit's natural maxContentOffset is
            //   contentSize - bounds + adjustedContentInset.top + adjustedContentInset.bottom
            // safeAreaTop becomes adjustedContentInset.top, so include it here —
            // omitting it under-counts maxOffset by safeAreaTop (~116pt) and
            // wrongly engages compensation when content already fits naturally.
            let rawMaxOff = cv.contentSize.height - cv.bounds.height
                          + bottomInsetBase + safeAreaTop
            let needsCompensation = overflow > 0 && rawMaxOff <= 0
            let prevBottomInset = cv.contentInset.bottom

            // [B-fix] Monotonic compensation: during streaming, contentSize
            // grows token-by-token. The naive `desired = needs ? base+overflow
            // : base` jumps the inset back to base the moment `rawMaxOff`
            // crosses 0 (~content reaches bounds.height), and the PIN below
            // chases the inset down — visually the streaming cell snaps from
            // mid-screen back to the bottom by ~overflow pt (observed: 114pt
            // jump at 17:35:39, log [CHANGE] bottomInset 302.7→188.4 RELAX).
            //
            // Hold the inflated inset until either (a) caller explicitly asks
            // for a RELAX (e.g. mode change, snapshot-shrink, clear), or (b)
            // the cell can naturally scroll past `prevBottomInset - base` —
            // i.e. rawMaxOff has caught up to the existing inflation, so
            // releasing it produces no geometric jump.
            let priorInflation = max(0, prevBottomInset - bottomInsetBase)
            let canSafelyRelax = rawMaxOff >= priorInflation - 0.5
            let desiredBottomInset: CGFloat
            if needsCompensation {
                // Grow only — never let the inset shrink mid-stream.
                desiredBottomInset = max(prevBottomInset, bottomInsetBase + overflow)
            } else if forceRelax || canSafelyRelax {
                desiredBottomInset = bottomInsetBase
            } else {
                desiredBottomInset = prevBottomInset
            }
            let bottomInsetWillChange = abs(prevBottomInset - desiredBottomInset) > 0.5
            if bottomInsetWillChange {
                let reason: String
                if desiredBottomInset < prevBottomInset {
                    reason = forceRelax ? "RELAX-FORCED" : "RELAX-SAFE (rawMaxOff≥priorInfl)"
                } else if needsCompensation && prevBottomInset <= bottomInsetBase + 0.5 {
                    reason = "ENGAGE (overflow=\(String(format: "%.0f", overflow)))"
                } else {
                    reason = "GROW (overflow=\(String(format: "%.0f", overflow)))"
                }
                AppLogger(category: "SubViewport").info("[CHANGE] from=\(caller) bottomInset \(String(format: "%.1f", prevBottomInset))→\(String(format: "%.1f", desiredBottomInset)) Δ\(String(format: "%+.1f", desiredBottomInset - prevBottomInset)) — \(reason)")
                cv.contentInset.bottom = desiredBottomInset
            } else if priorInflation > 0.5 {
                // [BottomGapDiag] The inset did NOT change but is still inflated
                // above base — i.e. compensation is being HELD by the [B-fix]
                // monotonic rule (`canSafelyRelax == false`). This is invisible to
                // the `[CHANGE]` log above, which only fires on movement, yet it
                // is precisely the state that leaves reserved blank space under
                // the last bubble. Logging it is the whole point of this probe:
                // if the reported gap correlates with HOLD lines, the monotonic
                // relax condition is the root cause.
                AppLogger(category: "BottomGapDiag").info(
                    "[BottomGapDiag][HOLD] from=\(caller) inflation=\(String(format: "%.1f", priorInflation)) "
                    + "inset=\(String(format: "%.1f", prevBottomInset)) base=\(String(format: "%.1f", bottomInsetBase)) "
                    + "rawMaxOff=\(String(format: "%.1f", rawMaxOff)) overflow=\(String(format: "%.1f", overflow)) "
                    + "needsComp=\(needsCompensation) canRelax=\(canSafelyRelax) — inflated inset retained")
            }
            // Pin offset so content's bottom reaches the overlay top
            // (= bounds - bottomInset in viewport coords). Active in both the
            // compensation and the natural-scroll regime, as long as we are in
            // autoScrolling mode and there's something to pin to. Read the
            // INFLATED inset (cv.adjustedContentInset.bottom) for the pin
            // target so we glue to the just-applied bottom.
            if scrollMode == .autoScrolling {
                // [PIN-fix] Pin against the BASE bottom inset, not the
                // inflated one. Reading inflated `cv.adjustedContentInset.bottom`
                // here would push the cell up by `bottomI - base` (= the
                // sub-viewport compensation amount, up to ~90pt observed),
                // because the inflated inset effectively reserves blank space
                // BELOW the input bar that nobody can see. The compensation's
                // sole job is to make UIKit's natural maxOffset positive so
                // the user can scroll up to reveal the last cell — it is NOT
                // meant to define the resting position. Pinning to base keeps
                // the last cell glued to the input-bar top.
                //
                // adjustedContentInset.top still applies (safe-area /
                // navigation bar) — keep that as-is.
                let pinBottomInset = bottomInsetBase + cv.safeAreaInsets.bottom
                let rawTarget = cv.contentSize.height - cv.bounds.height + pinBottomInset
                // Clamp: don't let target go below -adjustedTop (would scroll
                // past the top edge), and don't exceed the inflated-inset
                // maxOff (would over-scroll past content end).
                let inflatedMaxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
                let topLimit = -cv.adjustedContentInset.top
                let target = min(max(rawTarget, topLimit), inflatedMaxOff)
                if target > topLimit - 0.5 && abs(cv.contentOffset.y - target) > 0.5 {
                    cv.contentOffset.y = target
                }
            }
            return needsCompensation
        }

        func scrollToBottomNow(animated: Bool = false) {
            guard let cv = viewController?.collectionView else { return }
            // Sub-viewport overflow path: re-evaluate compensation, then pin.
            if applySubViewportCompensation(caller: "scrollToBottom") {
                syncScrollFlags()
                return
            }
            let maxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
            guard maxOff > 0 else { return }
            let target = CGPoint(x: 0, y: maxOff)
            if animated {
                isAnimatingScrollToBottom = true
                cv.setContentOffset(target, animated: true)
                // The animated set's final scrollViewDidScroll should land within
                // the near-bottom threshold, but an interrupted animation or
                // sub-pixel/inset rounding can leave vm.isNearBottom stuck false,
                // so the scroll-to-bottom button keeps showing while already at
                // the bottom. Re-sync once the animation settles.
                DispatchQueue.main.async { [weak self] in self?.syncScrollFlags() }
            } else {
                cv.contentOffset = target
                syncScrollFlags()
            }
        }

        /// Push the current near-bottom / far-from-top readings to the view
        /// model (change-gated to avoid @Published churn). Call after any
        /// programmatic scroll whose terminal scrollViewDidScroll may not fire
        /// or may land just outside a threshold.
        /// Re-sync isNearBottom after a programmatic jump (up-turn walk /
        /// jump-to-bottom) so the floating up/down buttons — both gated on
        /// !isNearBottom — reflect the settled position even when the terminal
        /// scrollViewDidScroll lands just outside the threshold. Called on the
        /// main thread after a jump settles.
        func syncScrollFlags() {
            guard let vm else { return }
            let nb = isNearBottom()
            if vm.isNearBottom != nb {
                AppLogger(category: "ScrollDiag").info("[ScrollDiag][syncScrollFlags] isNearBottom \(vm.isNearBottom)→\(nb) \(Self.nbDump(viewController?.collectionView))")
                vm.isNearBottom = nb
            }
            let atTop = isAtContentTop()
            if vm.isAtFirstTurn != atTop { vm.isAtFirstTurn = atTop }
        }
}
