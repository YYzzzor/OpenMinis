//
//  ContentView.swift
//  Minis - 首页（Views/ContentView）
//
//  ContentView：应用的根视图。会话列表（侧边栏）、进入聊天的导航，以及设置、工具、同步的入口。
//
//  本文件：ToolSheet、ContentView 的全部存储属性（@State、@ObservedObject、@AppStorage 等）、
//  草稿会话 id 的辅助函数、SyncSubtitleState，以及 `body`（布局切换、sheet、
//  onChange / onReceive 链）。
//
//  文件地图（从一个 8000 行的大文件拆出；代码逐字移动，对应上游 1.15 的拆分，
//  只保留 MinisX 现有的代码）：
//    ContentView/ContentView.swift          本文件
//    ContentView/ContentView+<职责>.swift   按职责分组的 ContentView 成员：
//      Layout             分栏（iPad / 宽窗口）和堆叠（iPhone）布局、详情页
//      SidebarGrouping    日期 / 置顶 / 文件夹分组，文件夹折叠与 mini bar，
//                         便于 diff 的 SidebarGroup 投影
//      SessionList        行与文件夹分组的 List / ForEach
//      SidebarToolbar     工具栏、同步副标题和指示器
//      Navigation         选中辅助、新建对话、打开 / 切换会话、Quick Action 和后台导航
//      SessionMenu        行上下文菜单标签与动作通道接线
//      RemoteSessions     其他设备同步来的会话
//      PendingShare       分享扩展交接
//      EmptyState         首次使用的设置步骤
//      Search             搜索栏和搜索调度
//      SessionRefresh     会话列表刷新 / 防抖；MinisX：首屏会话加载（loadInitialSessionState）
//      FAB                悬浮新建对话和搜索按钮
//      SectionHeaders     可选择的行、日期和文件夹分组头、文件夹动作
//      SelectionToolbar   多选工具栏、Force Sync
//      SessionActions     删除（含删除信息）、重新生成标题
//      Export             JSON / 纯文本导出
//    ContentView/Sidebar/   列表用到的类型：SidebarGroup 模型、行视图（SessionRow、
//        RemoteSessionRow）、表面和 modifier、上下文菜单、动作通道、文件夹选择与弹窗、
//        FAB、同步指示器、DEBUG 探针
//    ContentView/Sheets/    删除确认、导出预览、会话编辑
//    Settings/SettingsSheet.swift、Settings/AppearanceSettingsView.swift
//                           工具栏打开的设置页
//
//    body 的分段内容（navigationContent、sessionEventContent、presentationContent、
//    startupContent、navigationEventContent、deepLinkContent）是 MinisX 独有的，
//    和 body 一起留在本文件。上游 1.15 有而 MinisX 没有对应代码的文件不建
//    （NavDiag、HomeListPerf、FABActionChannel、SessionStackRow / SessionSplitRow、
//    FolderPickerOrder、MacOS27GlassWorkaround 等）。除上面两处外，MinisX 独有的代码
//    都放进了职责最接近的上游文件，没有新增 MinisX 专属文件。
//
//  拆分规则：
//    - 存储属性（@State、@ObservedObject、@AppStorage 等）留在本文件的 struct 主体里：
//      扩展里不能有存储属性。只有扩展文件用到的放在主体末尾。新状态也加在这里。
//    - 跨文件使用的声明是 internal（原来是 private）；视为首页私有。只在一个文件里
//      用到的类型保持 private。
//    - shareLog、draftLog 是文件级 private，每个要打日志的文件各一份。
//    - 有状态的文件级全局变量只能放在一个文件里：DEBUG 的 rowHeightSeen 和
//      rowHeightSeenLock 只在 Sidebar/SidebarDebugProbes.swift，用到它们的
//      probeRowHeight 在同一个文件。
//    - 新行为加进所属的 ContentView+<职责>.swift，或新建一个；不要加长 `body`，
//      它已经接近类型检查器的预算（见 FolderAlertsModifier）。
//    - 本目录是 Xcode 同步文件夹：新文件自动加入 Minis target，不用改 project.pbxproj。
//      Settings/ 不是：那里的新文件要在 project.pbxproj 里逐个加。
//      Swift 文件名在模块内必须唯一。
//

import SwiftUI

private let shareLog = AppLogger(category: "Share")
private let draftLog = AppLogger(category: "DraftSession")

/// Sheets triggered from the toolbar menu, consolidated into a single `.sheet(item:)`.
enum ToolSheet: String, Identifiable {
    case settings
    case rootfsManagement
    case browser
    case browserManagement
    case syncMigrationDetail
    var id: String { rawValue }
}

struct ContentView: View {
    /// Prefix for draft session IDs. Each new chat gets a unique suffix
    /// so SwiftUI's `.id()` correctly destroys old views and creates new ones.
    private static let newSessionPrefix = "__new__"

    /// Whether a session ID represents an unsaved draft session.
    static func isNewSessionId(_ id: String?) -> Bool {
        id?.hasPrefix(newSessionPrefix) == true
    }

    /// Generate a unique draft session ID.
    static func makeNewSessionId() -> String {
        "\(newSessionPrefix)\(UUID().uuidString)"
    }

    private static let groupSeparator = "__grp__"

    /// Generate a draft session ID that also carries a model group selection.
    static func makeNewSessionId(groupId: String) -> String {
        "\(newSessionPrefix)\(UUID().uuidString)\(groupSeparator)\(groupId)"
    }

    /// Extract the group ID embedded in a draft session ID, if present.
    static func extractGroupId(from id: String) -> String? {
        guard let range = id.range(of: groupSeparator) else { return nil }
        let groupId = String(id[range.upperBound...])
        return groupId.isEmpty ? nil : groupId
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var shareCoordinator: ShareCoordinator
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    /// Subscribe to the router so changes to its `@Published` fields are
    /// observed by SwiftUI — without this, `onChange(of: router.newChatTrigger)`
    /// reads a static value and never fires after the view mounts. Quick
    /// Actions that arrive before this view's `.onReceive(.newChatRequested)`
    /// publisher is attached (typical cold-launch race) would otherwise be
    /// dropped.
    @ObservedObject var quickActionRouter = QuickActionRouter.shared
    // [T-ios-ipad-sidebar-running-indicator-stale] Observe the activity /
    // concurrency trackers AT THE LIST LEVEL too (SessionRow already observes
    // them, but the #584 id-list ForEach reuses an already-materialized cell
    // for the running session and swallows the row's @ObservedObject change
    // when only the running flag flips — id list & resolved ChatSession value
    // are unchanged). Observing here re-evaluates the list body when
    // activeSessions / suspended flips, which regenerates each row's composite
    // diff key (see sessionRowKeys) so the ForEach can't skip re-materializing
    // the row whose running state changed.
    @ObservedObject var sidebarActivityTracker = SessionActivityTracker.shared
    // Folder-header aggregates (anyUnread / anyPaused) read the badge store
    // during sidebarGroups; observing it here is what re-derives those
    // aggregates when a badge flips. Row-level observation alone would only
    // refresh the rows, not the header pass.
    @ObservedObject var sidebarBadgeStore = SessionBadgeStore.shared
    @ObservedObject var sidebarConcurrencyManager = SessionConcurrencyManager.shared
    @State var sessions: [ChatSession] = []
    @State var folders: [ChatFolder] = []
    /// Collapsed folder sections. Pure UI view-state: persisted locally, never
    /// synced (like SessionBadgeStore's .unread — cross-device expand state is
    /// noise, not signal).
    @State var collapsedFolderIds: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "collapsedFolderIds") ?? [])
    /// Folder ids whose EXPANDED header card is currently scrolled out above
    /// the list's visible top — drives the floating mini-bar. A Set (not a
    /// single id) because "expanded" is the DEFAULT folder state: before the
    /// accordion ever runs, several folders can be expanded at once, so more
    /// than one header can be offscreen. Display picks one deterministically.
    @State var offscreenFolderHeaderIds: Set<String> = []
    /// Global Y of the list's visible top edge (under the nav bar), measured
    /// by the mini-bar overlay. The header probe compares its own global
    /// frame against this to decide "scrolled out". Changes on rotation only.
    @State var folderMiniBarTopY: CGFloat = 0
    /// [T-ios-folder-accordion-scroll-anchor] Last observed global minY of each
    /// folder header row, keyed by folder id. Written by a lightweight probe on
    /// every header (collapsed ones included — the accordion needs the position
    /// of the header ABOUT to expand, which by definition is still collapsed
    /// when the tap lands). Read once per toggle to decide whether a scroll
    /// correction is needed at all; never drives layout, so the per-frame writes
    /// cost nothing but a dictionary store.
    @State var folderHeaderTopY: [String: CGFloat] = [:]
    /// The list's visible BOTTOM edge in global coords, the lower bound of the
    /// "still on screen" test. Paired with `folderMiniBarTopY` (the top edge).
    @State var folderListBottomY: CGFloat = 0
    /// Memo for the sidebar grouping — see SidebarGroupsMemo. Keeps the
    /// O(N) partition + per-folder aggregation off every AttributeGraph
    /// flush (activity ticks during streaming re-eval this body at high
    /// frequency, including mid-scroll).
    @State var sidebarGroupsMemo = SidebarGroupsMemo()
    /// Pending "move to folder" — non-nil presents the picker sheet. Shared by
    /// the multi-select toolbar and the row context menu (single-selection is a
    /// one-element set).
    @State var folderPickerRequest: FolderPickerRequest?
    /// Set when the picker applied a move that originated from multi-select;
    /// selection mode is exited in the sheet's onDismiss (not in the apply
    /// callback) to avoid the documented animation conflict.
    @State private var folderMoveApplied = false
    // Folder-header context-menu state (rename / dissolve / delete-all / new chat).
    @State var folderToRename: ChatFolder?
    @State var renameFolderText = ""
    @State var renameFolderDesc = ""
    @State var folderToDissolve: ChatFolder?
    /// When delete-all runs for a folder, the (by then empty) folder row is
    /// dropped after the sessions are gone. Cleared on cancel in onDismiss.
    @State var pendingDeleteFolderId: String?
    /// "New chat in folder": the folder intent rides with the DRAFT ID, not a
    /// bare flag — a draft is promoted to a real row only on first message, so
    /// folder_id can't be written at draft time, and keying on the draft id
    /// means an abandoned draft never mis-files a later unrelated session.
    @State var pendingFolderDraft: (draftId: String, folderId: String)?
    /// Folder id currently hovered by a drag (empty string = the "ungroup"
    /// target on a date-bucket header). Drives the drop highlight.
    @State var dropTargetFolderId: String?
    /// [T-ios-session-list-equatable-jank] id → ChatSession lookup backing the
    /// sidebar rows. Held in @State (not a per-body-eval computed `[String:
    /// ChatSession]`) on purpose: a plain `let byId = computedDict` inside the
    /// List builder was captured as an AttributeGraph node input, so EVERY
    /// transaction flush deep-compared the whole dictionary
    /// (Dictionary.== → ChatSession.== × N) — the dominant scroll-deceleration
    /// CPU cost (HangDetector: flushTransactions → AGGraphSetOutputValue →
    /// Dictionary.== → ChatSession.==; Instruments: app-update phase 60–587ms
    /// spikes). @State is diffed by storage-box identity, not by deep value, so
    /// reading it from the row closure costs nothing per frame. Rebuilt only
    /// when `sessions` changes (see .onChange below).
    @State var sessionsByIdCache: [String: ChatSession] = [:]
    /// Soul name shown as the sidebar title. Sourced from SOUL.md, falls
    /// back to "Minis". Refreshed whenever SoulStore posts .soulMdChanged.
    @State var soulName: String = SoulStore.cachedMetadata.displayName
    /// Subtitle state shown under the "Minis" sidebar title. nil hides the
    /// row; otherwise it renders as small capsules per type or a single
    /// status string. Refreshed by a 5s timer.
    @State var migrationSubtitle: SyncSubtitleState?

    enum SyncSubtitleState: Equatable {
        case paused
        case migrating(percent: Int, byType: [(label: String, count: Int)])
        case syncing(byType: [(label: String, count: Int)])
        case upToDate
        /// Engine is not running yet (boot delay / transport still
        /// connecting / coming back from background). Title shows a
        /// neutral 'waiting' icon — not an error.
        case waiting

        static func == (a: SyncSubtitleState, b: SyncSubtitleState) -> Bool {
            switch (a, b) {
            case (.paused, .paused): return true
            case (.upToDate, .upToDate): return true
            case (.waiting, .waiting): return true
            case (.migrating(let p1, let t1), .migrating(let p2, let t2)):
                return p1 == p2 && t1.map { $0.label + "\($0.count)" } == t2.map { $0.label + "\($0.count)" }
            case (.syncing(let t1), .syncing(let t2)):
                return t1.map { $0.label + "\($0.count)" } == t2.map { $0.label + "\($0.count)" }
            default: return false
            }
        }
    }
    // [T-ios-migration-timer-sessionlist-uaf-crash] The migration-subtitle
    // refresh cadence used to be a process-lived `Timer.publish(every:5).autoconnect()`
    // subscribed via `.onReceive` on the sidebar Group (see sessionList). A
    // process-lived Combine publisher whose sink attribute AttributeGraph rebuilds
    // on every body transaction is a use-after-free hazard: a 5s tick delivered into
    // the sink while the graph tears down/rebuilds that attribute releases a dangling
    // sink closure (crash below). Replaced with a `.task`-driven async loop whose
    // lifetime SwiftUI owns and cancels deterministically — no graph-bound publisher.
    // See migrationSubtitleRefreshInterval / migrationSubtitleLoop.
    @State var remoteDeviceSessions: [(device: SyncDevice, sessions: [ChatSession])] = []
    // showSettings consolidated into activeToolSheet (.settings)
    @State var showTerminal = false
    @State var showAlarmList = false
    @State var hasAlarms = false
    @State var activeToolSheet: ToolSheet?
    #if DEBUG
    // [debug] Keep the screen awake (disable the idle/auto-lock timer) while the
    // app is in the foreground. Memory-only on purpose — NOT persisted, so it
    // resets to off on every app launch. iOS automatically clears
    // `isIdleTimerDisabled` when the app leaves the foreground, so this is
    // re-applied on scenePhase == .active below; "foreground only" falls out for
    // free. Toggled from the DEBUG-only menu item in the sidebar more-menu.
    @State var keepScreenAwake = false
    #endif
    @StateObject private var browserPool = BrowserTabPool()
    @State var selectedSessionId: String?
    /// Shadow of the previously-selected session id, used to identify the
    /// outgoing vm in `onChange(selectedSessionId)` so we can suspend it
    /// for the AttributeGraph race window. SwiftUI's iOS 16 onChange API
    /// only delivers `newValue`; we maintain the previous value ourselves.
    @State private var previousSelectedSessionId: String?
    /// [T-ios-session-coldload-listsessions-block] Coalesces the delayed
    /// outgoing-session preview refresh so rapid session switching schedules
    /// one trailing listSessions() (after the incoming load settles) instead
    /// of stacking full scans onto the serialized ChatStore actor.
    @State var outgoingPreviewRefreshWork: DispatchWorkItem?
    // [T-ios-listsessions-refresh-coalesce] Serialize session-list refreshes so
    // the ~12 refresh call sites never run listSessions() concurrently. A second
    // request that lands while one is in flight sets `pending` and is served by a
    // single trailing run — instead of each site spawning its own Task and
    // assigning its own array snapshot (the memgraph showed 3 live [ChatSession]
    // arrays from concurrent refreshes). Combined with the ChatStore-side cache
    // (T-ios-listsessions-cache), a clean refresh now returns the same cached
    // array, so this mainly prevents redundant Task churn.
    @State var sessionRefreshInFlight = false
    @State var sessionRefreshPending = false
    /// Whether the initial session load has completed (prevents showing the list before we decide to auto-navigate).
    @State var didInitialLoad = false
    /// Controls sidebar visibility on iPad (automatic handles iPhone collapse).
    @State var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Launch screen preference: 0=Auto, 1=Last Session, 2=New Chat.
    @AppStorage("launchScreen") var launchScreen: Int = 0
    /// FAB position preference: false = right (default), true = left.
    @AppStorage("fabOnLeft") var fabOnLeft = false
    /// Mirror of `SyncV2Bootstrap.isEnabled` so SwiftUI re-evaluates
    /// the iCloud-gated menu entries (per-session Force Sync / Force
    /// Pull and the multi-select Force Sync) the moment the user
    /// flips the toggle in Settings — without this, calling the
    /// static getter inline would only re-read on the next unrelated
    /// state change. `SyncV2Bootstrap.setEnabled` writes the same key.
    @AppStorage("cloudSync.v2.enabled") var iCloudSyncEnabled: Bool = false
    /// Current drag offset of the FAB (reset to 0 on drop).
    @State var fabDragOffset: CGFloat = 0

    // Multi-select
    @State var isSelecting = false
    @State var selectedIds: Set<String> = []
    /// Transient banner shown after a Force Sync action runs against
    /// a selection. Cleared after a few seconds via DispatchQueue.
    @State var forceSyncToast: String? = nil
    @State var forceSyncInFlight = false
    @State var scrollToId: String?
    @State var showDeleteConfirm = false
    @State var isComputingDelete = false
    @State var showExportPreview = false
    @State var isExporting = false
    @State var exportFileURL: URL?
    /// [T-export-preview-blank] The UNZIPPED payload backing `exportFileURL`, used
    /// only to render the preview. `exportFileURL` is the artifact the user shares
    /// or saves (a .zip), and zip bytes cannot be decoded as text — previewing it
    /// produced a blank page. Nil when there is nothing text-previewable.
    @State var exportPreviewURL: URL?
    @State var exportProgress: (done: Int, total: Int)? = nil
    @State var exportSummary: ExportSummary? = nil
    @State var deleteInfo: DeleteInfo?

    // Single delete
    @State var sessionToDelete: ChatSession?
    @State var singleDeleteInfo: DeleteInfo?

    // Title regeneration
    @State var regeneratingTitleSessionId: String?

    // Edit session
    @State var sessionToEdit: ChatSession?

    // [T-ios-crash-contextmenu-uaf] Stable action relay for session context menus.
    @State var menuActions = SessionMenuActionChannel()

    // Search
    @State var showSearchBar = false
    var isSearching: Bool { showSearchBar && !searchText.isEmpty }
    @State var searchText = ""
    /// Session IDs that matched the current search query (nil = no active filter).
    @State var searchMatchedIds: Set<String>?
    /// Per-session matched-content snippet for sessions whose match was on
    /// message body rather than title — surfaced in the row's subtitle slot
    /// in place of the generic `lastMessage` preview. Empty when no active
    /// search or for title-only matches. Mirrors Android
    /// `SessionListViewModel.searchSnippets` (commit 545d585).
    /// T-search-highlight 8edb74f2.
    @State var searchMatchSnippets: [String: String] = [:]
    @State var searchTask: Task<Void, Never>?

    /// Width threshold below which the layout collapses to single-column (iPhone-style).
    private let compactThreshold: CGFloat = 700
    /// Whether the device is an iPad (iPhones always use stack layout regardless of width).
    private let isIPad = UIDevice.current.userInterfaceIdiom == .pad
    /// Whether the current window is wide enough for two-column layout.
    @State var isWideLayout = false
    /// Navigation path for stack (compact) layout.
    @State var navigationPath = NavigationPath()
    /// Tracks the session ID currently visible on the compact navigation stack.
    @State var currentStackSessionId: String?
    /// [T-ios-stacknav-transition-attributegraph-race] Compact-layout analogue
    /// of `previousSelectedSessionId`: the session that was on the stack before
    /// the most recent `navigationPath` change, so the `onChange` observer can
    /// suspend the OUTGOING vm for the transition.
    ///
    /// A separate property is required — `currentStackSessionId` cannot serve
    /// here. `.onChange` is a view-update observer, so it runs after the state
    /// change is committed, and every navigation helper assigns
    /// `currentStackSessionId = newId` in the same synchronous block that
    /// mutates the path (see `switchToSession` / `handleNewChatRequest` /
    /// `openSession`). By observer time it therefore already holds the INCOMING
    /// id, and reading it would suspend the wrong vm — the one being mounted.
    @State var previousStackSessionId: String?
    /// The real session ID after a draft session is persisted (iPad only).
    /// While set, the AIChatView for this session stays alive even though
    /// selectedSessionId may still be a draft ID.
    @State var newSessionRealId: String?
    /// The draft ID that owns the current new-session view (iPad only).
    /// Used to redirect back when the user taps the real session row.
    @State var activeDraftId: String?

    /// Last `QuickActionRouter.newChatTrigger` value we've already routed.
    /// SwiftUI's `onChange` fires for transitions, not for initial values,
    /// so we use this to decide whether `onAppear` (or `onChange`) still
    /// owes a `handleNewChatRequest()` call.
    @State var consumedQuickActionTrigger: Int = 0

    /// Set when `handleNewChatRequest()` had to pop the iPhone
    /// NavigationStack before it could open the new draft session.
    /// `onChange(of: navigationPath.count == 0)` watches this and
    /// dispatches the new-draft open once the pop has fully settled.
    @State var pendingNewChatAfterPop: Bool = false
    /// Pre-computed session id for the pending pop+open dance, so the
    /// id we hand to `QuickActionWorkflow.attachTargetSession` here
    /// matches the one `openSession` will use after the pop commits.
    @State var pendingNewChatTargetId: String? = nil

    /// [T-ios-bg-nav-push-watchdog] A `navigationPath` write that arrived while
    /// the app was NOT active, held back until it is.
    ///
    /// Four `.ips` reports (1.12(16) 03:58 + 04:09, 1.13(1) 19:28 + 20:04, all
    /// `WatchdogVisibility: Background`) share one main-thread stack:
    ///
    ///     NavigationStackCoordinator.update(to:from:navigationController:…)
    ///     → UIKitNavigationController.pushViewController(_:animated:)
    ///     → -[UINavigationController _immediatelyApplyViewControllers:…]
    ///     → -[UINavigationBar _redisplayItems]
    ///     → -[UIView(Hierarchy) layoutBelowIfNeeded]      ← synchronous, whole tree
    ///
    /// `_immediatelyApplyViewControllers` is the non-animated branch: it runs
    /// the pushed screen's ENTIRE first layout pass inline, with no yield point.
    /// The screen being pushed is always `AIChatView` (the sole
    /// `navigationDestination` below) — the heaviest view in the app — so that
    /// pass costs hundreds of ms even on a good day.
    ///
    /// The reports' CPU statistics show the main thread pinned at ~100% of one
    /// core for the whole window (10.230s of application CPU inside a 10.00s
    /// scene-update allowance; 5.309 / 5.643 / 5.517s inside the 5.0s
    /// terminate allowance — the "17% CPU" line is percent-of-six-cores). No
    /// other thread holds a lock; SwiftUI's AsyncRenderer is itself parked on
    /// `_MovableLockLock` waiting for the ViewGraph lock main holds. So this is
    /// a compute-bound main-thread stall, not a deadlock.
    ///
    /// While the agent loop runs backgrounded (`beginBackgroundTask("AgentLoop")`
    /// + silent-audio keep-alive), notification / deep-link / QuickAction /
    /// share routes can all still write `navigationPath`. Backgrounded, that
    /// push renders nothing a user can see, yet spends its full layout cost
    /// inside the 5s termination or 10s scene-update budget — and the process
    /// gets SIGKILL'd. (The 03:58 report's `procExitAbsTime` lines up exactly
    /// with the 04:09 report's `procLaunch`: killed, relaunched, and killed
    /// again 11 minutes later on the same path.)
    ///
    /// Deferring costs nothing: the destination is offscreen either way, and
    /// on foreground return the same layout runs with a full frame budget
    /// instead of against a watchdog clock.
    ///
    /// Carries the deferral instant so a stale request can be dropped rather
    /// than flushed — see `pendingBackgroundNavigationTTL`.
    @State var pendingBackgroundNavigation: (path: NavigationPath, deferredAt: Date)?

    /// [T-ios-bg-nav-push-watchdog] How long a deferred push stays valid.
    ///
    /// The gate above answers "don't push while backgrounded"; this answers
    /// "…but for how long is that push still what the user wants?". A push
    /// deferred at 02:00 by a background agent-loop notification is not a
    /// destination the user asked for when they open the app at 09:00 to
    /// glance at the session list — flushing it would yank them into an
    /// unrelated session with no action of theirs behind it. That is a
    /// navigation-semantics bug, not a crash, but it is the direct cost of the
    /// deferral this mechanism introduced, so it belongs here.
    ///
    /// 90s: the case worth honouring is "user taps a notification / deep link,
    /// app foregrounds, push lands" — that round trip is seconds, and even a
    /// slow cold launch with a rootfs warm-up stays well inside a minute.
    /// Anything older is the app having sat suspended, where the reopen is far
    /// more likely to be the user's own intent than a reply to that stale
    /// request. Deliberately much tighter than the 15-minute "latest session is
    /// stale, open a new one instead" heuristic further down: that one picks
    /// between two reasonable destinations, whereas this one decides whether to
    /// override where the user just chose to be.
    static let pendingBackgroundNavigationTTL: TimeInterval = 90

    // 分段保留修饰符顺序，限制每段的类型推断规模。
    private var navigationContent: some View {
        GeometryReader { geo in
            let wide = isIPad && geo.size.width >= compactThreshold
            Group {
                if wide {
                    splitLayout
                } else {
                    stackLayout
                }
            }
            .overlay(alignment: .top) {
                if let toast = forceSyncToast {
                    ForceSyncToastBanner(text: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: forceSyncToast)
            .onChange(of: wide) { newWide in
                isWideLayout = newWide
            }
            .onAppear {
                isWideLayout = wide
                wireMenuActions()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .sessionDidCreate),
            perform: handleSessionCreatedForPendingFolder
        )
        .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in
            handleNewChatRequest()
        }
        // Cold-launch belt-and-braces: a Home Screen Quick Action that
        // fires before `.onReceive(.newChatRequested)` is attached
        // (WindowGroup still mounting) would otherwise be lost. The
        // router bumps `newChatTrigger` whenever it handles a shortcut.
        //
        // `quickActionRouter` is an `@ObservedObject`, so SwiftUI re-runs
        // body on every bump and `onChange` actually fires. The
        // `consumedQuickActionTrigger` state below tracks the last value
        // we've already routed — on cold launch the router might bump to
        // 1 (or higher, if the user invokes shortcuts multiple times
        // before the WindowGroup mounts) BEFORE our `.onAppear` runs;
        // we therefore also check the initial value on appear and route
        // any unconsumed bumps then.
        .onChange(of: quickActionRouter.newChatTrigger) { newValue in
            guard newValue != consumedQuickActionTrigger else { return }
            consumedQuickActionTrigger = newValue
            handleNewChatRequest()
        }
        .onReceive(QuickActionWorkflow.shared.$state) { newState in
            // Workflow advanced to pendingDispatch (either same-runloop
            // because we were already home, or after markHome fired
            // from a navigation change). Open the new session now.
            if case .pendingDispatch = newState {
                openSessionForPendingQuickAction()
            }
        }
        .onAppear {
            if quickActionRouter.newChatTrigger != consumedQuickActionTrigger {
                consumedQuickActionTrigger = quickActionRouter.newChatTrigger
                // Defer one runloop so the NavigationStack body has a
                // chance to attach `$navigationPath` before we append to
                // it — otherwise the append on a freshly-mounted stack
                // can be lost.
                DispatchQueue.main.async {
                    handleNewChatRequest()
                }
            }
            // The Appearance language picker wrote "pendingSettingsReopen"
            // right before changing appLanguage, which forced the root
            // `.id(appLanguage)` rebuild that just dropped + re-mounted us.
            // Reopen the Settings sheet so the user lands back where they
            // were instead of stranded on the chat list. SettingsSheet's
            // own onAppear pushes the saved destination onto its navPath.
            if UserDefaults.standard.string(forKey: "pendingSettingsReopen") != nil {
                DispatchQueue.main.async {
                    activeToolSheet = .settings
                }
            }
            // [T-ios-bg-nav-push-watchdog] Backstop for the scenePhase flush.
            // `.onChange(of: scenePhase)` only fires on a TRANSITION, so a
            // deferral that happened before this view mounted — a cold launch
            // straight into the background, or a root remount (the
            // `.id(appLanguage)` rebuild above) — would leave the push stranded
            // with no later transition to release it. Deferred one runloop for
            // the same reason the quick-action path above is: the
            // NavigationStack must have attached `$navigationPath` first.
            DispatchQueue.main.async {
                flushPendingBackgroundNavigation()
            }
        }
    }

    private var sessionEventContent: some View {
        navigationContent
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidCreate)) { note in
            guard isWideLayout, let newId = note.object as? String else { return }
            let noteDraftId = (note.userInfo as? [String: String])?["draftId"]
            draftLog.info("🔑DRAFT sessionDidCreate realId=\(newId) noteDraftId=\(noteDraftId ?? "nil") selId=\(selectedSessionId ?? "nil") curReal=\(newSessionRealId ?? "nil") curDraft=\(activeDraftId ?? "nil")")
            // Verify this notification came from the currently active draft.
            // A late notification from a previous (now-destroyed) draft must be ignored.
            guard let selId = selectedSessionId, Self.isNewSessionId(selId),
                  noteDraftId == selId else {
                draftLog.info("🔑DRAFT sessionDidCreate IGNORED (draftId mismatch or not a draft)")
                // [T-ios-state-publish-offmain-crash] ChatStore (an actor) posts
                // .sessionDidCreate/.sessionDidUpdate from its background
                // executor; NotificationCenter delivers synchronously on that
                // thread, so this onReceive closure can run off-main. A bare
                // Task{} started here inherits the (background) execution context,
                // so `sessions =` (a @State write) lands off-main → "Publishing
                // changes from background threads" + AttributeGraph corruption of
                // the [ChatSession]/[String:ChatSession] state it deep-compares,
                // crashing in ChatSession.== / deinit during flushTransactions.
                // This onReceive can be delivered off-main, so hop explicitly —
                // refreshSessionList's @State writes must land on the main thread.
                Task { @MainActor in
                    refreshSessionList()
                }
                return
            }
            newSessionRealId = newId
            activeDraftId = selId
            draftLog.info("🔑DRAFT sessionDidCreate ACCEPTED newSessionRealId=\(newId) activeDraftId=\(selId)")
            // [T-ios-state-publish-offmain-crash] force main-thread @State write
            Task { @MainActor in
                refreshSessionList()
            }
        }
        .onReceive(
            // Throttle (not debounce): session-list updates are infrequent (one
            // per agent tool round, seconds apart), but a long multi-tool task
            // emits a steady stream of them. `.debounce` was reset by every new
            // event, so during a continuously-running task the list NEVER
            // refreshed until the task fully stopped — the row stayed on its
            // stale preview ("No messages yet") the whole time. `.throttle`
            // fires the first event right away and then at most once per second,
            // so the preview keeps up with each tool round without thrashing
            // `listSessions`.
            NotificationCenter.default.publisher(for: .sessionDidUpdate)
                .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
        ) { _ in
            // [T-ios-state-publish-offmain-crash] force main-thread @State write
            Task { @MainActor in
                refreshSessionList()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveInputToSession)) { note in
            guard let targetId = (note.userInfo as? [String: String])?["targetId"] else { return }
            // Skip navigation if the target session is already visible
            if isWideLayout {
                guard selectedSessionId != targetId && newSessionRealId != targetId else { return }
                // Wide layout replaces selection — no stack to worry about
                openSession(targetId)
            } else {
                // [T-ios-moveto-transfer-race] No early-return when the target
                // already reads as current: a swallowed push leaves
                // `currentStackSessionId` set to a target that never appeared,
                // and bailing here is exactly what made a retry do nothing.
                // switchToSession is idempotent, so re-running it for a target
                // that genuinely is on screen is harmless.
                switchToSession(targetId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSessionFromIntent)) { note in
            guard let sessionId = (note.userInfo as? [String: String])?["sessionId"] else { return }
            // [T-notification-tap-vs-launch-session] Warm path owns this
            // navigation: drop the cold-launch buffer copy and stamp the
            // handling time so an in-flight launch `.task` (the post can land
            // during its `await listSessions()`) doesn't clobber the target
            // session with the Launch Session default afterwards.
            NotificationNavigationStore.shared.markHandled()
            // Skip navigation if the target session is already visible
            if isWideLayout {
                guard selectedSessionId != sessionId && newSessionRealId != sessionId else { return }
                openSession(sessionId)
            } else {
                // [T-ios-moveto-transfer-race] Same atomic replacement as the
                // move path — the old animated-pop-then-delayed-push had the
                // same swallowed-push failure mode here.
                guard currentStackSessionId != sessionId else { return }
                switchToSession(sessionId)
            }
        }
        .fullScreenCover(isPresented: $showTerminal) {
            NavigationStack {
                ISHTerminalView(showCloseButton: true)
            }
        }
    }

    private var presentationContent: some View {
        sessionEventContent
        .sheet(isPresented: $showAlarmList, onDismiss: { fetchAlarmsIfNeeded() }) {
            AlarmListView()
        }
        .sheet(item: $activeToolSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsSheet(showTerminal: $showTerminal)
            case .rootfsManagement:
                NavigationStack {
                    RootfsManagementView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { activeToolSheet = nil }
                            }
                        }
                }
            case .browser:
                BrowserSheetView(pool: browserPool)
            case .browserManagement:
                NavigationStack {
                    BrowserManagementView(pool: browserPool)
                }
            case .syncMigrationDetail:
                NavigationStack {
                    SyncMigrationDetailView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { activeToolSheet = nil }
                            }
                        }
                }
            }
        }
        // Something else is taking over the screen (an incoming share, a
        // WebApp deep link, a `.minisbak` opened from Files). iOS will not
        // present a second sheet from the same root while one is up, so a tool
        // sheet left open here silently swallows the new presentation — which
        // is exactly how opening a backup while sitting in Settings did
        // nothing at all. Clearing it lets the incoming content surface.
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllImmersivePresentations)) { _ in
            if activeToolSheet != nil { activeToolSheet = nil }
        }
        .sheet(item: $sessionToDelete) { session in
            DeleteConfirmSheet(info: $singleDeleteInfo, isLoading: false) {
                print("[DELETE] onDelete called for session: \(session.id)")
                deleteSession(session)
                sessionToDelete = nil
                singleDeleteInfo = nil
            }
            .onAppear {
                print("[DELETE] Sheet appeared. singleDeleteInfo is \(singleDeleteInfo == nil ? "nil" : "non-nil, sessionCount=\(singleDeleteInfo!.sessionCount)")")
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $sessionToEdit) { session in
            SessionEditSheet(session: session) { newTitle, newCategory in
                // [T-ios-state-publish-offmain-crash] @MainActor so the @State
                // write after the actor-hop await stays on the main thread.
                Task { @MainActor in
                    await ChatStore.shared.updateSessionTitle(session.id, title: newTitle, category: newCategory)
                    refreshSessionList()
                }
                sessionToEdit = nil
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showDeleteConfirm, onDismiss: {
            if deleteInfo == nil {
                // Deletion was performed — reset selection mode after sheet is fully dismissed
                isSelecting = false
                selectedIds.removeAll()
            } else {
                // Cancelled — a pending delete-folder-with-sessions must not
                // linger and attach itself to a later unrelated delete.
                pendingDeleteFolderId = nil
            }
        }) {
            DeleteConfirmSheet(info: $deleteInfo, isLoading: isComputingDelete) {
                deleteSelectedSessions()
                showDeleteConfirm = false
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showExportPreview) {
            ExportPreviewSheet(fileURL: exportFileURL, previewURL: exportPreviewURL, summary: exportSummary)
        }
        .sheet(item: $folderPickerRequest, onDismiss: {
            // Mirror the delete sheet's pattern (see the comment near
            // computeDeleteInfo): selection state is reset only after the
            // sheet is fully dismissed to avoid animation conflicts.
            if folderMoveApplied {
                folderMoveApplied = false
                isSelecting = false
                selectedIds.removeAll()
            }
        }) { req in
            FolderPickerSheet(
                items: folderPickerItems(),
                sessionIds: Array(req.sessionIds),
                anyFiled: req.anyFiled
            ) { choice in
                Task { @MainActor in
                    switch choice {
                    case .existing(let folderId):
                        await ChatStore.shared.setFolder(folderId, forSessions: Array(req.sessionIds))
                    case .create(let name, let desc):
                        let folder = await ChatStore.shared.createFolder(name: name, desc: desc)
                        await ChatStore.shared.setFolder(folder.id, forSessions: Array(req.sessionIds))
                    case .removeFromFolder:
                        await ChatStore.shared.setFolder(nil, forSessions: Array(req.sessionIds))
                    }
                    refreshSessionList()
                }
                if req.fromMultiSelect { folderMoveApplied = true }
                folderPickerRequest = nil
            }
            .presentationDetents([.medium, .large])
        }
        .modifier(FolderAlertsModifier(
            folderToRename: $folderToRename,
            renameFolderText: $renameFolderText,
            renameFolderDesc: $renameFolderDesc,
            folderToDissolve: $folderToDissolve,
            allFolders: folders,
            memberCount: { fid in sessions.filter { $0.folderId == fid }.count },
            onRename: { folder, name, desc in
                Task { @MainActor in
                    // Always pass desc (empty clears): the dialog is seeded with
                    // the stored value when it opens ([T-folder-rename-desc-wipe]),
                    // so whatever is in the field on Rename is the user's
                    // intended state.
                    await ChatStore.shared.renameFolder(folder.id, name: name, desc: desc)
                    refreshSessionList()
                }
            },
            onDissolve: { folder in
                Task { @MainActor in
                    _ = await ChatStore.shared.dissolveFolder(folder.id)
                    refreshSessionList()
                }
            },
            // [T-folder-duplicate-name] Merge the renamed group into the
            // existing same-named one: move its chats over, then dissolve the
            // now-empty source. Dissolve (not delete) is deliberate — it only
            // ever ungroups, so a mistake here can never cost a session.
            onMergeInto: { source, target in
                Task { @MainActor in
                    let memberIds = sessions.filter { $0.folderId == source.id }.map(\.id)
                    if !memberIds.isEmpty {
                        await ChatStore.shared.setFolder(target.id, forSessions: memberIds)
                    }
                    _ = await ChatStore.shared.dissolveFolder(source.id)
                    refreshSessionList()
                }
            }
        ))
        .overlay {
            if isExporting {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        if let p = exportProgress, p.total > 0 {
                            Text(AppLocalized("Exporting… \(p.done) / \(p.total)"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(AppLocalized("Exporting…"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: isExporting)
            }
        }
    }

    private var startupContent: some View {
        presentationContent
        .task {
            await loadInitialSessionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidFetchChanges)) { _ in
            // [T-ios-state-publish-offmain-crash] cloud-sync fetch fires off-main;
            // force the @State write onto the main thread.
            Task { @MainActor in
                refreshSessionList()
            }
        }
        // [T-ios-session-list-equatable-jank] Keep the id→session lookup cache
        // in sync with `sessions`. Rebuilding here (on actual list mutation)
        // instead of per body-eval is what removes the per-frame Dictionary.==
        // / ChatSession.== diff from the scroll transaction.
        .onChange(of: sessions) { _ in
            rebuildSessionsByIdCache()
        }
    }

    private var navigationEventContent: some View {
        startupContent
        .onChange(of: selectedSessionId) { newValue in
            // [T-ios-session-switch-attributegraph-race] Hosting-view race
            // mitigation: when the user switches between two sessions while
            // both vms are mid-stream, the outgoing AIChatView's UIHostingView
            // subgraph is being torn down at the same instant the new
            // session's hosting views are mounting. A concurrent mutation on
            // the outgoing vm (any @Published delta, scroll signal, etc.)
            // races with `AG::Subgraph::NodeCache::~NodeCache` on the same
            // AsyncRenderer thread → EXC_BAD_ACCESS (build-48 crash
            // Minis-2026-06-01-134710.ips). Suspend the outgoing vm here,
            // then schedule a resume on a short delay so when the user comes
            // back to that session everything catches up. Run before the
            // redirect/tracking-clear logic so we always pin the right id.
            // [T-ios-session-coldload-listsessions-block] Were we leaving a real
            // (persisted, non-new) session? Only then can its list-row preview
            // have drifted and need a navigation-time refresh. Captured before
            // previousSelectedSessionId is overwritten below.
            let hadOutgoingRealSession: Bool = {
                guard let outgoing = previousSelectedSessionId, outgoing != newValue else { return false }
                return !Self.isNewSessionId(outgoing)
            }()
            if let outgoingId = previousSelectedSessionId, outgoingId != newValue {
                if let outgoingVm = ViewModelCache.shared.get(for: outgoingId) {
                    outgoingVm.setSuspendedForTransition(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak outgoingVm] in
                        outgoingVm?.setSuspendedForTransition(false)
                    }
                }
            }
            previousSelectedSessionId = newValue
            if let sid = newValue {
                SessionBadgeStore.shared.remove(.unread, for: sid)
                AIChatViewModel.activeSessionId = sid
            } else {
                AIChatViewModel.activeSessionId = nil
            }
            draftLog.info("🔑DRAFT onChange(selectedSessionId) newValue=\(newValue ?? "nil") realId=\(newSessionRealId ?? "nil") draftId=\(activeDraftId ?? "nil")")
            // If user taps the real session row that was created from a draft,
            // redirect back to the draft ID to preserve the AIChatView instance.
            if let realId = newSessionRealId, newValue == realId,
               let draftId = activeDraftId {
                draftLog.info("🔑DRAFT onChange REDIRECT to draftId=\(draftId)")
                selectedSessionId = draftId
                return
            }
            // Clear new-session tracking when navigating to a different session
            if !Self.isNewSessionId(newValue) {
                draftLog.info("🔑DRAFT onChange CLEAR tracking (non-draft)")
                newSessionRealId = nil
                activeDraftId = nil
            }
            // iPad: detail cleared (newValue == nil) — if a quick-action
            // workflow is ensuring-home, advance it now.
            if newValue == nil, case .ensuringHome = QuickActionWorkflow.shared.state {
                QuickActionWorkflow.shared.markHome()
            }
            // [T-ios-search-focus-sticky] iPad split: selecting a session (or
            // new chat) with an empty search drops the sticky search bar.
            if newValue != nil {
                dismissSearchIfEmptyOnNavigate()
            }
            // [T-ios-session-coldload-listsessions-block] Only refresh the list
            // when LEAVING a real session — that outgoing session's preview may
            // have changed while the user was inside it. Entering never changes
            // existing rows. Even so, this listSessions() is a ~1.4s full scan
            // on a large DB and, on the serialized ChatStore actor, is
            // non-preemptible — if it starts before the incoming session's
            // loadSession() reaches its 2nd actor hop (getMemoryEnabled →
            // loadMessages), that hop waits the whole scan out and the spinner
            // hangs ~1.5s. So DELAY the outgoing-preview refresh well past the
            // incoming load (which completes in ~50-150ms) instead of racing it
            // onto the actor. Content changes are already covered by
            // .sessionDidUpdate / .sessionDidCreate / .cloudSyncDidFetchChanges
            // / pin / delete / edit, so this delayed refresh is belt-and-braces.
            if hadOutgoingRealSession {
                scheduleOutgoingPreviewRefresh()
            }
        }
        .onChange(of: navigationPath) { _ in
            // [T-ios-stacknav-transition-attributegraph-race] The SAME hosting-
            // view teardown race the `selectedSessionId` observer above guards
            // — but that observer only fires in the SPLIT (iPad / wide) layout.
            // iPhone drives navigation through `navigationPath`, so the
            // outgoing chat's vm was NEVER suspended for a push/pop, and the
            // mitigation added for the 2026-06-01 build-48 crash simply did not
            // exist on the compact path.
            //
            // Crash 2026-08-10 19:23 (Minis 1.12(1), iOS 26.5.2, iPhone18,1 —
            // a STACK-layout device): EXC_BAD_ACCESS at 0xffffffff00000000 in
            // AG::Subgraph::~Subgraph → NodeCache::~NodeCache, reached from
            // `NavigationStackCoordinator.navigationController(_:willShow:)` →
            // `ejectDeferred/sanitize` → `replaceRootViewWhenSafe` → a
            // synchronous `ViewGraph.updateOutputs` inside the UIKit
            // transition-completion callback. The device log shows exactly the
            // documented precondition: the agent loop kept streaming straight
            // through the transition and PAST the view's teardown —
            //
            //   19:23:26.731  chat slides offscreen (x=402…804, transition starts)
            //   19:23:26.735  [TOOL:STREAMING] shell_execute …
            //   19:23:27.138  [TOOL:STREAMING] …
            //   19:23:27.213  AIChatView.onDisappear vm.isProcessing=true
            //   19:23:27.349  [TOOL:STREAMING] …   (still mutating after teardown)
            //
            // so @Published deltas were feeding a subgraph while UIKit was
            // invalidating it. Suspend the outgoing vm for the transition,
            // exactly as the split path does, and resume on the same 0.4s
            // delay so the session catches up when the user returns.
            //
            // The outgoing id is tracked separately (`previousStackSessionId`)
            // rather than read from `currentStackSessionId` — see that
            // property's doc-comment for why the latter is already the INCOMING
            // id by the time this observer runs.
            // The incoming id is `currentStackSessionId` only while the path is
            // NON-empty; a pop to the session list leaves it momentarily stale
            // (it is cleared further down in this same handler), so an empty
            // path means "incoming = nothing" and the outgoing vm must still be
            // suspended. Getting this wrong would skip the pop — which is the
            // exact transition the crash log captured.
            let incomingStackId: String? = navigationPath.isEmpty ? nil : currentStackSessionId
            let outgoingStackId = previousStackSessionId
            previousStackSessionId = incomingStackId
            if let outgoingId = outgoingStackId,
               outgoingId != incomingStackId,
               let outgoingVm = ViewModelCache.shared.get(for: outgoingId) {
                outgoingVm.setSuspendedForTransition(true)
                // Unconditional resume on the same 0.4s delay the split path
                // uses. `weak` so a deallocated vm simply drops it, and
                // `setSuspendedForTransition` is guarded on an actual change,
                // so overlapping transitions cannot leave the flag stuck.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak outgoingVm] in
                    outgoingVm?.setSuspendedForTransition(false)
                }
            }
            // [T-ios-search-focus-sticky] iPhone stack: pushing into a session
            // (or new chat) with an empty search drops the sticky search bar.
            // Only on push (path non-empty) — popping back must NOT clear an
            // active search the user is returning to.
            if !navigationPath.isEmpty {
                dismissSearchIfEmptyOnNavigate()
            }
            if navigationPath.isEmpty {
                currentStackSessionId = nil
                AIChatViewModel.activeSessionId = nil
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                // If a quick-action workflow asked us to ensure-home,
                // we're there now — let it advance to pendingDispatch.
                if case .ensuringHome = QuickActionWorkflow.shared.state {
                    QuickActionWorkflow.shared.markHome()
                }
            }
            // [T-ios-session-coldload-listsessions-block] Only refresh when
            // popping back to home (path emptied) — that's when a preview that
            // changed inside the session the user just left needs to show. On
            // PUSH (entering a session, the cold-open hot path) this scan only
            // head-of-line-blocked loadSession on the ChatStore actor. Delayed
            // so it never races the incoming load's actor hops.
            if navigationPath.isEmpty {
                scheduleOutgoingPreviewRefresh()
            }
            fetchAlarmsIfNeeded()
        }
    }

    private var deepLinkContent: some View {
        navigationEventContent
        .onChange(of: shareCoordinator.hasPendingShare) { hasPending in
            if hasPending {
                let hadRecord = SharedContainerStore.loadPendingShare() != nil
                processPendingShare()
                // [T-share-double-raise] Only navigate when this raise actually
                // carried content. A duplicate raise finds the record already
                // consumed; opening a second blank session for it would replace
                // the one the first pass just populated.
                //
                // [T-share-routes-to-background-session] Route to the chat the
                // user is LOOKING AT, and only open a new session when there
                // isn't one.
                //
                // The bug this fixes was never "a share reached an open chat" —
                // it was a share reaching a chat the user was NOT looking at.
                // Device log 2026-08-18 23:55:42: the file landed in session
                // 87B79110, mid-agent-run in the BACKGROUND, purely because
                // that view happened to be mounted; nothing checked whether the
                // share was meant for it.
                //
                // So the destination is decided here, explicitly, and stamped
                // onto the buffer — a foreground chat when there is one, a
                // fresh session otherwise — and only that destination's view is
                // allowed to consume it (see injectPendingShareIfNeeded).
                // `navigationPath.isEmpty ? nil : currentStackSessionId` is the
                // same "what is actually on screen" test the outgoing-session
                // tracker at line ~1879 uses.
                if hadRecord {
                    let foreground: String? = navigationPath.isEmpty ? nil : currentStackSessionId
                    if let foreground {
                        // Already on screen — stamp it and navigate nowhere.
                        shareCoordinator.setBufferTarget(foreground)
                        shareLog.info("[Share] onChange: routing share into the foreground session \(foreground.prefix(16)) (no navigation needed)")
                    } else {
                        let target = Self.makeNewSessionId()
                        shareCoordinator.setBufferTarget(target)
                        shareLog.info("[Share] onChange: no session on screen — opening new session \(target.prefix(16)) for share")
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) { openSession(target) }
                    }
                }
            }
        }
        .onChange(of: deepLink.showEnvironmentVariables) { show in
            if show {
                activeToolSheet = .settings
            }
        }
        .onChange(of: deepLink.showPermissions) { show in
            if show {
                activeToolSheet = .settings
            }
        }
        .onChange(of: deepLink.showAlarmList) { show in
            if show {
                showAlarmList = true
                deepLink.showAlarmList = false
            }
        }
        // Open the SettingsSheet whenever a deep link sets a settings
        // target. SettingsSheet itself reads `deepLink.pendingSettingsTarget`
        // in onAppear/onChange to push the right destination, then clears it.
        .onChange(of: deepLink.pendingSettingsTarget) { target in
            guard target != nil else { return }
            if activeToolSheet != .settings {
                activeToolSheet = .settings
            }
        }
        .onChange(of: deepLink.pendingRootfsManagement) { pending in
            if pending {
                activeToolSheet = .rootfsManagement
                deepLink.pendingRootfsManagement = false
            }
        }
        .onChange(of: deepLink.pendingSessionId) { sid in
            guard let sid, !sid.isEmpty else { return }
            // Switch to the requested session if it exists in the loaded
            // list. If not loaded yet (cold launch with deep link), set
            // it now — the session-load path will pick it up once the
            // list refresh completes.
            selectedSessionId = sid
            deepLink.pendingSessionId = nil
        }
    }

    var body: some View {
        deepLinkContent
        .onChange(of: scenePhase) { phase in
            // [T-ios-scenephase-active-sigkill] Defer ALL .active work off the
            // synchronous callback. Writing @Published (SyncCore.isAppInBackground)
            // here triggers objectWillChange → SwiftUI view invalidation in the
            // same runloop tick as the foreground view-graph re-evaluation → SIGTRAP.
            if phase == .active {
                Task { @MainActor in
                    await Task.yield()
                    // Guard against rapid bg→fg→bg: if scenePhase already
                    // changed back, skip the stale .active work.
                    guard scenePhase == .active else { return }
                    // [T-ios-bg-nav-push-watchdog] Commit any push that arrived
                    // while backgrounded. Runs here — after the `Task.yield()`
                    // that keeps .active work off the synchronous callback — so
                    // the pushed screen's first layout pass lands on its own
                    // runloop turn with a full frame budget, never inside the
                    // foreground-transition tick.
                    flushPendingBackgroundNavigation()
                    fetchAlarmsIfNeeded()
                    if #available(iOS 17.0, *) {
                        SyncCore.shared.isAppInBackground = false
                    }
                    #if DEBUG
                    UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
                    #endif
                    // [T-home-fab-keyboard-inset] Defense-in-depth behind the
                    // structural .ignoresSafeArea immunity on the session lists:
                    // on foreground return with the HOME screen actually showing
                    // (no pushed chat on compact, no selected session on split —
                    // a split chat column may legitimately hold composer focus)
                    // and the inline search bar not focused, no responder is
                    // legitimate. Resign whatever UIKit resurrected during the
                    // background snapshot pass so its stale keyboard inset can't
                    // inflate the window's bottom safe area.
                    if !searchFocused, navigationPath.isEmpty, selectedSessionId == nil {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil)
                    }
                }
            } else {
                if #available(iOS 17.0, *) {
                    SyncCore.shared.isAppInBackground = (phase != .active)
                }
            }
        }
    }

    // 只有 ContentView+<职责>.swift 用到的存储属性：扩展里不能有存储属性，所以放在这里。

    let syncLog = AppLogger(category: "RemoteSync")

    @StateObject var providerStore = ProviderConfigStore.shared
    @State var showAddProvider = false
    @State var showSelectModels = false

    @State var fabDidDrag = false
    @FocusState var searchFocused: Bool

    @State var searchDragOffset: CGFloat = 0
    @State var searchDidDrag = false

    /// Namespace tying the search FAB and the expanded search bar together as one
    /// glass fragment, so the two morph instead of cross-fading (iOS 26+).
    @Namespace var fabGlassNamespace
}

#Preview {
    ContentView()
}
