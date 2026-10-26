//
//  AIChatView.swift
//  Minis - 聊天页（Views/Chat/AIChatView）
//
//  AIChatView：聊天页本体。为一个会话（或草稿、远程设备的只读会话）显示消息列表、
//  输入区、导航栏、横幅、各类 sheet 和全屏预览。
//
//  本文件：CachedViewModel（解析缓存的 AIChatViewModel 的 @StateObject 包装）、
//  AIChatView 的全部存储属性（@State、@StateObject、@AppStorage 等）、init，以及 `body`
//  （类型擦除后的页面内容和 sheet / alert / onChange / onReceive 链）。
//
//  文件地图（从一个 6400 行的大文件拆出；代码逐字移动，对应上游 1.15 的拆分，
//  只保留 MinisX 现有的代码）：
//    AIChatView.swift                 本文件
//    AIChatView+<职责>.swift          按职责分组的 AIChatView 成员：
//      QuickActions       主屏幕 Quick Actions（相机、workflow 交接）
//      ShareInjection     分享扩展条目和 Move to 转移内容注入输入框；Provider 导出 JSON 检测
//      TrailingMenu       "..." 菜单、从菜单新建对话、Force Sync / Force Pull
//      NavigationTitle    principal 工具栏内容：标题、模型选择器、fast mode 开关、
//                         思考等级徽标、标题 pill 的会话快照
//      Banners            内核启动遮罩、错误卡片、DEBUG 的复制会话数据和分叉横幅
//      MessagesArea       消息列表容器、滚动按钮、悬浮工具预览、内容宽度
//      LinkAndDrop        Markdown 图片点击进图库、minis:// 与网页链接路由、
//                         全屏 cover 重置、拖放导入
//      ComposerControls   输入区按钮与行：附件 "+"、斜杠、朗读、语言、麦克风、发送、
//                         输入框 / 波形、iPad 拖拽高度；MinisX：语音草稿入口
//                         （beginVoiceInput、returnToKeyboard）
//      InputBar           键盘处理和带高度记录的 `inputBar` 视图
//      InputPopups        斜杠命令和 @ 提及弹层、行视图、弹层外观、附件网格
//      Send               canSend / canEnqueue、入队、发送
//    Composer/            输入区用到的类型：材质（ComposerSurface）、麦克风按钮、
//                         语音纠错上下文
//    Toolbar/             导航栏 modifier、equatable 门控的 toolbar host 和 "..." 菜单
//    Sheets/              Provider 导入提示、Move to Session、语音语言、压缩摘要、
//                         Token 用量（MinisX：SessionBillingSection 会话费用）
//    Overlays/            Face ID 锁遮罩、空对话目录时间线、会话加载卡片
//    Support/             ChatColors、SystemResourceMonitor、sheet 目标、UIView 辅助
//
//    上游 1.15 有而 MinisX 没有对应代码的文件不建（Banners 里的 topBanners、
//    ChatSendButton、ComposerActionChannel、VoiceSendGate、ChatSearchBar、
//    SubAgentRunDetail、SessionOverrideListParts、ViewWillDisappearHook、
//    SpeedTier+Display 等）。MinisX 独有的代码都放进了职责最接近的上游文件，
//    没有新增 MinisX 专属文件。
//
//  拆分规则：
//    - 存储属性（@State、@StateObject、@ObservedObject、@AppStorage、@Environment 等）
//      留在本文件的 struct 主体里：扩展里不能有存储属性。新状态也加在这里。
//    - `body` 留在本文件，保持一个表达式；新增子视图以计算属性放进 AIChatView+<职责>.swift。
//    - 跨文件使用的声明是 internal（原来是 private）；视为聊天页私有。只在一个文件里
//      用到的类型保持 private。
//    - minisLogger 是文件级 private，每个要打日志的文件各一份（AppLogger 只保存 category，
//      各份等价）。
//    - UIView 的 nearestViewController 扩展必须留在 Support/UIViewHelpers.swift 并保持
//      private：SelectableMarkdownView.swift 里有同名的另一个 private 扩展。
//    - 本目录是 Xcode 同步文件夹：新文件自动加入 Minis target，不用改 project.pbxproj。
//      Swift 文件名在模块内必须唯一。
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

private let minisLogger = AppLogger(category: "MinisURL")

/// Wrapper that resolves an AIChatViewModel from the cache.
/// Used as @StateObject so SwiftUI creates it once per AIChatView lifetime,
/// but the underlying `vm` is the cached (possibly still-running) instance.
@MainActor
final class CachedViewModel: ObservableObject {
    let vm: AIChatViewModel
    /// True if this ViewModel was freshly created (not found in cache).
    let isNew: Bool
    /// Forwards the VM's objectWillChange to this wrapper so SwiftUI
    /// observes all @Published changes through the @StateObject.
    private var cancellable: AnyCancellable?

    init(sessionId: String?) {
        if let sessionId {
            let (cached, isNew) = ViewModelCache.shared.getOrCreate(for: sessionId)
            self.vm = cached
            self.isNew = isNew
            // If the cached VM is stale (iCloud merged new MessageV2 rows
            // for this session while we were on a DIFFERENT session and
            // the foreground reload signal never reached us), trigger a
            // fresh loadSession so the bubble list matches SQLite
            // (T-inbound-message-cached-vm-stale). Cache HIT only —
            // `isNew` already loads from scratch.
            if !isNew, ViewModelCache.shared.consumeStaleFlag(sessionId: sessionId) {
                minisLogger.info("🔑DRAFT CachedViewModel.init sessionId=\(sessionId) — STALE flag consumed, scheduling reload")
                Task { @MainActor [weak vm = cached] in
                    await vm?.loadSession()
                }
            }
            minisLogger.info("🔑DRAFT CachedViewModel.init sessionId=\(sessionId) vm=\(cached.vmInstanceId) isNew=\(isNew)")
        } else {
            let draft = ViewModelCache.shared.createDraft()
            self.vm = draft
            self.isNew = true
            minisLogger.info("🔑DRAFT CachedViewModel.init DRAFT vm=\(draft.vmInstanceId)")
        }
        // Forward VM's objectWillChange → this wrapper's objectWillChange
        // so that SwiftUI re-renders when any @Published property on `vm` changes.
        cancellable = vm.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // iOS 16 fix: When NavigationStack recreates the @StateObject, the new
        // CachedViewModel may wrap a VM that already has messages loaded. Force
        // a re-render so SwiftUI picks up the current state, since objectWillChange
        // events between the old and new subscription may have been lost.
        if !isNew {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }
}

// MARK: - Main View

struct AIChatView: View {
    var sessionId: String? = nil
    /// The draft ID from the parent (e.g. "__new__<UUID>") for notification correlation.
    var draftId: String? = nil
    /// If non-nil, this is a read-only view of a remote device's session.
    var remoteDeviceId: String? = nil
    /// Model group to bind when creating a new session (from long-press FAB).
    var initialGroupId: String? = nil
    @EnvironmentObject var shareCoordinator: ShareCoordinator
    @StateObject var cached: CachedViewModel

    /// The actual ViewModel — always derived from the @StateObject to avoid
    /// the @ObservedObject re-init-on-body-recompute problem.
    /// CachedViewModel is ObservableObject and forwards objectWillChange from its vm,
    /// so SwiftUI observes changes through `cached`.
    var vm: AIChatViewModel { cached.vm }

    /// Whether this view is in read-only mode (remote session).
    private var isReadOnly: Bool { remoteDeviceId != nil }

    /// Binding to vm.inputText, routed through the stable @StateObject.
    var inputTextBinding: Binding<String> {
        Binding(
            get: { cached.vm.inputText },
            set: { cached.vm.inputText = $0 }
        )
    }

    init(sessionId: String? = nil, draftId: String? = nil, remoteDeviceId: String? = nil, initialGroupId: String? = nil) {
        self.sessionId = sessionId
        self.draftId = draftId
        self.remoteDeviceId = remoteDeviceId
        self.initialGroupId = initialGroupId
        // [T-ios-aichatview-eager-cachedvm] Build the CachedViewModel INSIDE the
        // StateObject autoclosure so SwiftUI only constructs it the first time
        // this view's StateObject is created — NOT on every struct re-init.
        // ContentView re-evaluates its body (and thus re-inits AIChatView)
        // whenever ANYTHING it observes changes — a sync recentFetchTimer fire,
        // a scenePhase.active transition, an unrelated @Published — none of
        // which should rebuild the view model. The previous `let c =
        // CachedViewModel(...)` ran eagerly before the autoclosure, so every
        // such re-init did a ViewModelCache lookup + Combine sink + an
        // objectWillChange.send (which itself re-triggered updateUIViewController
        // / applySubViewportCompensation). The MLTRACE idle-window capture showed
        // AIChatView.init firing 8× with no user navigation, each tracking a
        // recentFetchTimer / scenePhase event. Deferring construction makes the
        // re-init a no-op when the StateObject already exists. CachedViewModel.init
        // logs its own creation (🔑DRAFT), so the redundant per-init [SessionLoad]
        // line is dropped.
        _cached = StateObject(wrappedValue: CachedViewModel(sessionId: sessionId))
        AIChatViewModel.onAppearTimestamp = CFAbsoluteTimeGetCurrent()
    }
    @StateObject var oauth = ClaudeOAuthManager.shared
    @StateObject private var geminiOAuth = GeminiOAuthManager.shared
    // Face ID lock state moved into `SessionLockGateOverlay` (separate
    // struct) — keeping the @State / @ObservedObject here pushed the
    // body's generic-type depth past iOS 26's runtime metadata budget
    // and triggered an EXC_BAD_ACCESS stack-overflow during
    // `__swift_instantiateConcreteTypeFromMangledNameV2`.
    @StateObject var speechManager = SpeechRecognitionManager.shared
    @ObservedObject private var mentionIndex = FileMentionIndex.shared
    @ObservedObject var configStore = ProviderConfigStore.shared
    @ObservedObject private var fontSettings = FontSettings.shared
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    @Environment(\.dismiss) var dismiss
    @State var inputFocused: Bool = false
    @State var inputHasSelection: Bool = false
    @State var inputIsScrollable: Bool = false
    /// [T-ios-composer-swipe-send-at-bottom] True when the composer's text is
    /// scrolled to its end (or is short enough not to scroll). Combined with
    /// `inputIsScrollable` to decide whether a vertical drag belongs to the
    /// text's inner scroll or to swipe-to-send. Starts `true` because an empty
    /// composer has nothing to scroll.
    @State var inputAtScrollBottom: Bool = true
    @State var inputBarHeight: CGFloat = 0
    @State var inputBarHeightDebounce: Task<Void, Never>?
    /// [T-voice-inputbar-anim-tail] The most recent ON-SCREEN composer height
    /// reported by onGeometryChange. The debounced commit reads THIS instead of
    /// the height captured when its 300ms timer was armed: the panel's
    /// expand/collapse + transcript-band animations are 280ms, so the value that
    /// arms the timer is routinely a mid-animation sample, and committing it
    /// froze the bottom inset at a transitional height (log 07-14 15:34:
    /// settled=312.67 / 363 while the panel was really 232 → 210). Writing every
    /// callback here and committing the freshest one makes the debounce a
    /// genuine trailing edge.
    @State var latestInputBarFrameH: CGFloat = 0
    /// [T-voice-inputbar-collapse-selfheal] Liveness signal for the composer's
    /// geometry reporting: bumped on EVERY onGeometryChange callback (including
    /// off-screen ones, which still prove the host is laying out), plus the wall
    /// clock of the last one. The foreground health probe compares the tick
    /// across a 900ms window to tell "the composer woke up" apart from "the host
    /// is silent and the bottom of the screen is blank" — the 2026-08-18 01:29
    /// failure, where the last callback preceded the blank bar by minutes.
    @State var inputBarGeometryTick: Int = 0
    @State var inputBarLastGeometryAt: CFAbsoluteTime?
    @State private var inputBarHealthProbe: Task<Void, Never>?
    /// [T-voice-inputbar-stale-height] False until the FIRST non-zero
    /// inputBarHeight lands. The first write (session open / initial composer
    /// layout) is applied IMMEDIATELY (leading edge) so the message list computes
    /// the correct bottom inset on its very first pass and snaps straight to the
    /// bottom — no visible "scroll, pause, scroll" from a late debounced correction
    /// (regression from pure trailing-edge debounce). Only SUBSEQUENT height
    /// changes (voice compact↔expanded transitions that sample mid-animation
    /// frames) go through the 300ms trailing debounce that fixes the stuck
    /// stale-height voice-panel-blank bug.
    @State var didSeedInputBarHeight = false
    /// Swipe-up-to-send drag progress in 0...1. Drives the floating send-arrow
    /// hint opacity / scale and acts as the threshold check on gesture end.
    /// Only updated while the input field has non-empty text.
    @State var sendSwipeProgress: CGFloat = 0
    /// Live finger location within the input-bar coordinate space while a
    /// swipe-up-to-send drag is in progress. Drives the floating send-arrow
    /// hint position so it visually follows the user's finger.
    @State var sendSwipeLocation: CGPoint = .zero
    /// [T-ios-composer-swipe-send-at-bottom] Drag translation at the moment
    /// swipe-to-send took over from the composer's inner scroll, so send
    /// progress is measured from THERE rather than from the drag's origin.
    ///
    /// Without this, one continuous drag that scrolls a long value to its end
    /// would hand off to send with the whole scroll distance already banked in
    /// `value.translation.height` — instantly past the 120pt threshold, sending
    /// a message the user never asked to send. Reset to nil whenever the gesture
    /// ends or the send branch is not active, so each hand-off re-anchors.
    @State var sendSwipeAnchor: CGFloat?
    /// Vertical drag distance (points) above which a swipe-up release fires
    /// `performSend()`. Below this, the hint animates away with no action.
    static let kSendSwipeThreshold: CGFloat = 120
    /// Progress fraction (0...1) at which the release-to-send threshold
    /// engages: haptic tick fires, capsule is fully opaque, and lifting the
    /// finger sends. Set below 1.0 so users get earlier confirmation that
    /// they've reached the trigger zone.
    static let kSendSwipeArmFraction: CGFloat = 0.8

    /// [T-ios-composer-swipe-send-at-bottom] Whether a vertical drag on the
    /// input bar belongs to swipe-to-send rather than the composer text's own
    /// inner scroll.
    ///
    /// Previously this was just `!inputIsScrollable`: the moment the text
    /// overflowed, swipe-to-send was disabled outright and every vertical drag
    /// went to the scroll view — even once the user had already read to the end
    /// and further dragging could not move the content. Now the scroll gets
    /// first claim only while it still has somewhere to go: the user scrolls the
    /// long text through to the bottom, and from there another upward drag
    /// arms the send, matching how a short (non-overflowing) value behaves.
    ///
    /// `inputAtScrollBottom` is trivially true when the text does not overflow,
    /// so the short-text path is unchanged by construction.
    var swipeToSendAllowed: Bool {
        !voiceInputActive && (!inputIsScrollable || inputAtScrollBottom)
    }

    @State var floatingBarHeight: CGFloat = 0
    @State var showFileBrowser = false
    // [T-browser-download-ux-v2] Downloads panel + "Show in Files" locate target.
    @State var showDownloadsPanel = false
    @State private var locateDownloadTarget: DownloadLocateTarget?
    /// Total session count snapshot (persisted in DB) — used to decide
    /// whether to show the New-Chat onboarding directory grid. Only the
    /// "first-time, no sessions yet" case shows it; returning users with
    /// any prior chat skip the grid even when starting a new draft.
    /// Populated lazily on first appearance.
    @State var totalSessionCount: Int? = nil
    @State var showBrowserSheet = false
    @State var showTerminal = false
    @State var terminalInitCommand: String?
    @State var showAttachmentMenu = false
    @State private var isDropTargeted = false
    @State var showCamera = false
    @State var showPhotoPicker = false
    @State var showDocumentPicker = false
    @State var showMoveToSheet = false
    @State var showClearChatConfirm = false
    /// [T-new-chat-menu-entry] Confirmation gate for "New Chat" from the "…"
    /// menu while the current session is still streaming: stopping the task is
    /// destructive enough to warrant an explicit confirm.
    @State var showNewChatStopConfirm = false
    @State var showForcePullConfirm = false
    // [inline-voice] Inline voice input mode: the composer's text area becomes a
    // VAD waveform + live transcript when active. Backed by a shared in-memory
    // preference so the voice/text choice carries across sessions (reset on cold
    // start), like an input method's current state.
    @ObservedObject private var voiceMode = VoiceModePreference.shared
    var voiceInputActive: Bool {
        get { voiceMode.isVoiceActive }
        nonmutating set { voiceMode.isVoiceActive = newValue }
    }
    @StateObject var voiceVM = VoiceInputViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceVoiceMotion
    var voiceTransition: Animation? {
        reduceVoiceMotion ? nil : .smooth(duration: VoiceComposerStyle.transitionDuration)
    }

    /// Global read-replies state — observed so the voice-mode "Read replies" toggle
    /// reflects enabled/muted in lockstep with the global voice-output capsule.
    @ObservedObject var voiceOutput = VoiceOutputState.shared
    @AppStorage("cloudSync.v2.enabled") var iCloudSyncEnabled: Bool = false
    /// [T-codex-fast-mode] Codex Fast Mode toggle ("..." menu, OpenAI OAuth
    /// only). Same key OpenAIProvider reads at request-build time; @AppStorage
    /// so the toolbar (menu checkmark + nav bolt badge) re-renders on flip.
    @AppStorage(OpenAIProvider.fastModeDefaultsKey) var codexFastModeEnabled: Bool = false
    // Observe the in-app language so the view's body re-runs the moment
    // the user switches it. Without this, parts of the chat surface that
    // hold UIKit-bridged strings (PastableTextView placeholder, etc.)
    // keep their captured-at-makeUIView text until the next unrelated
    // state change forces a re-evaluate. The body re-eval propagates the
    // new `String(localized:)` result through to `updateUIView`, which
    // already syncs the placeholder UILabel via its viewWithTag(999) path.
    @AppStorage("appLanguage") private var observedAppLanguage: String = ""
    @State var isForcePulling = false
    @State var forcePullToast: String?
    @State var compactConfirmMessageId: UUID?
    /// True while unsent share-extension content is in the input bar.
    @State var hasInjectedShareContent = false
    @State var showModelPicker = false
    @State var showThinkingLevelSheet = false
    @State var showSessionSkills = false
    @State var showSessionMCPs = false
    @State var showSessionMemory = false
    @State var showEnhancedCacheAlert = false
    @State var showTokenUsage = false
    // [T-ios-json-open-provider-import-prompt] A shared/opened JSON file that
    // looks like a Provider export (providerType + credentialType + models)
    // prompts the user to choose: import as a provider, or add as a chat
    // attachment. Captured here while the confirmationDialog is up — the JSON
    // string for import + a temp-copied file URL for the attachment path
    // (the original shared file is cleaned up right after ingestion).
    @State var pendingProviderImport: PendingProviderImport?
    @State private var providerImportResult: String?
    @State var screenshotPreview: ChatScreenshotPreview?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State var attachmentGridHeight: CGFloat = 0
    @State var transcriptHeight: CGFloat = 0
    /// Tracks how much of recognizedText has already been appended to inputText.
    @State var lastRecognizedLength: Int = 0
    /// Intent-based auto-scroll: stays true until the user actively scrolls up
    @State var topSafeAreaInset: CGFloat = 59
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.scenePhase) var scenePhase

    // MARK: - [T-ipad-composer-resize] Draggable composer height (iPad only)

    /// Persisted composer height as a FRACTION of screen height (e.g. 0.5).
    /// 0 = never resized, so the composer keeps its natural content-driven
    /// height. Stored as a fraction rather than points so the preference
    /// survives rotation, Split View resizes and a move to another iPad.
    @AppStorage("chat.composer.heightFraction") var composerHeightFraction: Double = 0
    /// Live delta while a drag is in flight, in POINTS. Kept separate from the
    /// persisted fraction so an in-progress drag never writes to defaults and a
    /// cancelled gesture leaves no trace.
    @State var composerDragOffset: CGFloat = 0

    /// The drag handle is iPad-only: on iPhone the composer is already close to
    /// the keyboard and a 50%-height composer would leave no readable
    /// transcript, so the affordance is not offered there.
    var composerResizeEnabled: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Upper bound for the composer: half the screen. Beyond this the chat
    /// transcript stops being usable, which is the point of the feature's cap.
    var composerMaxHeight: CGFloat { UIScreen.main.bounds.height * 0.5 }

    /// The resolved text-view height, or nil to let the composer size itself.
    ///
    /// nil is the untouched default — the composer grows with its content up to
    /// the built-in ~120pt cap, exactly as before this feature. Once the user
    /// drags, the stored fraction becomes a FLOOR that the text view is pinned
    /// to, clamped to [default, 50% of screen].
    var composerTextHeight: CGFloat? {
        guard composerResizeEnabled else { return nil }
        let base = composerHeightFraction > 0
            ? UIScreen.main.bounds.height * composerHeightFraction
            : 0
        // A drag in flight applies even before anything is persisted, so the
        // very first drag has something to move away from.
        guard base > 0 || composerDragOffset != 0 else { return nil }
        let start = base > 0 ? base : Self.composerDefaultHeight
        return min(max(start + composerDragOffset, Self.composerDefaultHeight), composerMaxHeight)
    }

    /// The composer's natural cap when it has never been resized. Also the
    /// LOWER bound for a drag, per the requirement that the default height is
    /// the minimum.
    static var composerDefaultHeight: CGFloat { PastableUITextView.defaultMaxHeight }
    /// Face ID lock state — observed so the navbar title can blur in
    /// lockstep with the chat-body SessionLockGateOverlay (both read
    /// `lockStore.isVisuallyLocked(sid)` rather than recomputing the
    /// 4-guard expression independently).
    @ObservedObject var lockStore = SessionLockStore.shared
    /// Opacity for the fallback capsule highlight (animated 3× pulse on model switch).
    @State var fallbackPulseOpacity: Double = 0

    /// Snapshot of the current session's title + category, refreshed when the
    /// session updates (e.g. auto-generated title arrives). Nil until first load.
    @State var titlePillSession: ChatSession?
    /// Session being edited via the title-pill tap. Drives the SessionEditSheet.
    @State var titlePillEditSession: ChatSession?
    /// Default chat title for sessions without a generated title. Sourced
    /// from SOUL.md (`name`), falls back to "Minis". Refreshed on .soulMdChanged.
    @State var soulName: String = SoulStore.cachedMetadata.displayName

    /// True when any sheet or fullScreenCover is presented (suppress auto-focus to avoid keyboard bugs).
    var hasOverlayPresented: Bool {
        showFileBrowser || showBrowserSheet || showTerminal || showCamera
            || showPhotoPicker || showDocumentPicker || showModelPicker
    }

    /// Tracks whether this ChatView is the currently visible screen.
    /// Set to false in onDisappear (e.g. when another page is pushed),
    /// used to suppress auto-focus so the keyboard doesn't pop up behind other pages.
    @State var isChatViewVisible: Bool = false


    // minis:// link preview sheet state — hoisted from MinisOpenURLHandler so
    // sheet presentation originates from a stable window-hierarchy root and
    // plays its slide-up transition correctly. See MinisOpenURLHandler for rationale.
    @State var previewImageFile: URL?
    @State var imageGallery: GalleryPresentation?
    @State var previewVideoFile: URL?
    @State var previewAudioFile: URL?
    @State var previewTextFile: URL?
    @State var previewMarkdownFile: URL?
    @State var previewHTMLFile: URL?
    @State var previewDocumentFile: URL?
    @State var shareFile: URL?
    @State var safariURL: URL?
    @State var fullBrowserURL: URL?
    @State private var fullBrowserIsLocal = false
    /// Filename to show in the "file missing" alert. Set by `handleMinisURLTap`
    /// when `resolveMinisFileURL` returns nil for a tapped `minis://` link
    /// (file was deleted, the session was pruned, or iCloud hasn't synced yet).
    @State var missingMinisFileName: String?

    var body: some View {
        ZStack {
            // Messages — floating tool preview overlaid at bottom
            messagesArea
                .safeAreaInset(edge: .top, spacing: 0) {
                    // Error banner
                    if let error = vm.errorMessage {
                        errorBanner(error)
                    }
                    // Transient notice (e.g. request-level image budget
                    // elision). Auto-dismisses after ~4s.
                    if let notice = vm.transientNotice {
                        Text(notice)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.75))
                            .onAppear {
                                let captured = notice
                                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                    if vm.transientNotice == captured {
                                        vm.transientNotice = nil
                                    }
                                }
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    // Tool preview + input bar stacked at the bottom.
                    // Both overlay on top of the message list for immersive scrolling.
                    //
                    // The slash / mention popup is attached to THIS stack as
                    // a `.overlay(alignment: .bottom)` on a placeholder
                    // sitting just above the input bar — that way SwiftUI's
                    // own layout pins the popup's bottom edge to the input
                    // bar's top edge directly, with no `inputBarHeight`
                    // @State round-trip and no screen-bottom math. The
                    // popup follows the input bar automatically when
                    // attachments / waveform expand it, when the keyboard
                    // animates, or when safe-area insets change.
                    //
                    // Popup uses the EXACT same constraint toolbar uses
                    // with inputBar: bottom edge of popup = top edge of
                    // inputBar, with the SAME gap (i.e. whatever VStack
                    // spacing produces between toolbar and inputBar —
                    // which is 0 here, the visual gap toolbar exhibits
                    // comes from its own internal padding).
                    //
                    // To achieve this without re-implementing layout
                    // math: popup is an `.overlay(alignment: .top)` on
                    // the inputBar with `alignmentGuide(.top){$0[.bottom]}`
                    // — this anchors popup's BOTTOM to inputBar's TOP.
                    // The popup card carries its OWN bottom padding
                    // equal to what the toolbar's own internal bottom
                    // spacing produces, so the visual gap is identical
                    // whether toolbar is visible or not. Popup ALWAYS
                    // sits flush with inputBar top, covering the toolbar
                    // when it's also there.
                    // Wrap input stack in a ZStack so the popup can have a
                    // sibling-level frame (full ZStack size) with proper hit
                    // testing — `.overlay(alignment: .top)` on inputBar was
                    // failing to receive touches for the popup card because
                    // SwiftUI doesn't hit-test overlay content drawn outside
                    // the host's own frame.
                    //
                    // Layout structure (z-order bottom→top inside ZStack):
                    //   1. VStack { toolbar; inputBar } — anchored .bottom
                    //   2. Popup with alignmentGuide pinning its BOTTOM
                    //      edge to inputBar's TOP edge — also anchored
                    //      .bottom, but `alignmentGuide(.bottom) { d in
                    //      d[.bottom] + inputBarHeight }` would require
                    //      reading inputBar height again. Instead we use
                    //      `.padding(.bottom, inputBarHeight)` so the
                    //      popup's bottom edge sits exactly at inputBar's
                    //      top edge. inputBarHeight here is just the input
                    //      bar (NOT including toolbar) so popup covers
                    //      toolbar when both visible.
                    ZStack(alignment: .bottom) {
                        // Tap-outside catcher placed UNDER the popup (declared
                        // first → lower z-order). When the popup is visible,
                        // the catcher fills the ZStack and absorbs taps that
                        // land outside the popup card. Taps on the popup
                        // itself naturally fall through to the popup view
                        // because it sits on top in z-order.
                        if vm.showSlashMenu || vm.showMentionMenu {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if vm.showSlashMenu { vm.dismissSlashMenu() }
                                    else if vm.showMentionMenu { vm.dismissMentionMenu() }
                                }
                        }
                        VStack(spacing: 0) {
                            floatingToolPreview
                                .shadow(color: Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.25) : UIColor(white: 0, alpha: 0) }), radius: 6, x: 0, y: 4)
                            #if DEBUG
                            if isReadOnly {
                                forkBanner
                            } else {
                                inputBar
                            }
                            #else
                            inputBar
                            #endif
                        }
                        // Register the composer (tool preview + input bar) as a
                        // region the global speech capsule must not cover.
                        .capsuleProtectedFrame("inputBar")
                        inputPopupOverlay
                            .padding(.bottom, inputBarHeight)
                    }
                }
                // Collapse the expanded speech player on a tap anywhere in the chat
                // area. Attached as a SIMULTANEOUS TapGesture directly on the content
                // (no full-screen hit-test overlay, which blocked scrolling) so a tap
                // collapses the player while scroll/drag still work normally. The tap
                // only acts when the player is expanded; otherwise it's a no-op.
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if vm.speakEnabled && vm.speechPlayerExpanded {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                vm.speechPlayerExpanded = false
                            }
                        }
                    }
                )
                .overlay(alignment: .bottomTrailing) {
                    floatingSpeechButton
                }
                .overlay {
                    // Session-loading indicator, two flavors by scenario:
                    //  • ENTERING the session (first load, nothing rendered yet)
                    //    → centered soft loading card with a gentle fade+scale
                    //    exit, replacing the abrupt bare system spinner.
                    //  • Any LATER reload (iCloud sync, compaction, stale-cache
                    //    refresh) while content is on screen → keep the small
                    //    unobtrusive spinner; the big card must never cover
                    //    content the user is already reading.
                    ZStack {
                        // Pre-load window: isLoadingSession only flips once
                        // loadSession() actually begins (onAppear → Task →
                        // repairSessionIfNeeded → loadSession), so gating the
                        // card on it alone left a blank screen for that gap.
                        // Treat "real session, nothing loaded yet" as loading
                        // from the very first frame of the push.
                        let enteringUnloaded = sessionId != nil
                            && vm.messages.isEmpty
                            && !vm.hasCompletedInitialLoad
                        if (vm.isLoadingSession || enteringUnloaded) && vm.messages.isEmpty {
                            // Entering: nothing rendered yet — show the dots.
                            // In-place reloads with content on screen (iCloud
                            // sync fetch → reloadMessagesFromDB → loadSession
                            // right after entry is the common case) show NO
                            // overlay at all: the content stays visible and
                            // interactive, and a centered gray "…" right after
                            // the blue entry dots read as a glitch, not
                            // feedback (user report 2026-07-06).
                            SessionLoadingCard()
                                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                                .accessibilityIdentifier("sessionLoadingCard")
                        }
                    }
                    .animation(.easeOut(duration: 0.28), value: vm.isLoadingSession)
                    .allowsHitTesting(false)
                }
                .overlay {
                    SessionLockGateOverlay(sessionId: vm.sessionId)
                }
                .onChange(of: vm.isLoadingSession) { newValue in
                    // [SpinnerTrace] Every transition of the
                    // session-loading overlay logged, so we can confirm
                    // whether a center-spinner report corresponds to
                    // this overlay or some other ProgressView in the
                    // chat.
                    minisLogger.warning("[SpinnerTrace] isLoadingSession → \(newValue) sid=\(vm.sessionId?.prefix(8) ?? "nil") msgs=\(vm.messages.count)")
                }

            // Full-screen kernel boot overlay
            kernelBootOverlay
        }
        .background(ChatColors.background)
        .onDrop(of: [.image, .movie, .fileURL, .data], isTargeted: $isDropTargeted) { providers in
            handleDropProviders(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 16)))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.chatSessionId, vm.sessionId)
        .modifier(NavBarStyleModifier(topSafeAreaInset: $topSafeAreaInset))
        .navigationBarTitleDisplayMode(.inline)
        // [T-ios-navbar-toolbar-host] The ENTIRE toolbar now lives inside an
        // equatable-gated host child. Root cause of the mid-streaming "..."
        // menu refresh (4th attempt, this one from instrumentation): with
        // .toolbar attached on this (per-token re-evaluated) chain, the
        // ToolbarContent builder itself re-ran on EVERY streaming tick
        // (NavbarEval toolbarPass=34/stream) and handed the bridge a brand-new
        // ToolbarContent value each time — which it re-pushed to the
        // UINavigationItem, refreshing the OPEN UIMenu, even while both inner
        // Equatable gates provably held (titleEval=3, menuEval=2). Hosting the
        // toolbar in a child whose body is gated on the displayed inputs means
        // the builder simply never re-runs during a stream: no new
        // ToolbarContent, nothing to re-push, and the native SwiftUI Menu
        // (with the system's round Liquid-Glass chrome) can stay.
        // .equatable() is MANDATORY here, not an optimization hint: device
        // instrumentation (2026-07-17 23:53, == FALSE count 0 while
        // hostEval == toolbarPass) proved SwiftUI does NOT consult a plain
        // Equatable conformance for this generic closure-holding view in the
        // .background position — the gate silently never engaged. EquatableView
        // wrapping is the only guaranteed path to ==.
        .background(
            ChatToolbarHost(key: chatToolbarKey, title: {
                chatNavPrincipalContent
            }, trailing: {
                trailingMenu
            })
            .equatable()
        )
        .sheet(item: $titlePillEditSession) { session in
            SessionEditSheet(session: session) { newTitle, newCategory in
                Task {
                    await ChatStore.shared.updateSessionTitle(session.id, title: newTitle, category: newCategory)
                    refreshTitlePillSession()
                }
                titlePillEditSession = nil
            }
        }
        .alert(AppLocalized("Force Pull Messages"), isPresented: $showForcePullConfirm) {
            Button(AppLocalized("Pull from iCloud"), role: .destructive) {
                runForcePull()
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("This will delete all local messages for this chat and re-download them from iCloud. Local changes that haven't synced yet will be lost. Continue?"))
        }
        // [T-ios-json-open-provider-import-prompt] Shared/opened Provider-export
        // JSON: let the user choose import-as-provider vs add-as-attachment.
        // Extracted into a single modifier so the body's type-check stays cheap.
        .modifier(ProviderImportPromptModifier(
            pending: $pendingProviderImport,
            result: $providerImportResult,
            onImport: { json in configStore.importInstanceJSON(json) },
            onAttach: { url in vm.addFileAttachment(from: url) }
        ))
        .overlay(alignment: .top) {
            if let msg = forcePullToast {
                Text(msg)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: forcePullToast)
        // [T-browser-download-ux-v2] Downloads panel opened from the floating
        // download button (mounted next to the scroll buttons, see
        // downloadFloatingButton). Completed rows jump to the file browser
        // located at the downloaded file in the session workspace.
        .sheet(isPresented: $showDownloadsPanel) {
            BrowserDownloadPanelSheet(sessionId: vm.sessionId ?? "") { filename in
                showDownloadsPanel = false
                locateDownloadTarget = DownloadLocateTarget(filename: filename)
            }
        }
        .sheet(item: $locateDownloadTarget) { target in
            if let sid = vm.sessionId {
                NavigationStack {
                    FileBrowserView(
                        rootPath: AIChatViewModel.minisWorkspacePersistentDir(for: sid),
                        rootLabel: "/var/minis/workspace",
                        highlightFileName: target.filename
                    )
                }
            }
        }
        .alert("Enhanced Cache", isPresented: $showEnhancedCacheAlert) {
            Button("Enable") {
                UserDefaults.standard.set(true, forKey: "enhancedCacheConfirmed")
                cached.vm.enhancedCacheEnabled = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enhanced cache extends the cache TTL from 5 minutes to 1 hour. Cache writes cost more (2x vs 1.25x base price), but cache reads remain cheap (0.1x). Recommended for long coding sessions where request gaps may exceed 5 minutes.")
        }
        .alert(AppLocalized("Context Near Capacity"), isPresented: Binding(get: { vm.showCompactBeforeSendPrompt }, set: { vm.showCompactBeforeSendPrompt = $0 })) {
            Button(AppLocalized("Compact & Send")) {
                vm.compactAndSend()
            }
            // [T-chat-auto-compact-opt-in] One-tap opt-in: compact now AND
            // remember (globally, UserDefaults "autoCompactOnThreshold") to
            // auto-compact without prompting whenever the threshold fires in
            // future conversations.
            Button(AppLocalized("Compact & Enable Auto-Compact")) {
                vm.autoCompactEnabled = true
                vm.compactAndSend()
            }
            Button(AppLocalized("Cancel"), role: .cancel) {
                vm.cancelCompactBeforeSend()
            }
        } message: {
            Text(AppLocalized("Conversation context is nearly full. Compact the history to free up space before sending. Enabling auto-compact will do this automatically from now on."))
        }
        .alert(AppLocalized("Context Full"), isPresented: Binding(get: { vm.showContextExhaustedPrompt }, set: { vm.showContextExhaustedPrompt = $0 })) {
            Button(AppLocalized("New Session")) {
                vm.showContextExhaustedPrompt = false
                vm.cancelCompactBeforeSend()
                NotificationCenter.default.post(name: .newChatRequested, object: nil)
            }
            Button(AppLocalized("Clear Chat"), role: .destructive) {
                vm.showContextExhaustedPrompt = false
                vm.cancelCompactBeforeSend()
                vm.clearChat()
            }
            Button(AppLocalized("Cancel"), role: .cancel) {
                vm.cancelCompactBeforeSend()
            }
        } message: {
            Text(AppLocalized("The conversation context has reached its limit. Start a new session or clear the chat to continue."))
        }
        // [T-new-chat-menu-entry] Streaming guard for the "…" menu's New Chat:
        // confirm → stop the running task, then create; cancel → stay put.
        .alert(AppLocalized("Task Running"), isPresented: $showNewChatStopConfirm) {
            Button(AppLocalized("Stop & New Chat"), role: .destructive) {
                vm.cancel()
                NotificationCenter.default.post(name: .newChatRequested, object: nil)
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("A task is running in this chat. Starting a new chat will stop it."))
        }
        .alert(AppLocalized("Clear Chat"), isPresented: $showClearChatConfirm) {
            Button(AppLocalized("Clear"), role: .destructive) { vm.clearChat() }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("All messages in this session will be permanently deleted."))
        }
        // Bridge VM's slash-command "/clear" request into the local @State that
        // drives the confirmation alert above, so the menu and slash-command
        // entry points share one alert instance.
        .onChange(of: vm.clearChatConfirmRequested) { requested in
            if requested {
                showClearChatConfirm = true
                vm.clearChatConfirmRequested = false
            }
        }
        .alert(AppLocalized("Compact Above"), isPresented: Binding(
            get: { compactConfirmMessageId != nil },
            set: { if !$0 { compactConfirmMessageId = nil } }
        )) {
            Button(AppLocalized("Compact"), role: .destructive) {
                if let id = compactConfirmMessageId {
                    Task { await vm.compactBefore(id) }
                }
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("Messages above this point will be compacted into a summary. This cannot be undone."))
        }
        .offloadPermissionDialog()
        .environment(\.openMinisURL, OpenMinisURLAction { url in
            handleMinisURLTap(url)
        })
        .environment(\.openImageGallery, OpenImageGalleryAction { presentation in
            imageGallery = presentation
        })
        .fullScreenCover(item: $previewImageFile) { fileURL in
            MinisImageFilePreviewView(fileURL: fileURL)
        }
        .alert(
            AppLocalized("File Not Found"),
            isPresented: Binding(
                get: { missingMinisFileName != nil },
                set: { if !$0 { missingMinisFileName = nil } }
            ),
            presenting: missingMinisFileName
        ) { _ in
            Button(AppLocalized("OK"), role: .cancel) { missingMinisFileName = nil }
        } message: { name in
            Text(AppLocalized("\(name) is unavailable. It may have been deleted or not yet synced from iCloud."))
        }
        .fullScreenCover(item: $imageGallery) { presentation in
            MessageImageGallery(items: presentation.items, startIndex: presentation.startIndex)
        }
        .onReceive(NotificationCenter.default.publisher(for: MarkdownImageTapRouter.tappedNotification)) { note in
            handleMarkdownImageTap(note)
        }
        .modifier(DismissImmersiveCoversListener(onDismiss: dismissAllOwnedImmersiveCovers))
        .onReceive(vm.requestComposerFocusSignal) {
            // VM fires this after filling the composer programmatically
            // (e.g. /skill tap) so the keyboard pops up immediately and
            // the user can keep typing without an extra tap on the field.
            inputFocused = true
        }
        .modifier(ChatInputAppendListener(vm: vm, inputFocused: $inputFocused))
        .modifier(RerunFromToolBlockListener(vm: vm))
        .fullScreenCover(item: $previewVideoFile) { fileURL in
            MinisVideoFullscreenPlayer(fileURL: fileURL)
        }
        .sheet(item: $previewAudioFile) { fileURL in
            MinisAudioPreviewView(fileURL: fileURL)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(item: $previewTextFile) { fileURL in
            MinisTextPreviewView(fileURL: fileURL)
        }
        .sheet(item: $previewMarkdownFile) { fileURL in
            MinisMarkdownPreviewView(fileURL: fileURL)
        }
        .sheet(item: $previewDocumentFile) { fileURL in
            MinisDocumentPreviewView(fileURL: fileURL)
        }
        .sheet(item: $shareFile) { fileURL in
            MinisShareSheet(url: fileURL)
        }
        .sheet(item: $safariURL) { url in
            MinisLinkPreviewView(url: url, browserPool: vm.browserTabPool, onExpand: { _ in
                fullBrowserIsLocal = false
                let targetURL = url
                safariURL = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    fullBrowserURL = targetURL
                }
            })
        }
        // Auto-present the in-app preview when a shell tool's stdout emits
        // an OSC MinisOpenURL marker (via /usr/local/bin/minis-open).
        //
        // Dispatch by scheme:
        //  - http/https/about: in-chat WKWebView preview. ToolLiveSheet
        //    observes the same broker and takes priority for web URLs when
        //    it is on top (broker.toolSheetVisible).
        //  - minis://...: chat-resource file preview (image/markdown/html/
        //    pdf/...). Routed through handleMinisURLTap which already
        //    picks the right sheet by extension. Always dispatched here
        //    because ToolLiveSheet cannot host fullscreen file previews.
        //
        // `.dropFirst()` skips the current value that `@Published` delivers
        // to new subscribers on first attach — without it, a chat view
        // created after a previous OSC capture would re-present a stale URL.
        .onReceive(MinisOpenURLBroker.shared.$pendingURL.dropFirst().compactMap { $0 }) { url in
            if MinisOpenURLBroker.isWebScheme(url.scheme) {
                // Skip when a topmost host wants to present the web preview
                // itself: ToolLiveSheet (`toolSheetVisible`) or the
                // full-screen iSH terminal (`terminalVisible`). Otherwise
                // our sheet fights their presentation and the terminal's
                // fullScreenCover gets dismissed mid-animation.
                guard !MinisOpenURLBroker.shared.toolSheetVisible,
                      !MinisOpenURLBroker.shared.terminalVisible else { return }
                withAnimation { safariURL = url }
            } else {
                _ = handleMinisURLTap(url)
            }
            MinisOpenURLBroker.shared.consume()
        }
        .sheet(item: $previewHTMLFile) { fileURL in
            MinisHTMLPreviewView(fileURL: fileURL, onExpand: { _ in
                fullBrowserIsLocal = true
                let targetURL = fileURL
                previewHTMLFile = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    fullBrowserURL = targetURL
                }
            })
        }
        .fullScreenCover(item: $fullBrowserURL) { url in
            let wasLocal = fullBrowserIsLocal
            MinisSafariView(url: url, localFile: wasLocal, onCollapse: {
                fullBrowserURL = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if wasLocal {
                        previewHTMLFile = url
                    } else {
                        safariURL = url
                    }
                }
            })
        }
        .sheet(isPresented: $showFileBrowser) {
            NavigationStack {
                let base = RootfsManager.shared.dataPath
                FileBrowserView(rootPath: base, initialPath: base.appendingPathComponent("var/minis"), rootLabel: "/")
            }
        }
        .sheet(isPresented: $showBrowserSheet) {
            BrowserSheetView(pool: vm.browserTabPool, isAgentBusy: vm.browserTabPool.isAgentBrowsing, onTakeover: {
                vm.browserTakeoverActive = true
            })
        }
        .sheet(isPresented: $showModelPicker) {
            NavigationStack {
                SessionModelPicker(sessionId: vm.sessionId) {
                    await vm.ensureSessionReturningId()
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showTokenUsage) {
            TokenUsageSheet(vm: cached.vm)
                .presentationDetents([.fraction(0.8), .large])
        }
        .sheet(item: $screenshotPreview) { preview in
            ChatScreenshotPreviewSheet(image: preview.image)
        }
        .sheet(isPresented: $showSessionSkills) {
            // Pass the real id (nil for a draft) plus an ensure-session closure
            // so a pre-first-message toggle binds its override to the session
            // the chat will actually persist under, instead of the "" phantom
            // key (T-ios-session-skill-override-init-timing).
            SessionSkillsView(sessionId: vm.sessionId) {
                await vm.ensureSessionReturningId()
            }
        }
        .sheet(isPresented: $showSessionMCPs) {
            SessionMCPsView(sessionId: vm.sessionId) {
                await vm.ensureSessionReturningId()
            }
        }
        .sheet(isPresented: $showSessionMemory) {
            SessionMemoryView(vm: cached.vm)
        }
        .sheet(isPresented: $showMoveToSheet) {
            MoveToSessionSheet(currentSessionId: vm.sessionId) { targetId in
                // [T-ios-moveto-transfer-race] Stash bound to the target, so
                // only that session can consume it.
                let movedText = vm.inputText
                let movedAttachments = vm.attachments
                let stash = ViewModelCache.PendingTransfer(
                    targetId: targetId,
                    inputText: movedText,
                    attachments: movedAttachments
                )
                ViewModelCache.pendingTransfer = stash
                // Clear the source composer optimistically so the move reads as
                // instant, but keep a copy: if the target never consumes the
                // stash (navigation swallowed, wrong session opened), restore it
                // here rather than letting the user's content vanish. Attachment
                // files are NOT deleted on this path — both the stash and this
                // restore reference the same cacheURLs.
                vm.inputText = ""
                vm.attachments.removeAll()
                // The share content is no longer here — reset the flag that
                // gates the "Move to…" pill. Currently `hasMovableShareContent`
                // hides the pill anyway now the composer is empty, so this is
                // not user-visible, but leaving it true is a latent trap for
                // anything else that reads it.
                hasInjectedShareContent = false
                DispatchQueue.main.asyncAfter(deadline: .now() + ViewModelCache.PendingTransfer.staleAfter) {
                    // Match the exact stash we staged, not just its target: a
                    // second move to the same target within the stale window
                    // replaces the slot, and this timer must not restore that
                    // newer content out from under it.
                    guard let stranded = ViewModelCache.pendingTransfer,
                          stranded.targetId == targetId,
                          stranded.createdAt == stash.createdAt else { return }
                    // Still sitting in the slot → nobody consumed it.
                    ViewModelCache.pendingTransfer = nil
                    minisLogger.info("[MoveTo] Transfer to \(targetId) was never consumed — restoring content to source session")
                    if vm.inputText.isEmpty {
                        vm.inputText = movedText
                    } else if !movedText.isEmpty {
                        vm.inputText += "\n" + movedText
                    }
                    vm.attachments.append(contentsOf: movedAttachments)
                }
                // Dismiss keyboard first so it doesn't linger during transition
                inputFocused = false
                // Post navigation after sheet dismiss animation completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(
                        name: .moveInputToSession,
                        object: nil,
                        userInfo: ["targetId": targetId]
                    )
                }
            }
        }
        .fullScreenCover(isPresented: $showTerminal) {
            terminalInitCommand = nil
        } content: {
            NavigationStack {
                ISHTerminalView(sessionId: vm.sessionId, showCloseButton: true, initCommand: terminalInitCommand)
                    .onAppear {
                        if let sid = vm.sessionId {
                            minisLogger.info("🔍MOUNT Terminal onAppear — re-mounting minis for session \(sid)")
                            vm.mountMinis(for: sid)
                        } else {
                            minisLogger.info("🔍MOUNT Terminal onAppear — no sessionId, skipping mount")
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            minisLogger.info("[QuickAction] fullScreenCover(camera) onDismiss showCamera=\(showCamera)")
        }) {
            // AnyView erases the camera sheet's view tree from the
            // outer body's generic chain. Without it, AIChatView.body's
            // mangled type pushes Swift's runtime type decoder past its
            // recursion limit on cold launch via the share/quick-action
            // path — SIGSEGV in __swift_instantiateConcreteTypeFromMangledNameV2
            // with `attachmentMenuButton.getter` at the stack top (a
            // bystander; whichever leaf the decoder reached when the
            // stack ran out gets named). Same class of crash as the
            // 2026-04-17 `inputBar.getter` blow-up — the
            // `.observingQuickActions(modifier:)` modifier added by
            // T-quick-action-workflow tipped a chain that was already
            // sitting at the threshold. AnyView here is the minimal,
            // surgical cut: it sinks the largest closure in this
            // modifier (CameraPicker + .ignoresSafeArea + .onAppear)
            // into an erased subtree so the outer body type stays
            // demangle-able. Keep until the body is structurally split
            // into separate View structs (v1.10 follow-up).
            AnyView(
                CameraPicker { image in
                    minisLogger.info("[QuickAction] CameraPicker onCapture size=\(Int(image.size.width))x\(Int(image.size.height))")
                    vm.addImageAttachment(image)
                }
                .ignoresSafeArea()
                .onAppear {
                    minisLogger.info("[QuickAction] fullScreenCover(camera) content onAppear — notifying workflow")
                    QuickActionWorkflow.shared.markCoverPresented()
                }
            )
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItems,
                      maxSelectionCount: 50, matching: .any(of: [.images, .videos]))
        .onChange(of: selectedPhotoItems) { items in
            guard !items.isEmpty else { return }
            // [T-ios-photo-pick-placeholder] 1) Insert a loading placeholder chip
            // for every picked item RIGHT NOW (one main-actor batch update), so the
            // user immediately sees how many they picked instead of watching photos
            // trickle in one-by-one. 2) Load all of them CONCURRENTLY via a
            // TaskGroup. 3) Resolve each placeholder in place as its bytes arrive
            // (success → real thumbnail, failure → error chip). The send button is
            // gated on `hasLoadingAttachments` until every item settles.
            let kinds = items.map { item -> InputAttachment.Kind in
                item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) ? .video : .image
            }
            let placeholderIDs = vm.addLoadingPlaceholders(kinds: kinds)

            // Snapshot per-item metadata synchronously (PHAsset fetch + UTI) so the
            // concurrent loaders don't touch SwiftUI state or PhotosUI mid-flight.
            struct PickJob { let id: UUID; let item: PhotosPickerItem; let isVideo: Bool; let ext: String?; let date: Date? }
            let jobs: [PickJob] = zip(placeholderIDs, items).map { pid, item in
                let isVideo = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
                var assetDate: Date?
                if let aid = item.itemIdentifier,
                   let asset = PHAsset.fetchAssets(withLocalIdentifiers: [aid], options: nil).firstObject {
                    assetDate = asset.creationDate
                }
                let ext = item.supportedContentTypes
                    .first(where: { $0.conforms(to: .image) })?
                    .preferredFilenameExtension
                return PickJob(id: pid, item: item, isVideo: isVideo, ext: ext, date: assetDate)
            }
            selectedPhotoItems = []

            Task {
                await withTaskGroup(of: Void.self) { group in
                    for job in jobs {
                        group.addTask {
                            if job.isVideo {
                                if let videoURL = try? await job.item.loadTransferable(type: VideoFileTransferable.self) {
                                    await MainActor.run {
                                        vm.finalizeVideoPlaceholder(id: job.id, from: videoURL.url, originalDate: job.date)
                                    }
                                } else {
                                    await MainActor.run { vm.markPlaceholderFailed(id: job.id) }
                                }
                            } else if let data = try? await job.item.loadTransferable(type: Data.self) {
                                // Preserve original encoded bytes (PNG transparency,
                                // HEIC, animated GIFs, EXIF) — written verbatim.
                                await MainActor.run {
                                    vm.finalizeImagePlaceholder(id: job.id, data: data, fileExtension: job.ext, originalDate: job.date)
                                }
                            } else {
                                await MainActor.run { vm.markPlaceholderFailed(id: job.id) }
                            }
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showDocumentPicker,
            allowedContentTypes: [.image, .pdf, .plainText, .json, .sourceCode, .presentation, .spreadsheet, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    vm.addFileAttachment(from: url)
                }
            case .failure(let error):
                minisLogger.error("File import failed: \(error.localizedDescription)")
            }
        }
        .onAppear {
            let sinceInit = (CFAbsoluteTimeGetCurrent() - AIChatViewModel.onAppearTimestamp) * 1000
            minisLogger.info("[SessionLoad] onAppear T+\(String(format: "%.0f", sinceInit))ms isNew=\(cached.isNew) msgs=\(vm.messages.count)")
            // [T-inputbar-stale-across-reentry] Re-arm the leading-edge seed on
            // EVERY appear. AIChatView is keyed `.id(sessionId)` in ContentView,
            // so re-entering the SAME session reuses the same SwiftUI identity
            // and its @State survives — `inputBarHeight` keeps whatever (possibly
            // wrong) value it last held, and because `didSeedInputBarHeight` is
            // still true the synchronous seed never re-fires. If the composer's
            // geometry doesn't change on re-entry, onGeometryChange emits no new
            // callback either, so nothing ever reconciles it: a too-tall height
            // survives indefinitely across re-renders. Clearing the flag makes
            // the next (guaranteed) geometry callback re-seed authoritatively.
            didSeedInputBarHeight = false
            inputBarHeightDebounce?.cancel()
            inputBarHeightDebounce = nil
            AppLogger(category: "InputBarLayout").info("inputBarHeight re-arm seed on appear (was \(inputBarHeight))")
            vm.sessionId = sessionId
            vm.draftId = draftId
            vm.remoteDeviceId = remoteDeviceId
            vm.initialGroupId = initialGroupId
            // Snapshot total session count once so the New-Chat onboarding
            // grid only appears for first-time users (no prior sessions).
            // [T-ios-session-coldload-listsessions-block] Use the bare
            // COUNT(*) query, NOT listSessions().count — the latter ran 4
            // un-indexable parts_json LIKE subqueries per session (~0.5s cold
            // on a 100k-message DB) and, on the serialized ChatStore actor,
            // head-of-line-blocked the loadSession() dispatched below, which
            // was the reported ~3s cold-open stall. The comment used to claim
            // "single SQLite COUNT" — now the code actually does one.
            if totalSessionCount == nil {
                Task.detached(priority: .utility) {
                    let count = await ChatStore.shared.sessionCount()
                    await MainActor.run { totalSessionCount = count }
                }
            }
            if let sessionId { AIChatViewModel.activeSessionId = sessionId }
            vm.ensureKernelBooted()
            if let sessionId {
                if cached.isNew || (vm.messages.isEmpty && !vm.isLoadingSession) {
                    // Load session if: (a) VM is freshly created, or (b) cache hit but messages
                    // are empty — this can happen on iOS 16 where NavigationStack may recreate
                    // @StateObject unexpectedly, causing isNew=false but an empty VM.
                    minisLogger.info("🔄SESSION AIChatView.onAppear loading session \(sessionId) isNew=\(cached.isNew) msgs=\(vm.messages.count)")
                    // [T-ios-session-coldload-listsessions-block] .userInitiated
                    // so the actual session-open work wins the serialized
                    // ChatStore actor queue over background sidebar-refresh
                    // listSessions() scans that would otherwise starve it.
                    Task(priority: .userInitiated) {
                        // Phase A: auto-repair any sortOrder / legacy marker anomalies
                        // before loading. Cheap no-op if the session is healthy.
                        _ = await ChatStore.shared.repairSessionIfNeeded(sessionId: sessionId)
                        await vm.loadSession()
                    }
                } else if vm.messages.isEmpty && vm.isLoadingSession {
                    // iOS 16 edge case: a previous view instance started loadSession()
                    // but this view appeared before it completed. Wait for it to finish,
                    // then reload if messages are still empty (objectWillChange may have
                    // fired between old and new CachedViewModel subscriptions).
                    minisLogger.info("🔄SESSION AIChatView.onAppear WAITING for in-flight load session=\(sessionId)")
                    Task {
                        // Wait for the in-flight load to complete (poll at short intervals)
                        for _ in 0..<20 {
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                            if !vm.isLoadingSession { break }
                        }
                        // If messages are still empty after the load completed, retry
                        if vm.messages.isEmpty && !vm.isLoadingSession {
                            minisLogger.warning("🔄SESSION AIChatView.onAppear RETRY load — messages still empty after in-flight load for \(sessionId)")
                            await vm.loadSession()
                        }
                    }
                } else {
                    let reuseStart = CFAbsoluteTimeGetCurrent()
                    minisLogger.info("🔄SESSION AIChatView.onAppear REUSING cached vm for \(sessionId) isProcessing=\(vm.isProcessing) msgs=\(vm.messages.count)")
                    // Remount minis for this session (in case another session took over)
                    vm.mountMinis(for: sessionId)
                    // While the user was off this view, an iCloud / LAN
                    // sync may have landed new messages (or applied a
                    // tombstone). reloadMessagesFromDB internally compares
                    // SQLite count + max(sort_order) + (id, sort_order)
                    // hash against the VM's last-known baseline and only
                    // re-renders on diff. Skip when isProcessing — the
                    // active stream owns messages right now and a reload
                    // would clobber the in-flight assistant turn.
                    if !vm.isProcessing && !vm.isCompacting {
                        Task { @MainActor in await vm.reloadMessagesFromDB(reason: "AIChatView.onAppear-reuse") }
                    }
                    vm.consumeDeferredSnapshotIfNeeded()
                    let mountElapsed = (CFAbsoluteTimeGetCurrent() - reuseStart) * 1000
                    // Cached VM already has messages — trigger scroll-to-bottom
                    // since isLoadingSession won't transition and its onChange won't fire.
                    if !vm.messages.isEmpty {
                        vm.forceScrollToBottom.send()
                    }
                    let totalElapsed = (CFAbsoluteTimeGetCurrent() - reuseStart) * 1000
                    minisLogger.info("[SessionLoad] \(sessionId) — REUSE: \(String(format: "%.1f", totalElapsed))ms [mount: \(String(format: "%.1f", mountElapsed)) | msgs: \(vm.messages.count)]")
                }
            } else {
                minisLogger.info("🔄SESSION AIChatView.onAppear nil sessionId — draft mode")
                // Draft session — auto-focus input for immediate typing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard !hasOverlayPresented, isChatViewVisible else { return }
                    inputFocused = true
                }
            }
            minisLogger.info("[Share] AIChatView.onAppear: sessionId=\(sessionId ?? "nil") bufferVersion=\(shareCoordinator.bufferVersion) hasBuffer=\(shareCoordinator.pendingShareBuffer != nil)")
            injectPendingShareIfNeeded()
            injectPendingTransferIfNeeded()
            isChatViewVisible = true
            refreshTitlePillSession()
            // Notify workflow that THIS view is mounted + visible. If
            // the workflow is waiting for our session id, it will
            // transition to chatReady — our state observer below picks
            // that up and flips `showCamera`. Transient draft views
            // (sessionId=nil) won't match the workflow's target and
            // are correctly skipped.
            tryMarkWorkflowChatReady(reason: "onAppear")
        }
        .observingQuickActions(modifier: quickActionObserver)
        .onChange(of: vm.sessionId) { _ in
            refreshTitlePillSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidUpdate)) { note in
            guard let sid = vm.sessionId,
                  let updatedId = note.object as? String,
                  updatedId == sid else { return }
            refreshTitlePillSession()
        }
        .onChange(of: shareCoordinator.bufferVersion) { newVersion in
            // Warm start: user is already in a session when share arrives
            minisLogger.info("[Share] AIChatView.onChange(bufferVersion)=\(newVersion) sessionId=\(sessionId ?? "nil") draftId=\(draftId ?? "nil") hasBuffer=\(shareCoordinator.pendingShareBuffer != nil)")
            injectPendingShareIfNeeded()
        }
        .onDisappear {
            isChatViewVisible = false
            // [T-voice-inputbar-collapse-selfheal] The health probe must not
            // outlive the view — its report would describe a composer that no
            // longer exists.
            inputBarHealthProbe?.cancel()
            inputBarHealthProbe = nil
            if speechManager.state == .recording {
                speechManager.stopRecording()
            }
            // [T-inputbar-keyboard-leaks-to-home] Cut the ONLY channel by which
            // chat composer geometry can reach the HOME screen.
            //
            // `inputBarHeight` is per-view @State and only feeds the message
            // list's bottom inset — it cannot touch home. What CAN is a stranded
            // first responder: leaving the chat while the composer (or the voice
            // transcript editor) still holds focus leaves the keyboard's inset
            // reserved on the WINDOW, and SwiftUI's automatic keyboard avoidance
            // applies that window-wide. The home screen's 新建/搜索 FAB row is a
            // `.safeAreaInset(edge: .bottom)` (ContentView 1213/1326) with no
            // `.ignoresSafeArea(.keyboard)` opt-out, so it reads that inflated
            // bottom safe area and floats upward — the reported symptom. Same
            // failure class as the offscreen-WebView phantom keyboard (8232308a)
            // and the voice-editor stranded responder (4c530bf4); this closes the
            // remaining door, the chat→home transition itself.
            //
            // Blanket-disabling keyboard avoidance on the home FAB row would be
            // the wrong fix — its inline search field legitimately needs to rise
            // with the keyboard. Releasing the responder at the source is correct
            // and is a no-op when nothing is focused.
            inputFocused = false
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
            if let keyWindow, keyWindow.endEditing(true) {
                AppLogger(category: "InputBarLayout").info("chat onDisappear — released a lingering first responder (would have left a phantom keyboard inset on the window)")
            }
            // Capsule auto-shows whenever audio is loaded — no manual activation needed.
            minisLogger.info("🔑DRAFT AIChatView.onDisappear vm=\(vm.vmInstanceId) sessionId=\(sessionId ?? "nil") draftId=\(draftId ?? "nil") vm.sessionId=\(vm.sessionId ?? "nil") vm.isProcessing=\(vm.isProcessing)")
        }
        // [T-voice-bg-fg-gap] Structural immunity: while the voice panel is up
        // and the transcript editor is NOT open, there is no legitimate keyboard
        // in this subtree — so ignore the keyboard safe-area entirely in that
        // state. Device log 2026-07-17 12:12 showed the panel shifting from
        // y=686…778 to y=638…730 (exactly 48pt, the keyboard-accessory height)
        // during the didEnterBackground layout pass: iOS re-asserted a keyboard
        // inset while snapshotting, the app suspended before the matching hide
        // was processed, and no keyboard event fires on foreground return — the
        // zombie inset persisted and the panel floated (the reported bottom
        // gap). Ignoring the keyboard edge in this state makes ANY such stale
        // inset harmless; edit mode (edges: []) keeps normal avoidance so the
        // panel still lifts above the keyboard while editing, and text mode is
        // untouched.
        .ignoresSafeArea(
            .keyboard,
            edges: (voiceInputActive && !voiceVM.isEditingTranscript) ? .bottom : []
        )
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                // [T-voice-inputbar-fg-stale-debounce] iOS changes safe area
                // insets while backgrounded, causing onGeometryChange to fire
                // with shifted geometry. That measurement spawns a debounce
                // Task carrying stale height. Cancel it so the stale value
                // never lands. The post-foreground onGeometryChange re-fires
                // with the correct geometry and enters a fresh debounce.
                // NOTE: do NOT reset didSeedInputBarHeight here. The seed path
                // is synchronous (no debounce) so it would capture a mid-
                // animation frame if the panel is expanding/collapsing when the
                // app returns to foreground — the debounce path is the correct
                // one for an already-visible view.
                inputBarHeightDebounce?.cancel()
                inputBarHeightDebounce = nil
                // [T-voice-inputbar-collapse-selfheal] …EXCEPT when the composer
                // has stopped reporting geometry altogether, which is the one
                // state the note above cannot cover.
                //
                // Device 2026-08-18 01:29 (iPhone 17 Pro, no lock, no manual app
                // switch): a transcript landed and collapsed the panel band in a
                // single frame (transcriptContentHeight 262→42, an intermediate
                // panel frame reaching y=1119 on an 874pt window). The system
                // then drove six inactive↔active cycles in 20s on its own
                // (snapshot / audio-session interruption right after
                // `end(.capture)`), each logging `hadResponder=true`. After
                // `inputBarHeight settled=282.0` at 01:29:15.597 the composer's
                // onGeometryChange NEVER fired again: its SwiftUI host survived
                // with alpha=1 and zero subviews (confirmed live via
                // debug.viewTree — FloatingBarHostingView nkids=0), so the whole
                // bottom of the screen was empty black with no input bar.
                //
                // Nothing could wake it: this subtree deliberately ignores the
                // keyboard safe area while the voice panel is up
                // ([T-voice-bg-fg-gap], see the .ignoresSafeArea above), so the
                // inset churn that would normally force a re-layout is filtered
                // out by design, and onGeometryChange is the ONLY writer of
                // inputBarHeight. The user's own workaround — leave the session
                // and re-enter — worked precisely because `.onAppear` re-arms
                // the seed ([T-inputbar-stale-across-reentry]); this is that
                // same recovery, applied without making the user find it.
                //
                // Re-arm only when the composer is provably not reporting: the
                // last on-screen sample disagrees with the committed height, or
                // no sample was ever recorded. In the healthy case both values
                // match and this is a no-op, so the mid-animation hazard the
                // note above warns about is not reintroduced — a re-seed can
                // only happen where the alternative is a permanently wrong (or
                // missing) bar.
                let committedH = inputBarHeight
                let latestH = latestInputBarFrameH
                let sinceReport = inputBarLastGeometryAt.map { CFAbsoluteTimeGetCurrent() - $0 } ?? -1
                if didSeedInputBarHeight,
                   latestH <= 0 || abs(latestH - committedH) > 0.5 {
                    didSeedInputBarHeight = false
                    AppLogger(category: "InputBarLayout").info("[voice-bgfg] scene active — composer geometry stale (committed=\(committedH) latest=\(latestH) lastReport=\(String(format: "%.1f", sinceReport))s ago); re-arming seed so the next callback re-measures")
                }

                // [T-voice-inputbar-collapse-selfheal] Re-arming only makes the
                // seed ELIGIBLE to fire; it cannot make a host that has stopped
                // reporting geometry start again. In the observed failure that
                // host had zero subviews and emitted nothing for minutes, so
                // verify the wake-up actually happened and say so loudly when it
                // did not — this is the line that tells the next investigation
                // "the self-heal ran and was not enough" instead of leaving them
                // to re-derive it from a silent log.
                inputBarHealthProbe?.cancel()
                let probeBaseline = inputBarGeometryTick
                inputBarHealthProbe = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    guard !Task.isCancelled else { return }
                    let ticked = inputBarGeometryTick != probeBaseline
                    let age = inputBarLastGeometryAt.map { CFAbsoluteTimeGetCurrent() - $0 } ?? -1
                    if ticked {
                        AppLogger(category: "InputBarLayout").info("[InputBarHealth] OK after foreground — composer re-reported geometry (h=\(latestInputBarFrameH) committed=\(inputBarHeight))")
                    } else {
                        AppLogger(category: "InputBarLayout").error("[InputBarHealth] STALLED — no geometry callback 900ms after foreground. committed=\(inputBarHeight) latest=\(latestInputBarFrameH) lastReport=\(String(format: "%.1f", age))s ago voice=\(voiceInputActive) editing=\(voiceVM.isEditingTranscript) seeded=\(didSeedInputBarHeight). The composer host is not laying out; expect a blank bottom area. Leaving and re-entering the session rebuilds it.")
                    }
                }
                // [T-voice-bg-fg-gap] Foreground reseal: if we return to a
                // voice-mode-not-editing state, no responder should be armed.
                // Releasing here is a no-op when nothing is focused and clears
                // any responder UIKit resurrected during the background pass.
                if voiceInputActive && !voiceVM.isEditingTranscript {
                    let keyWindow = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .flatMap(\.windows)
                        .first(where: \.isKeyWindow)
                    if let keyWindow, keyWindow.endEditing(true) {
                        AppLogger(category: "InputBarLayout").info("[voice-bgfg] scene active — released a resurrected responder (voice mode, not editing)")
                    }
                }
            }
            if phase != .active, voiceInputActive, !voiceVM.isEditingTranscript {
                // [T-voice-bg-fg-gap] Complete any in-flight keyboard dismissal
                // BEFORE the snapshot/suspend layout pass — but ONLY in the
                // voice-mode-not-editing state, where no responder is ever
                // legitimate (text mode keeps its focused composer across app
                // switches; edit mode keeps its editor keyboard — resigning
                // those would be a visible regression). If the edit→send
                // teardown's dismiss animation is still running when the app
                // backgrounds, iOS can freeze the window mid-dismissal with a
                // partial keyboard inset that survives into the next foreground.
                // Synchronous resign + no-animation layout guarantees the window
                // geometry is final before UIKit snapshots it.
                let keyWindow = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow)
                if let keyWindow {
                    let hadResponder = keyWindow.endEditing(true)
                    UIView.performWithoutAnimation { keyWindow.layoutIfNeeded() }
                    AppLogger(category: "InputBarLayout").info("[voice-bgfg] scene \(phase == .inactive ? "inactive" : "background") — forced keyboard-dismiss completion (hadResponder=\(hadResponder)) voice=\(voiceInputActive) editing=\(voiceVM.isEditingTranscript)")
                }
            }
            if phase != .active, speechManager.state == .recording {
                speechManager.stopRecording()
            }
        }
        .onChange(of: deepLink.showTerminal) { show in
            if show {
                terminalInitCommand = deepLink.terminalInitCommand
                showTerminal = true
                deepLink.showTerminal = false
                deepLink.terminalInitCommand = nil
            }
        }
        // [T-ios-voiceover-announce] Announce the end of a turn to VoiceOver.
        // Deliberately a SEPARATE observer from the auto-focus handler below:
        // that one returns early when the auto-focus setting is off, and a
        // blind user must still hear that the reply ended regardless of an
        // unrelated keyboard preference. The outcome closure is evaluated at
        // the end edge so it sees the final cancel/error state.
        .announceChatTurnEnd(isProcessing: vm.isProcessing) {
            if vm.userDidCancel { return .stopped }
            if vm.errorMessage != nil { return .failed }
            return .finished
        }
        .onChange(of: vm.isProcessing) { processing in
            if !processing {
                // Reply reading is handled INCREMENTALLY during streaming (the
                // SSE loop splits into sentences/titles + tool announcements and
                // queues them as they arrive — see speakQueued/extractNewSentences).
                // No whole-reply speak here; that would double-read everything.
                // [T-keyboard-auto-pop default flip] Gate behind a Settings
                // toggle. Default ON — most users want the composer ready
                // for a follow-up immediately. `object(forKey:)` lets us
                // distinguish "never toggled" (nil → use new ON default)
                // from "explicitly set OFF" (NSNumber(false) → respect).
                // Existing length-based skip is still applied so very long
                // replies still don't trigger the auto-focus.
                let autoFocusEnabled = (UserDefaults.standard.object(forKey: "chat.autoFocusAfterReply") as? Bool) ?? true
                guard autoFocusEnabled else { return }
                // [T-ios-retry-keyboard] Don't treat the end of a RETRIED turn
                // as "a reply arrived".
                //
                // Trigger chain being cut: the user taps Retry on a failure from
                // a while back -> retry() sets isProcessing=true -> the re-sent
                // request fails fast (kernel down, no concurrency slot, or an
                // immediate provider error) -> isProcessing flips back to false
                // -> this observer fires. The edge is indistinguishable from a
                // successful reply, and the delayed block's guards now all pass
                // (the user IS looking at the chat, nothing is queued, and the
                // errored message is short so the <600 length check succeeds) —
                // so the keyboard rises seconds after a tap that only meant
                // "try that again".
                //
                // Scoped to the turn's ORIGIN, not its outcome: auto-focus when
                // a fresh send fails is existing, accepted behaviour and is
                // deliberately left alone. Consumed (not just read) so it
                // governs exactly one turn.
                let wasRetry = vm.turnStartedByRetry
                vm.turnStartedByRetry = false
                guard !wasRetry else { return }
                if GCKeyboard.coalesced != nil {
                    inputFocused = true
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard !hasOverlayPresented, isChatViewVisible else { return }
                        guard !vm.isProcessing, vm.promptQueue.isEmpty else { return }
                        // Re-check: a retry started during the 1.5s window would
                        // otherwise be focused by this older timer.
                        guard !vm.turnStartedByRetry else { return }
                        let lastAssistantLength = vm.messages.last.flatMap {
                            $0.role == .assistant ? $0.blocks.reduce(0) { $0 + $1.content.count } : nil
                        } ?? 0
                        if lastAssistantLength < 600 {
                            inputFocused = true
                        }
                    }
                }
            }
        }
        // [T-ios-retry-hide-when-processing] Inject the view model so deep
        // descendants (e.g. ToolCapsuleView's long-press menu) can react to
        // `vm.isProcessing` without threading the vm through every level.
        .environmentObject(vm)
    }
}
