//
//  CollectionViewMessageListV3.swift
//  Minis - V3 聊天消息列表（Agent/MessageList/CollectionViewMessageListV3）
//
//  入口：聊天界面嵌入的 UIViewControllerRepresentable，以及列表监听的两个
//  Notification.Name。持有 SwiftUI 侧配置（回调、inset、宽度），其余交给 Coordinator。
//
//  文件地图（从一个 5300 行的大文件拆出；代码逐字移动，对应上游 1.15 的拆分，
//  只保留 MinisX 现有的代码）：
//    CollectionViewMessageListV3.swift      representable、Section、通知名
//    Cells/
//      BridgedAssistantHeaderV3.swift       助手回合顶部的 "✦ <名字>" 行
//      BridgedAssistantBlockV3.swift        一个助手块（文本 / 思考 / 工具）及其长按菜单
//      BridgedAssistantFooterV3.swift       输入中 / 错误 / 继续 / 用量 页脚行
//      BridgedWholeMessageV3.swift          用户 / 分隔线 / 系统信息消息行
//      MessageListV3Cells.swift             各类型的 SelfSizingCell 子类（用于复用）
//    Coordinator/
//      MessageListV3Coordinator.swift       类声明、全部存储属性、deinit、ScrollMode
//      +Setup                 attach(to:vm:)：数据源、布局、sheet 展示器
//      +CellConfiguration     cell 提供器主体、首次显示种子、桥接对象、liveAssistantIds
//      +BridgeUpdates         逐 cell 的 CellStateBridgeV2 刷新、页脚形态
//      +Bindings              view model 订阅（bindViewModel）
//      +FooterHeight          页脚高度缓存失效
//      +ContentLength         重新测量用的内容长度判断
//      +Streaming             最后一条消息的流式订阅与刷新
//      +Snapshot              applySnapshot（diffable data source）、附件尺寸变化处理
//      +HeightMeasurement     精确的文本 / 用户气泡高度预计算
//      +HeightEstimation      缓存键、未测量项的高度估算
//      +Scroll                滚动状态、跳转、底部固定、不足视口时的 inset 补偿
//      +ScrollingScreenshot   长按截取整轮对话（滚动并拼接）
//      +ScrollViewDelegate    预取与 UIScrollViewDelegate、settle
//      +DecelDisplayLink      仅 DEBUG 的 CADisplayLink 掉帧计量
//    Sheets/
//      MessageListV3SheetPresenters.swift   工具详情 / 压缩摘要 sheet 展示器和 SheetOverlayView
//
//    上游 1.15 有而 MinisX 没有对应代码的文件不建（BridgedToolGroupV3、Search/*、
//    RetryLogSheet、ComposerShrinkAbsorption、QueuedCandidateSpacing、
//    +ToolFolding 等）。MinisX 没有独有到需要新文件的代码。
//
//  拆分规则：
//    - 新增的 Coordinator 存储属性放进 MessageListV3Coordinator.swift（扩展里不能有存储属性），
//      放在对应 "Stored state of +<Concern>" 分隔注释之下。
//    - 跨文件使用的成员是 internal（不写 private）；只有调用者全在本文件时才保留 private。
//    - 本目录是 Xcode 同步文件夹：新文件自动加入 Minis target，不用改 project.pbxproj。
//      Swift 文件名在模块内必须唯一，所以带 MessageListV3 前缀。
//
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by toggleUsage to tell the Coordinator to re-snapshot so the
    /// footer cell is inserted or removed on demand.
    static let messageListNeedsResnapshot = Notification.Name("messageListNeedsResnapshot")

    /// [T-ios-user-attach-mount-invalidate #182-followup] Posted by the send
    /// queue's drain when it mounts processed attachments onto an
    /// already-inserted user message (`chatMsg.attachments = attMetas`).
    /// `object` is the message's UUID.
    ///
    /// The mount is a +70pt-per-row in-place content change on a cell whose
    /// item identity does not move, so nothing on the normal invalidation path
    /// (reconfigure / prepareForReuse) runs. Device forensics (msg 5956CCDD,
    /// log hash 1BFDAB45, 2026-08-08) showed the failure chain when the cell's
    /// FIRST real self-size lands inside the pre-mount window: the tile-less
    /// height (~68pt) enters `heightCache`, every later correct re-seed is
    /// rejected by `setPrecalcHeight`'s occupied-slot guard, and the
    /// width-matched cell cache + streaming-window short-circuit serve the
    /// stale height for the rest of the turn — the bubble truncates to one
    /// line with the tile seemingly detached above it. The Coordinator's
    /// handler breaks the chain with a TARGETED invalidation of that one cell.
    static let minisUserAttachmentsMounted = Notification.Name("minisUserAttachmentsMounted")
}

// MARK: - CollectionViewMessageListV3

/// V3 message list: builds on V2's cell-per-block model but simplifies
/// the scroll stability architecture:
///
/// - **Single height source**: UIKit self-sizing only (no GeometryReader)
/// - **3-tier height resolution**: measured cache → precalc (NSAttributedString) → estimate
/// - **2-state scroll model**: autoScrolling / userBrowsing (replaces V2's 6+ mechanisms)
/// - **O(1) message lookup**: UUID index rebuilt on each snapshot
struct CollectionViewMessageListV3: UIViewControllerRepresentable {
    @ObservedObject var vm: AIChatViewModel
    var inputFocused: Bool
    var onRetryMessage: ((UUID) -> Void)?
    var onRetryLast: (() -> Void)?
    /// [T-ios-assistant-header-open-soul] Tap on the assistant identity row.
    var onOpenSoulSettings: (() -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onDeleteFrom: ((UUID) -> Void)?
    var onWithdraw: ((UUID) -> Void)?
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?
    var onCompact: ((UUID) -> Void)?
    var onRevertCompact: (() -> Void)?
    var onForceSync: (() -> Void)?
    var onScreenshotImage: ((UIImage) -> Void)?
    var maxContentWidth: CGFloat
    var floatingBarHeight: CGFloat
    var inputBarHeight: CGFloat

    func makeUIViewController(context: Context) -> MessageListViewController {
        let vc = MessageListViewController()
        context.coordinator.attach(to: vc, vm: vm)
        // Drops are handled exclusively by the SwiftUI `.onDrop` on the chat
        // root view. Previously a UIDropInteraction here intercepted drops on
        // top of the collection view, which (a) suppressed SwiftUI's
        // isTargeted highlight on the first drop and (b) on iPadOS 26.5 left
        // SwiftUI's drop session state half-tracked, sticking the highlight
        // on the second drag. See T-filedrop GH#12.
        return vc
    }

    func updateUIViewController(_ vc: MessageListViewController, context: Context) {
        let coord = context.coordinator
        // [T-ios-scrollbtn-vm-split] The coordinator captured `vm` once in
        // makeUIViewController → attach. SwiftUI reuses this representable's
        // platform VC (and coordinator) across AIChatView re-creations, so when
        // the ViewModelCache hands the re-created view a NEW AIChatViewModel
        // instance for the same session, the coordinator kept driving the OLD
        // one: every isNearBottom write landed on a VM nothing was observing,
        // while the overlay's VM stayed at its initial isNearBottom=true — the
        // floating ↑/↓ buttons never appeared again for the whole session
        // (device ring trace: coordinator vm read false at every sync while
        // the buttons stayed hidden at diff≈2700pt from the bottom).
        coord.rebindViewModelIfNeeded(vm)
        coord.onRetryMessage = onRetryMessage
        coord.onOpenSoulSettings = onOpenSoulSettings
        coord.onRetryLast = onRetryLast
        coord.onEdit = onEdit
        coord.onDeleteFrom = onDeleteFrom
        coord.onWithdraw = onWithdraw
        coord.onResume = onResume
        coord.onStop = onStop
        coord.onCompact = onCompact
        coord.onRevertCompact = onRevertCompact
        coord.onForceSync = onForceSync
        coord.onScreenshotImage = onScreenshotImage
        coord.maxContentWidth = maxContentWidth

        // Bottom inset base = input bar + tool bar overlay height + breathing room.
        // applySubViewportCompensation is the only writer of cv.contentInset.bottom;
        // it reads coord.baseBottomInset and adds overflow on top when needed.
        //
        // [T-bottom-occluded 0a6d3c92] introduced +16 to fix a perceived
        // clip of the last bubble's bottom text. That report turned out
        // to be the cell-height bug fixed in [ClipFix 2026-05-16]
        // (boundingRect / mtv missing textContainerInset). With cell
        // heights now accurate the +16 breathing room becomes pure
        // dead space — observed as ~100pt gap between the last bubble
        // and the composer top. Restored to the historical +8.
        let bottomPad: CGFloat = inputBarHeight + floatingBarHeight + 8
        let baseChanged = abs(coord.baseBottomInset - bottomPad) > 0.5
        if baseChanged {
            let cv = vc.collectionView!
            let previousBase = coord.baseBottomInset
            let wasSmaller = previousBase < bottomPad
            // Capture follow-intent BEFORE mutating the inset: enlarging the
            // inset enlarges maxOffset, so a user pinned at the bottom would
            // measure as >20pt away from it and fail the isNearBottom() guard.
            let wasNearBottomBefore = coord.isNearBottom()
            coord.baseBottomInset = bottomPad
            // Apply the base immediately so contentInset.bottom reflects the
            // new base before applySubViewportCompensation runs (which may
            // further inflate it). Compensation will overwrite if needed.
            cv.contentInset.bottom = bottomPad
            // [T-inputbar-shrink-content-bump] Re-pin on BOTH directions, not just
            // growth.
            //
            // The old condition was `wasSmaller && …`, so only an ENLARGING inset
            // re-pinned. A shrink was left to UIKit — and UIKit's response to
            // `maxContentOffset` dropping below the current `contentOffset` is to
            // clamp it, which reads on screen as the whole conversation jerking
            // UPWARD by exactly the shrink amount, then settling back when the next
            // scroll/settle re-pins it.
            //
            // Field trace (first message + tool card): inputBarHeight went
            // 115.36 → 193.36 → 115.36 as the tool-execution card expanded and
            // collapsed. baseBottomInset therefore moved 123.36 → 201.36 → 123.36,
            // i.e. maxContentOffset fell by 78pt on the way back down. Pinned at the
            // bottom, the offset was 78pt past the new maximum and got clamped —
            // the reported "content bumps up a bit, then returns".
            //
            // Growth still needs the re-pin for the documented reason (a larger
            // inset enlarges maxOffset, so a pinned user would otherwise be left
            // 78pt short of the bottom). Shrink needs it to hide the clamp. The
            // follow-intent gate is unchanged, so a user who has scrolled away is
            // still never yanked to the bottom by a composer resize.
            if coord.scrollMode == .autoScrolling || wasNearBottomBefore {
                if !wasSmaller {
                    AppLogger(category: "ScrollDiag").info("[ScrollDiag][baseInsetShrink] \(String(format: "%.2f", previousBase))→\(String(format: "%.2f", bottomPad)) inputBar=\(String(format: "%.2f", inputBarHeight)) offset=\(String(format: "%.1f", cv.contentOffset.y)) — re-pinning to hide the UIKit clamp")
                }
                coord.scrollMode = .autoScrolling
                coord.scrollToBottomNow(animated: false)
            }
        }

        // [T-first-msg-top-gap 2026-07-18] Apply the top inset. User report
        // (iOS 16 screenshot): the first user bubble sat flush against the
        // opaque navbar — common to ALL of iOS 16-18, because
        // `baseContentInsetTop` (designed as "8pt manual padding on older
        // iOS", see its doc) was defined but never written into
        // cv.contentInset.top anywhere; the legacy nav layout doesn't extend
        // content behind the bar, so the collection view's own top edge IS
        // the navbar bottom and the first row rendered with zero breathing
        // room. iOS 26 returns 0 here (liquid-glass + .automatic adjustment
        // already position content), so this is a no-op there.
        let cvTop = vc.collectionView!
        if abs(cvTop.contentInset.top - coord.baseContentInsetTop) > 0.5 {
            cvTop.contentInset.top = coord.baseContentInsetTop
        }

        coord.applySubViewportCompensation(caller: "updateUIVC")

        // [T-message-list-empty-on-foreground] Backstop: if a snapshot was
        // deferred during a load (bind1) but binding 3's true→false edge was
        // missed (removeDuplicates collapse, or $isLoadingSession settling in
        // the same runloop cycle the snapshot was deferred), the list would be
        // stranded empty while the VM has messages. updateUIViewController runs
        // on every SwiftUI re-render (e.g. the toolbar updating — exactly the
        // observed "toolbar updates, list blank" symptom), so flush here once
        // loading has finished. Gated on NOT being in a streaming-suspend window
        // so we never pre-empt the suspend-resume machinery (which intentionally
        // holds hasPendingSnapshot during scroll-settle / background streaming);
        // that path has its own flush on resume. flushPendingSnapshotIfNeeded
        // no-ops when nothing is pending, so this is free on the happy path.
        if !vm.isLoadingSession && !vm.streamingUIUpdatesSuspended {
            coord.flushPendingSnapshotIfNeeded(caller: "updateUIVC-backstop")
        }

        if inputFocused != coord.lastInputFocused {
            let wasNearBottom = coord.scrollMode == .autoScrolling && coord.isNearBottom()
            coord.lastInputFocused = inputFocused
            if wasNearBottom {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak coord] in
                    coord?.scrollToBottomNow(animated: true)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    enum Section { case main }
}
