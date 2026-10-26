//
//  MessageListV3Coordinator.swift
//  Minis - V3 聊天消息列表（Agent/MessageList/CollectionViewMessageListV3）
//
//  Coordinator 类：回调、ScrollMode、全部存储属性、deinit。所有行为都在同目录的
//  MessageListV3Coordinator+<Concern>.swift 扩展里。
//
//  分隔："// MARK: Stored state of +<Concern>  [split seam]" 标出原来位于该关注点
//  区段内的存储属性；第一个分隔之前是类的前导属性，由多个关注点共用。
//
//  文件地图与拆分规则：CollectionViewMessageListV3.swift（本目录）。
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - V3 Coordinator

extension CollectionViewMessageListV3 {

    /// Scroll mode: the only two states V3 needs.
    enum ScrollMode {
        /// Content growth pins offset to bottom. Self-sizing accepted normally.
        case autoScrolling
        /// User is reading above the bottom. Layout changes preserve offset.
        case userBrowsing
    }

    final class Coordinator: NSObject, UICollectionViewDelegate, UIScrollViewDelegate, UICollectionViewDataSourcePrefetching {
        // Callbacks
        var onRetryMessage: ((UUID) -> Void)?
        var onOpenSoulSettings: (() -> Void)?
        var onRetryLast: (() -> Void)?
        var onEdit: ((UUID) -> Void)?
        var onDeleteFrom: ((UUID) -> Void)?
        var onWithdraw: ((UUID) -> Void)?
        var onResume: (() -> Void)?
        var onStop: (() -> Void)?
        var onCompact: ((UUID) -> Void)?
        var onRevertCompact: (() -> Void)?
        var onForceSync: (() -> Void)?
        var onScreenshotImage: ((UIImage) -> Void)?
        var maxContentWidth: CGFloat = 0
        var lastInputFocused: Bool = false

        #if DEBUG
        // MARK: Stored state of +DecelDisplayLink  [split seam]
        var decelDisplayLink: CADisplayLink?
        var decelDLLastTimestamp: CFTimeInterval = 0
        var decelDLFrames: Int = 0
        var decelDLDrops: Int = 0
        var decelDLMinGapMs: Double = .infinity
        var decelDLMaxGapMs: Double = 0
        var decelDLExpectedMs: Double = 16.67
        deinit {
            // [DecelDisplayLink] CADisplayLink retains its target — must
            // invalidate on Coordinator teardown to break the cycle.
            decelDisplayLink?.invalidate()
        }
        #endif

        // === Scroll mode (replaces V2's 6+ mechanisms) ===
        var scrollMode: ScrollMode = .autoScrolling {
            didSet {
                // Mirror to the layout so its invalidationContext can glue the
                // streaming cell's bottom to the viewport while pinned (smooth
                // grow) and skip that adjustment while the user browses.
                // [T-ios-stream-natural-transitions]
                viewController?.messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
            }
        }
        /// True during settleAfterInteraction flush — suppresses contentSize KVO offset changes.
        var isFlushing = false
        /// True while an animated setContentOffset is in flight. KVO grow events must not
        /// directly mutate contentOffset during this window — UIKit animation interpolation
        /// can produce a corrupted final offset. Instead, defer via scheduleCoalescedScroll().
        var isAnimatingScrollToBottom = false

        // === O(1) Lookup Indices ===
        var messageIndex: [UUID: Int] = [:]
        var itemToIndex: [MessageListItem: Int] = [:]

        // === Snapshot State ===
        var previousSnapshotIds: [MessageListItem] = []

        /// [T-ios-first-block-footer-gap] Per-message block count as of the last
        /// applied snapshot, used to detect the 0 -> >=1 edge that collapses the
        /// footer. Tracked in the DATA layer on purpose: the first attempt hung
        /// this off `blockContentFilledSignal`, which only fires for TEXT blocks
        /// going empty -> non-empty. A tool block is created already populated
        /// and never takes that path, so the footer was not invalidated until
        /// some later text block happened to stream — long after the gap was on
        /// screen. Counting blocks covers every kind (tool, thinking, text).
        var lastBlockCountByMessage: [UUID: Int] = [:]

        /// [T-ios-first-block-footer-gap] Footer shape as of the previous
        /// `updateBridge` call, per message. Needed because the shape now
        /// includes fields read from `ChatMessage`, which this function does not
        /// mutate — the transition to detect happens between calls, not within
        /// one. Pruned alongside `cellBridges`.
        var lastFooterShapeByMessage: [UUID: FooterHeightShape] = [:]
        var snapshotMessages: [ChatMessage] = []

        // === Bridges ===
        var cellBridges: [UUID: CellStateBridgeV2] = [:]

        // === Height Measurement Cache ===
        /// Caches measureAttributedStringHeight results by NSAttributedString identity.
        /// Avoids redundant TextKit layout on repeated snapshots for the same content.
        var attrStringHeightCache: [ObjectIdentifier: CGFloat] = [:]
        /// [T-ios-user-msg-estimate-tail-jitter] Caches accurate user-bubble
        /// heights keyed by "content|width|fontsize" (user text has no
        /// cachedAttributedString identity to key on). Cleared alongside
        /// attrStringHeightCache on session change / font change.
        var userBubbleHeightCache: [String: CGFloat] = [:]

        /// [T-ios-earlier-stream-seed-freeze] Memo for
        /// `liveAssistantIds(in:isProcessing:)`. `configureCell` runs per cell
        /// and the underlying rule walks every message's blocks, so without
        /// this the seed path would go O(cells x messages x blocks) on exactly
        /// the busiest frames (mid-stream, many visible cells). Keyed by the
        /// cheap (identity of last message, message count, isProcessing) tuple
        /// — every transition that can change the answer moves at least one of
        /// them, because a message becoming/ceasing to be live is always
        /// accompanied by `isProcessing` flipping or the block set changing
        /// within the same streaming generation, which `streamGeneration`
        /// tracks.
        var liveIdsMemo: (key: String, ids: Set<UUID>)?


        /// Bumped whenever block content/status changes in a way that can flip
        /// which messages are live, so `liveIdsMemo` recomputes.
        var streamGeneration: Int = 0

        // === Thinking Block Toggle ===
        var thinkingToggleSub: AnyCancellable?

        // === Attachment mount invalidation ===
        // [T-ios-user-attach-mount-invalidate] Drain mounts attachments onto an
        // already-inserted user message; see .minisUserAttachmentsMounted.
        var attachMountSub: AnyCancellable?

        // === Async attachment size invalidate ===
        // [T-attachment-size-invalidate 2026-05-21] Image / video / thumbnail
        // async loads cause cell SwiftUI body to grow from placeholder to fit
        // size, but SelfSizingCell's broad-width cache short-circuits
        // preferredLayoutAttributesFitting so the cell never re-measures —
        // bottom of content gets clipped until the chat is re-entered.
        var attachmentSizeChangedSub: AnyCancellable?
        /// [T-ios-image-squish-probe §2] Same-runloop-tick coalescing for
        /// `.minisAttachmentSizeChanged` bursts (a six-image message fires up
        /// to 12: header probe + decode completion per image). The handler is
        /// a full-list invalidate + reconfigure, so one pass per tick is the
        /// budget.
        var attachmentSizeRefreshScheduled = false
        var pendingAttachmentSizeUrls: [String] = []


        // === Foreground/Background Content Tracking ===
        /// Total character count of the last assistant message's blocks when the app entered background.
        /// Used to decide whether layout invalidation is needed on foreground return.
        var contentLengthAtBackground: Int?

        // === Streaming ===
        var lastMessageId: UUID?
        var lastMessageSub: AnyCancellable?
        var lastMessageBlockCountSub: AnyCancellable?

        /// [T-ios-ui-blocks-lost-suspend-resume] Last observed value of the vm's
        /// `streamingUIUpdatesSuspended`, tracked so the vm-state subscription can
        /// detect a true→false transition and flush a snapshot deferred during the
        /// suspend window (see `suspendResumeSub`).
        var lastSuspendedValue: Bool = false
        /// [T-ios-ui-blocks-lost-suspend-resume] Watches the vm for the moment
        /// `streamingUIUpdatesSuspended` clears, then flushes the pending snapshot.
        var suspendResumeSub: AnyCancellable?

        /// Adaptive streaming throttle: last time flushStreamingLayout actually ran.
        var lastStreamingLayoutTime: Date = .distantPast
        /// Trailing-edge work item so the final streaming update isn't lost.
        var pendingStreamingLayout: DispatchWorkItem?


        /// Scroll coalescing: batches rapid scroll signals into one 80ms action.
        var pendingScrollWork: DispatchWorkItem?

        // === Session Load ===
        /// When true, contentSize KVO keeps pinning to bottom until layout stabilizes.
        var clampAfterSessionLoad: Bool = false
        /// Hard deadline to stop clamping (2s after session load).
        var clampDeadline: Date = .distantPast

        // === Sheet Presenters ===
        let sheetPresenter = ToolSheetPresenter()
        let compactSummaryPresenter = CompactSummaryPresenter()
        var sheetOverlayHost: UIHostingController<SheetOverlayView>?

        // === References ===
        weak var viewController: MessageListViewController?
        weak var vm: AIChatViewModel?
        var dataSource: UICollectionViewDiffableDataSource<Section, MessageListItem>!
        var subscriptions = Set<AnyCancellable>()
        var contentSizeObservation: NSKeyValueObservation?

        // MARK: Stored state of +CellConfiguration  [split seam]

        let screenshotLogger = AppLogger(category: "TurnScreenshot")
        /// [T-ios-copy-screenshot-diag-logs] Verbose stage-by-stage trace of
        /// captureScrollingTurnScreenshot used to chase the "top blank when
        /// long-press from middle/bottom" symptom that the first repair
        /// (5e3c6160) didn't fully eliminate. Separate category from
        /// TurnScreenshot so users can `grep ChatScreenshot` cleanly to
        /// pull just the diagnostic frames without the noisier turn-level
        /// summary lines.
        let chatScreenshotLogger = AppLogger(category: "ChatScreenshot")
        /// Counts cells configured since last applySnapshot to detect first-cell timing.
        var cellConfigCount: Int = 0
        var firstCellConfigTime: CFAbsoluteTime = 0

        /// Subscriptions for bridge detailBlock → sheet presenter forwarding.
        var bridgeSheetSubs: [UUID: AnyCancellable] = [:]

        // MARK: Stored state of +Snapshot  [split seam]

        /// When a snapshot is deferred (e.g. streaming UI updates suspended),
        /// set to true so we know to re-apply later.
        var hasPendingSnapshot: Bool = false

        // MARK: Stored state of +Scroll  [split seam]

        let nearBottomThreshold: CGFloat = 20

        /// Tighter threshold for *re-acquiring* `.autoScrolling` after a
        /// deliberate user interaction settles. `nearBottomThreshold` (20pt)
        /// is right for *maintaining* the bottom-pin during streaming, but
        /// reusing it to re-arm auto-scroll caused trackpad jitter on iPad:
        /// a tiny two-finger scroll up leaves the offset well within 20pt of
        /// the bottom, so settle flipped straight back to `.autoScrolling`,
        /// the contentSize KVO re-pinned to the bottom, and that fought the
        /// next small scroll — the scrollbar darted up and down. Requiring the
        /// content to be essentially flush with the bottom (≤4pt) means a
        /// deliberate small scroll stays in `.userBrowsing`, while a scroll
        /// that genuinely lands at the bottom still resumes follow-along.
        /// [T-ios-trackpad-scroll-jitter]
        let reacquireAutoScrollThreshold: CGFloat = 4

        /// The user-message id the up-button last jumped to, so a repeated tap
        /// walks one turn further back. Reset (nil) whenever the anchoring
        /// context changes — manual drag, jump-to-bottom, snapshot change, or
        /// session load — so the next tap re-anchors to the current viewport
        /// instead of continuing from a stale turn.
        var lastJumpedUserId: UUID?

        /// Base contentInset.bottom = inputBarHeight + floatingBarHeight + 8.
        /// Set by updateUIViewController; the actual cv.contentInset.bottom
        /// equals this plus the current sub-viewport compensation (if any).
        /// `applySubViewportCompensation` is the only place that writes
        /// contentInset.bottom — it reads this base and adds overflow.
        var baseBottomInset: CGFloat = 0

        // MARK: Stored state of +ScrollViewDelegate  [split seam]

        /// Track last logged offset to detect jumps after settle.
        var lastLoggedOffset: CGFloat = 0
        var settleJustFinished = false

        var scrollSamples = 0
        var lastScrollFlushOffset: CGFloat = 0
        var lastScrollFlush: CFTimeInterval = 0

        // [ScrollDecel] Deceleration-phase instrumentation. Lets us pin a
        // dropped frame to "Xms into the decel, at offset Y" so the
        // scroll-jank trace's micro-hangs can be aligned to the exact moment
        // and content region where the costly render started.
        var decelStartTime: CFTimeInterval = 0
        var decelStartOffset: CGFloat = 0
        var decelTargetOffset: CGFloat = 0
        var decelLastFrameTime: CFTimeInterval = 0
        var decelFrameCount = 0
        var decelSlowFrameCount = 0
        /// A frame gap above this (seconds) during deceleration is a dropped
        /// frame worth logging. ~32ms ≈ two missed frames at 60Hz / several at
        /// 120Hz — low enough to catch the jitter, high enough to stay quiet
        /// on smooth scrolls.
        let decelSlowFrameThreshold: CFTimeInterval = 0.032

    }
}
