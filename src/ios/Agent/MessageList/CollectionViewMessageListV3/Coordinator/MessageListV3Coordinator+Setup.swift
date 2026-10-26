//
//  MessageListV3Coordinator+Setup.swift
//  Minis - V3 聊天消息列表（Agent/MessageList/CollectionViewMessageListV3）
//
//  attach(to:vm:)：连接 collection view、diffable data source、cell 注册、布局回调和 sheet 展示器浮层。
//
//  文件地图与拆分规则：CollectionViewMessageListV3.swift（本目录）。
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// 拆分接缝：这里的 `Section` 原本在外层 `extension CollectionViewMessageListV3` 内，
// 指 CollectionViewMessageListV3.Section；移到 Coordinator 扩展后会解析成 SwiftUI.Section。
private typealias Section = CollectionViewMessageListV3.Section

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Setup

        func attach(to vc: MessageListViewController, vm: AIChatViewModel) {
            self.viewController = vc
            self.vm = vm
            vc.loadViewIfNeeded()
            guard let collectionView = vc.collectionView else { return }
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            // Disable UIKit's main-thread cell prefetch. Profile (Time Profiler)
            // showed -[UICollectionView _prefetchItemsForPrefetchingContext:]
            // chains through _createPreparedCellForItemAtIndexPath → +UIView
            // performWithoutAnimation → _checkForPreferredAttributesInView →
            // SelfSizingCell.preferredLayoutAttributesFitting →
            // UIHostingContentView.systemLayoutSizeFitting, eating ~44ms (30%)
            // of one main-thread sample for a single off-screen BIG-CELL.
            // That's the 2-3 frame hitch users perceive as a sudden stutter
            // right before scrolling exposes a large text/table cell.
            // Disabling prefetch lets cells be sized only when they actually
            // come on-screen. Heights are still pre-estimated via setEstimatedHeight
            // in applySnapshot / configureCell, so layout positions don't shift.
            collectionView.isPrefetchingEnabled = false

            let wholeReg = UICollectionView.CellRegistration<WholeMessageCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }
            let headerReg = UICollectionView.CellRegistration<AssistantHeaderCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }
            let blockReg = UICollectionView.CellRegistration<AssistantBlockCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }
            let footerReg = UICollectionView.CellRegistration<AssistantFooterCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }

            dataSource = UICollectionViewDiffableDataSource<Section, MessageListItem>(
                collectionView: collectionView
            ) { cv, indexPath, item in
                switch item {
                case .wholeMessage:
                    return cv.dequeueConfiguredReusableCell(using: wholeReg, for: indexPath, item: item)
                case .assistantHeader:
                    return cv.dequeueConfiguredReusableCell(using: headerReg, for: indexPath, item: item)
                case .assistantBlock:
                    return cv.dequeueConfiguredReusableCell(using: blockReg, for: indexPath, item: item)
                case .assistantFooter:
                    return cv.dequeueConfiguredReusableCell(using: footerReg, for: indexPath, item: item)
                }
            }

            // Install sheet overlay (outside UIHostingConfiguration cell tree)
            if sheetOverlayHost == nil {
                let overlay = SheetOverlayView(toolPresenter: sheetPresenter, compactPresenter: compactSummaryPresenter)
                let host = UIHostingController(rootView: overlay)
                host.view.backgroundColor = .clear
                host.view.isUserInteractionEnabled = true
                host.view.frame = .zero
                vc.addChild(host)
                vc.view.addSubview(host.view)
                host.didMove(toParent: vc)
                sheetOverlayHost = host

                sheetPresenter.onDismiss = { [weak self] in
                    self?.flushPendingSnapshotIfNeeded(caller: "sheetDismiss")
                }
            }

            // ContentSize KVO — pin to bottom during autoScrolling
            contentSizeObservation = collectionView.observe(\.contentSize, options: [.new, .old]) {
                [weak self] cv, change in
                guard let self, !self.isFlushing else { return }
                let newH = change.newValue?.height ?? 0
                let oldH = change.oldValue?.height ?? 0
                guard newH != oldH else { return }
                let delta = newH - oldH

                // Session load stability: keep pinning to bottom until layout settles.
                // Use time-based deadline only — fire-count was too fragile on iPad
                // where width changes (sidebar) and async image loads produce many
                // contentSize KVO fires before the layout truly stabilizes.
                if self.clampAfterSessionLoad {
                    let maxOff = max(0, newH - cv.bounds.height + cv.adjustedContentInset.bottom)
                    if maxOff > 0 { cv.contentOffset.y = maxOff }
                    if Date() >= self.clampDeadline {
                        self.clampAfterSessionLoad = false
                    }
                    self.vm?.contentSizeDeltaSignal.send(delta)
                    return
                }

                if delta > 0 && self.scrollMode == .autoScrolling {
                    // Pin to bottom — but if an animated scroll is in flight, directly
                    // mutating contentOffset corrupts UIKit's animation interpolation.
                    // Defer to a coalesced scroll that fires after the animation ends.
                    if self.isAnimatingScrollToBottom {
                        self.scheduleCoalescedScroll()
                    } else {
                        let maxOff = newH - cv.bounds.height + cv.adjustedContentInset.bottom
                        if maxOff > 0 {
                            // [DIAG-3] If tracking/decel, auto-scroll mode is fighting user gesture
                            if cv.isTracking || cv.isDecelerating {
                                AppLogger(category: "StreamDiag").info("[KVO] ⚠️ PIN-WHILE-SCROLLING contentSize grew +\(String(format: "%.0f", delta)) offset \(String(format: "%.0f", cv.contentOffset.y))→\(String(format: "%.0f", maxOff)) tracking=\(cv.isTracking) decel=\(cv.isDecelerating) — MODE SHOULD BE userBrowsing")
                            }
                            cv.contentOffset.y = max(cv.contentOffset.y, maxOff)
                        }
                    }
                } else if delta > 0 && self.scrollMode == .userBrowsing {
                    // [DIAG-3b] Content grew while user is browsing — no pin.
                    // If a cell ABOVE viewport grew, all cells below shift down.
                    AppLogger(category: "StreamDiag").info("[KVO] contentSize grew +\(String(format: "%.0f", delta)) IN BROWSE MODE — no pin. offset=\(String(format: "%.0f", cv.contentOffset.y)) tracking=\(cv.isTracking) decel=\(cv.isDecelerating)")
                } else if delta < 0 && self.scrollMode == .autoScrolling {
                    // Content shrank while auto-scrolling — clamp to prevent overscroll.
                    // Skip during deceleration: settleAfterInteraction will handle it.
                    let maxOff = max(0, newH - cv.bounds.height + cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y > maxOff && !cv.isDecelerating {
                        cv.contentOffset.y = maxOff
                    }
                } else if delta < 0 && self.scrollMode != .autoScrolling {
                    // Content shrank while user is browsing — clamp to prevent overscroll.
                    let maxOff = max(0, newH - cv.bounds.height + cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y > maxOff && !cv.isTracking && !cv.isDecelerating {
                        cv.contentOffset.y = maxOff
                    }
                }
                // After settle, deferred heights are flushed and UIKit re-layouts
                // with real heights. If contentSize shrinks, the current offset may
                // exceed the new max — UIKit will hard-clamp it, causing a visible jump.
                // Pre-emptively clamp with performWithoutAnimation to avoid the jitter.
                if self.settleJustFinished && delta < -1 && !cv.isTracking && !cv.isDecelerating {
                    let maxOff = max(0, newH - cv.bounds.height + cv.adjustedContentInset.bottom)
                    if cv.contentOffset.y > maxOff {
                        AppLogger(category: "Settle").debug("[Settle] POST-SETTLE SHRINK clamp offset \(String(format: "%.1f→%.1f", cv.contentOffset.y, maxOff)) contentSize \(String(format: "%.1f→%.1f", oldH, newH))")
                        UIView.performWithoutAnimation {
                            cv.contentOffset.y = maxOff
                        }
                    }
                }
                // Forward contentSize changes to downstream observers.
                self.vm?.contentSizeDeltaSignal.send(delta)

                // Re-evaluate sub-viewport overflow compensation. When content
                // overflows the visible area but UIKit thinks no scroll is
                // needed, this inflates inset.top so we can pin past UIKit's
                // default clamp.
                self.applySubViewportCompensation(caller: "contentSizeKVO")

                // Sync vm.isNearBottom on every contentSize change. UIKit only
                // dispatches scrollViewDidScroll when contentOffset moves; in
                // sub-viewport streaming (offset clamped at -insetTop while
                // contentSize grows past the visible area), the published value
                // would otherwise stay stuck at its prior reading and the
                // scroll-to-bottom button never appears.
                if let vm = self.vm {
                    let nb = self.isNearBottom()
                    if vm.isNearBottom != nb {
                        vm.isNearBottom = nb
                    }
                }
                self.syncScrollFlags()
            }

            bindViewModel(vm)
        }
}
