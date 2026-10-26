//
//  MessageListV3Coordinator+FooterHeight.swift
//  Minis - V3 聊天消息列表（Agent/MessageList/CollectionViewMessageListV3）
//
//  页脚高度缓存失效。
//
//  文件地图与拆分规则：CollectionViewMessageListV3.swift（本目录）。
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Footer height invalidation

        /// [T-ios-plaf-cache-footer-staleness] Drop the cached height of every
        /// VISIBLE assistant-footer cell, both cell-side and layout-side.
        ///
        /// Needed because the footer's height is driven by `@Published` state on
        /// `CellStateBridgeV2` (`showUsage`, `isActiveMessage`, `canResume`,
        /// the auto-retry fields) rather than by the message content that forms
        /// the diffable item identity. Those flips re-render the SwiftUI body
        /// in place without changing the snapshot, so nothing on the normal
        /// invalidation path (applyContentConfiguration / prepareForReuse) ever
        /// runs and `SelfSizingCell`'s now-unbounded height cache goes stale.
        ///
        /// Deliberately scoped to `visibleCells`: an off-screen footer will be
        /// configured from scratch when it scrolls back in (cell provider →
        /// applyContentConfiguration), so it needs nothing here.
        ///
        /// `messageId == nil` invalidates every visible footer; passing an id
        /// narrows it to that message's footer.
        func invalidateFooterHeightCaches(messageId: UUID? = nil) {
            guard let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout,
                  let ds = dataSource else { return }
            let items = ds.snapshot().itemIdentifiers
            for (i, item) in items.enumerated() {
                guard case .assistantFooter(let mid) = item else { continue }
                if let messageId, mid != messageId { continue }
                let ip = IndexPath(item: i, section: 0)
                let cellForFooter = cv.cellForItem(at: ip) as? SelfSizingCell

                // [T-ios-footer-extra-gap] DEFENSIVE, not a root-cause fix.
                //
                // `invalidateHeight` needs no cell, so it should not sit behind
                // the cell lookup — the old `guard let cell … else { continue }`
                // skipped the layout-side invalidate whenever the footer was not
                // currently realised. Field logs (2026-08-10 09:30:06, idx=179)
                // confirm that branch does fire, though in that instance nothing
                // was cached and the skip was harmless.
                //
                // Kept separate deliberately: the cell clear still requires a
                // cell, the layout invalidate no longer does. This closes the
                // asymmetry without claiming it explains the reported gap.
                cellForFooter?.clearCachedHeight()
                layout.invalidateHeight(at: i)
            }
        }
}
