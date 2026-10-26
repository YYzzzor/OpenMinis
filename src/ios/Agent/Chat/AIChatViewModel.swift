//
//  AIChatViewModel.swift
//  Minis - 聊天 view model（Agent/Chat）
//
//  AIChatViewModel：一个聊天会话的 view model，持有消息、Agent 循环（请求模型、
//  执行工具）和聊天界面绑定的状态。
//
//  文件地图（从一个 6800 行的大文件拆出；代码逐字移动，对应上游 1.15 的拆分，
//  只保留 MinisX 现有的代码）：
//
//    AIChatViewModel.swift      本文件：全部存储属性（@Published 状态、循环 / 队列 /
//        语音 / 同步状态、信号）、init / deinit，以及几个读起来像状态的小计算属性
//    轮次流程
//        +Send            send()、retry()、resume()、未回复的用户轮次恢复
//        +AgentLoop       runAgentLoop（请求、读流、工具、重复）
//        +Rerun           从某条消息 / 某个工具块重跑，从这里起删除
//        +EditMessage     编辑已发送的消息
//        +Cancel          Stop
//        +PromptQueue     排队的提示词：依次发出、作为新一轮注入
//        +TurnCompletion  完成触感、失败提示、取消后的清理
//        +SSEStream、+ConcurrentTools、+ToolDefinitions、+ToolPreflight、
//        +RequestBudget、+Fallback、+ProviderFactory、+Offloading、+Compaction
//                         （原有扩展文件）
//    提示词与上下文
//        +SystemPrompt    基础系统提示词
//        +ContextUsage    上下文用量、会话 token 统计、模型能力查询
//        +ThinkingLevel   会话思考强度
//    界面辅助
//        +StreamingUI     流式 / 转场闸门、流式文本写入
//        +Speech          语音朗读；+AutoPlayAudio  音频自动播放、MIME 判断
//        +Attachments、+MentionMenu、+SlashCommands   （原有扩展文件）
//    会话与生命周期
//        +Lifecycle       长时间后台的浏览器任务标记、富文本缓存失效
//        +Persistence、+TitleGeneration、+BackgroundTask、+Misc、+Billing
//                         （原有扩展文件）
//    工具
//        +FileTools、+MemoryTools、+ISHCommand   （原有扩展文件）
//    诊断
//        +DebugDumps      agentHistory / 队列日志
//    LLMProviderError.swift  原本在本文件末尾的服务商错误枚举
//
//    上游 1.15 有而 MinisX 没有对应代码的文件不建（+ProgrammaticPrompt、+UserAsk 等）。
//    MinisX 独有的代码都放进了职责最接近的上游文件，没有新建 MinisX 专属文件：
//    上下文用量快照函数在 +ContextUsage，shortFrame 在 +StreamingUI。
//
//  拆分规则：
//
//  - 存储属性留在本类的主体中（扩展不能声明存储属性），顺序与拆分前相同。
//    autoPlayAudioPattern、speechEndersForCut、DeferredStreamingTextUpdate
//    也留在这里，不随各自的函数移动。
//  - 用到日志的扩展文件各自声明文件内的 `logger`（category "AIChatVM"），
//    与原有扩展文件一致。
//  - 被其他文件用到的成员去掉了 `private`；它们仍视为 view model 内部成员。
//  - 新增行为放进对应职责的扩展文件，没有合适的就新建一个。
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

// MARK: - View Model

@MainActor
final class AIChatViewModel: ObservableObject, SpeechControlling {

    /// Maximum characters returned in a single tool result to the model
    static let kMaxToolResultChars = 15000

    /// Maximum number of images retained in agent history when building the
    /// context sent to the model. Older images are replaced with a text
    /// placeholder (containing dimensions + byte size + persisted path) so
    /// they can be re-viewed via the `read_image` tool.
    static let kImageContextKeepCount = 20

    // MARK: - Image byte budgets (T-imgsize-13b7d81c)
    //
    // Anthropic rejects requests whose total inline image payload exceeds
    // 30 MB ("Downloaded image content cannot exceed 30MB" — the 30 MB
    // applies to decoded image bytes, NOT the base64-inflated wire form,
    // so we budget in raw bytes too). Other providers have similar but
    // undocumented caps. We enforce a tighter, pre-encoding budget so the
    // request never reaches the wire too big:
    //
    //   - Per image: 5 MB after JPEG re-encode. The Anthropic SDK's own
    //     per-image soft hint; well under the 30 MB request cap and
    //     ensures a single huge photo can't gobble the whole budget.
    //     Anything bigger runs the compressor ladder (smaller max edge +
    //     lower JPEG quality) until it fits or until we've shrunk it
    //     past readability.
    //   - Per message: 25 MB cumulative across all inlined images.
    //     Leaves ~5 MB headroom under Anthropic's 30 MB request cap for
    //     other parts of the payload (tool results, prior message
    //     attachments echoed back, etc.).
    //   - Above the message cap, additional images are dropped to a text
    //     placeholder (same fallback the count cap already uses).

    /// Hard ceiling per single image after compression. Matches the
    /// Anthropic SDK's per-image hint; well below the 30 MB request cap.
    static let kPerImageMaxBytes = 5 * 1024 * 1024

    /// Hard ceiling across all inlined images in one user message.
    /// 5 MB under Anthropic's 30 MB request cap, leaving headroom for
    /// tool results and prior-turn attachments still in context.
    static let kMessageImageMaxBytes = 25 * 1024 * 1024

    /// Hard ceiling on cumulative inline-image bytes across the FULL
    /// request body (all messages, all tool results). When a long
    /// session accumulates browser screenshots + attachments + read_image
    /// results past this cap, gpt-5.5 via factory.pub silently returns
    /// 200 + empty SSE + `finish_reason=stop` and the client treats the
    /// empty turn as completion (T-request-imgsize). Eldest images are
    /// elided to text placeholders here.
    static let kRequestImageMaxBytes = 25 * 1024 * 1024

    /// Hard ceiling on agent loop iterations within a single user turn.
    /// Backstop against runaway tool-call cycles that slip past
    /// `ToolLoopDetector` (e.g. visited args/results vary just enough to
    /// dodge the global circuit breaker). On reaching the limit the loop
    /// finalizes as resumable — see runAgentLoop's tail — so the user gets
    /// an inline explanation + Resume affordance rather than an unbounded
    /// runaway. Mirrors Android ChatViewModel.MAX_AGENT_TURNS.
    static let maxAgentTurns = 200
    /// [T-chat-auto-compact-inloop] Max in-loop auto-compactions per single
    /// user turn. Beyond this the loop stops as exhausted rather than
    /// compacting endlessly (which would defeat the maxAgentTurns backstop).
    static let maxInLoopCompactions = 3

    /// [StreamDiag] (#181) Monotonic counter tagging each outbound streaming
    /// request so the stall watchdog's log line can be correlated with the
    /// request it belongs to. Main-actor isolated (the whole class is), so the
    /// `&+=` bump needs no additional synchronization. Diagnostics only —
    /// nothing reads this for control flow.
    static var diagRequestSeq: UInt64 = 0

    /// If non-nil, this VM is in read-only mode viewing a remote device's session.
    var remoteDeviceId: String?

    /// Short unique ID for this ViewModel instance (for debugging lifecycle).
    let vmInstanceId = UUID().uuidString.prefix(6)

    /// [T-deferred-sync-reload] Set to true when a
    /// `.cloudSyncDidFetchChanges` notification fires WHILE
    /// `isProcessing == true`. The `$isProcessing` sink drains it on
    /// the false-edge by replaying exactly one `reloadMessagesFromDB`
    /// so the user sees the post-send DB state without waiting for the
    /// next 60s sync timer.
    var pendingSyncReloadOnIdle = false

    // MARK: - Post-stop sync hold (T-ios-defer-icloud-sync-after-stop)

    /// While the agent loop runs (`isProcessing`), and for a grace window AFTER
    /// it stops, BOTH iCloud directions are held: no push to cloud, no pull-
    /// driven local reload. This stops a deferred sync from overwriting the
    /// just-finished candidate the instant the loop ends (field repro: content
    /// vanished + a brief loading flash right after Stop). The hold is released
    /// — and a single catch-up sync (flush dirty push + replay reload) runs —
    /// when the earliest of these happens: the 60s timer fires, the user leaves
    /// the session (back to the list), or the app is backgrounded.
    static let postStopSyncHoldSeconds: TimeInterval = 60
    /// Deadline of the current hold; nil when not held.
    private(set) var postStopSyncHoldUntil: Date?
    private var postStopSyncHoldTimer: Timer?

    /// True while the post-stop grace window is active.
    var isSyncHeld: Bool {
        guard let until = postStopSyncHoldUntil else { return false }
        return until > Date()
    }

    /// Enter the post-stop hold: pause SyncCore (blocks push) for the grace
    /// window and arm a timer that releases at the deadline. Called when the
    /// agent loop transitions to idle.
    @MainActor
    private func beginPostStopSyncHold() {
        let until = Date().addingTimeInterval(Self.postStopSyncHoldSeconds)
        postStopSyncHoldUntil = until
        SyncCore.shared.pause(for: Self.postStopSyncHoldSeconds)
        postStopSyncHoldTimer?.invalidate()
        postStopSyncHoldTimer = Timer.scheduledTimer(withTimeInterval: Self.postStopSyncHoldSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.releasePostStopSyncHold(reason: "timer-60s") }
        }
        logger.info("[SyncHold] BEGIN hold until \(until) (\(Int(Self.postStopSyncHoldSeconds))s) sid=\(self.sessionId?.prefix(8) ?? "nil")")
    }

    /// Release the hold early/at-deadline and run one catch-up sync: resume
    /// SyncCore, flush deferred dirty (push), and replay any pending reload
    /// (pull). Idempotent — safe to call from any of the release triggers.
    @MainActor
    func releasePostStopSyncHold(reason: String) {
        guard postStopSyncHoldUntil != nil else { return }
        postStopSyncHoldUntil = nil
        postStopSyncHoldTimer?.invalidate()
        postStopSyncHoldTimer = nil
        logger.info("[SyncHold] RELEASE reason=\(reason) sid=\(self.sessionId?.prefix(8) ?? "nil") — resuming sync + catch-up")
        SyncCore.shared.resume()
        // Push: flush whatever the agent turn marked dirty.
        Task { await ChatStore.shared.flushPendingSyncDirty() }
        // Pull: replay a deferred reload now that it's safe.
        if pendingSyncReloadOnIdle, !isProcessing, sessionId != nil {
            pendingSyncReloadOnIdle = false
            Task { @MainActor in await self.reloadMessagesFromDB(reason: "syncHoldReleased(\(reason))") }
        }
    }

    /// Cancellable for tracking `isProcessing` → `SessionActivityTracker`.
    private var activityTrackingCancellable: AnyCancellable?
    private var captureSuppressCancellable: AnyCancellable?
    private var mediaPreemptCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    /// Observer for font-size changes to invalidate cached attributed strings.
    private var fontChangeObserver: Any?
    /// Observer for iCloud sync changes to reload messages.
    private var syncChangeObserver: Any?
    /// Observer for group binding changes to update in-memory context limit.
    /// Observer that releases the post-stop sync hold when the app backgrounds.
    private var backgroundSyncHoldObserver: Any?
    /// [T-tool-bg-suspended-hint] Observer firing on foreground return; stamps
    /// still-running browser tool blocks that have spanned a background period
    /// and exceeded the long-run threshold so the chat capsule can hint at the
    /// likely background slowdown. In-memory only (not persisted).
    private var bgHintForegroundObserver: Any?
    private var snapshotForegroundObserver: Any?
    private var detachedLoopEndObserver: Any?
    /// Timestamp of the most recent background-entry, used to detect that a
    /// long-running browser task actually spanned a background period.
    var bgHintBackgroundEntryDate: Date?
    /// A browser tool running longer than this when the app returns to the
    /// foreground (after having been backgrounded) gets the suspension hint.
    static let bgHintBrowserThreshold: TimeInterval = 5 * 60

    init() {
        logger.info("🔄SESSION [vm=\(self.vmInstanceId)] init — new AIChatViewModel created")

        fontChangeObserver = NotificationCenter.default.addObserver(
            forName: .fontSettingsMessageBaseChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.invalidateAttributedStringCaches() }
        }

        // [T-ios-defer-icloud-sync-after-stop] Backgrounding is a release
        // trigger for the post-stop sync hold — let the held catch-up sync run
        // before the app suspends, instead of waiting out the 60s window.
        backgroundSyncHoldObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // [T-tool-bg-suspended-hint] Remember when we went to background so
            // a foreground return can tell a browser task actually spanned it.
            self.bgHintBackgroundEntryDate = Date()
            Task { @MainActor in self.releasePostStopSyncHold(reason: "background") }
        }

        // [T-tool-bg-suspended-hint] On foreground return, flag any still-running
        // browser tool that spanned the background period and has now exceeded the
        // long-run threshold — the WebView/JS is likely throttled or stalled while
        // backgrounded, so the capsule surfaces the "enable enhanced background"
        // hint. In-memory only; mirrors the BackgroundInterruptionTracker gate
        // (skip when enhanced background is already effective).
        bgHintForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.markLongBackgroundBrowserTasks() }
        }

        // [T-ios-bg-blocks-lost] On foreground return, replay the deferred
        // snapshot rebuild if isProcessing went false while backgrounded.
        // When the app is in background with streamingUIUpdatesSuspended=false,
        // bind4b may call applySnapshot but UIKit can silently drop or
        // incompletely apply UICollectionView diffs while not in .active.
        // The isProcessing didSet sets needsSnapshotReloadOnResume=true for
        // this case, but clearStreamingUIUpdatesSuspended won't fire (the
        // flag was never set). This observer is the missing trigger.
        // [T-ios-bg-blocks-lost] Replay the deferred snapshot rebuild when the
        // app returns to .active. Uses didBecomeActiveNotification (not
        // willEnterForegroundNotification) because the deferred path triggers
        // for BOTH .background and .inactive states — inactive→active is
        // common (e.g. Control Center swipe, notification shade pull) and
        // willEnterForeground only fires from background, missing the
        // inactive case entirely.
        snapshotForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // [T-blockslost-defensive defect ②] Gate on being the
                // CURRENTLY-DISPLAYED session. This observer was written
                // (02970b7b) when the flag could only mean suspended /
                // backgrounded — cases where foreground-return implies this
                // VM's view is mounted. b5f6a1e1 later added the
                // "no subscriber" deferral (user viewing ANOTHER session):
                // for that case a foreground-return must NOT consume the
                // flag — the replay signal would fire with no CollectionView
                // subscriber bound and be lost, starving
                // consumeDeferredSnapshotIfNeeded (the in-app switch-back
                // path) of the flag it exists to consume.
                let sid = self.sessionId
                let gatePassed = (sid != nil && Self.activeSessionId == sid)
                let needsFlag = self.needsSnapshotReloadOnResume
                logger.info("[BlocksLost] didBecomeActive gate sid=\(sid?.prefix(8) ?? "nil") vm=\(self.vmInstanceId) activeSessionId=\(Self.activeSessionId?.prefix(8) ?? "nil") gatePassed=\(gatePassed) needsFlag=\(needsFlag)")
                guard needsFlag else { return }
                guard gatePassed else {
                    // Keep the flag: the user is on another session; the
                    // onAppear-reuse path consumes it when they switch back.
                    return
                }
                self.needsSnapshotReloadOnResume = false
                let totalBlocks = self.messages.reduce(0) { $0 + $1.blocks.count }
                let lastBlocks = self.messages.last?.blocks.count ?? 0
                logger.info("[BlocksLost] REPLAY retrySnapshot — app became active. sid=\(sid?.prefix(8) ?? "nil") totalBlocks=\(totalBlocks) lastMsgBlocks=\(lastBlocks) msgCount=\(self.messages.count)")
                self.retrySnapshotReloadSignal.send()
            }
        }

        // [T-ios-detached-vm-loop-end] When the agent loop finishes on a
        // detached VM (user navigated away mid-loop, or VM was evicted and
        // recreated), that VM posts .sessionAgentLoopDidEnd. The currently-
        // displayed VM for the same session picks it up here and reloads
        // from DB so the final tool results / assistant text appear.
        detachedLoopEndObserver = NotificationCenter.default.addObserver(
            forName: .sessionAgentLoopDidEnd, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let sid = self.sessionId else { return }
            guard let notifSid = notification.object as? String, notifSid == sid else { return }
            guard Self.activeSessionId == sid else { return }
            guard !self.isProcessing else { return }
            logger.info("[BlocksLost] DETACHED reload — agent loop ended on another VM, reloading. sid=\(sid.prefix(8)) vm=\(self.vmInstanceId)")
            Task { @MainActor in
                await self.reloadMessagesFromDB(reason: "detachedVMLoopEnd")
            }
        }

        syncChangeObserver = NotificationCenter.default.addObserver(
            forName: .cloudSyncDidFetchChanges, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let sid = self.sessionId else { return }
            // Only the foreground-visible VM reacts. ViewModelCache holds
            // every session the user has ever opened in this launch, and
            // each instance is a notification subscriber — without this
            // gate, one inbound batch fans out into N concurrent
            // reloadMessagesFromDB calls, each of which loadMessages-es
            // its session (potentially thousands of rows + JSON decode).
            // The hidden VMs catch up on their own via the
            // AIChatView.onAppear REUSING branch, which already does the
            // same hash+count comparison before reloading.
            if Self.activeSessionId != sid { return }
            // [T-deferred-sync-reload] If a send is in flight, don't
            // reload mid-stream — that would re-snapshot messages and
            // could clobber the streaming assistant block / hide the
            // "Minis is thinking" indicator. Flip a flag instead; the
            // $isProcessing observer below picks it up and replays one
            // reload as soon as the send completes. This avoids waiting
            // the full sync-timer cycle (~60s) for the next refresh.
            if self.isProcessing {
                self.pendingSyncReloadOnIdle = true
                logger.info("[ReloadTrace] DEFER reason=cloudSyncDidFetchChanges sid=\(sid.prefix(8)) isProcessing=true — will reload on idle")
                return
            }
            Task { @MainActor in
                await self.reloadMessagesFromDB(reason: "cloudSyncDidFetchChanges")
            }
        }

        activityTrackingCancellable = $isProcessing
            .removeDuplicates()
            .sink { [weak self] processing in
                guard let self else { return }
                // Key selection:
                //   - Before the draft has a real session (sessionId == nil),
                //     fall back to draftId so the sidebar proxy row still
                //     reflects activity.
                //   - Once sessionId exists, use ONLY it; mixing in draftId
                //     caused leaks — ensureSession migrates draft→real but
                //     draftId stays set for sidebar UX, and a second send()
                //     would setActive(draftId) again while the first send's
                //     setInactive(sessionId) wasn't reliably paired.
                let activeKey: String
                if let sid = self.sessionId {
                    activeKey = sid
                } else if let did = self.draftId {
                    activeKey = did
                } else {
                    return
                }
                let src = "vm=\(self.vmInstanceId) isProcessing=\(processing)"
                logger.info("🔄SESSION [vm=\(self.vmInstanceId)] isProcessing=\(processing) key=\(activeKey) draftId=\(self.draftId ?? "nil") sessionId=\(self.sessionId ?? "nil")")
                if processing {
                    SessionActivityTracker.shared.setActive(activeKey, source: src)
                    if let sid = self.sessionId {
                        Task {
                            if let session = await ChatStore.shared.getSession(sid),
                               let title = session.title, !title.isEmpty {
                                await MainActor.run {
                                    SessionActivityTracker.shared.updateSessionTitle(sid, title: title)
                                }
                            }
                        }
                    }
                    // [T-ios-session-running-shows-pause-badge] Starting/resuming
                    // a loop means this session is no longer paused — drop any
                    // stale ⏸ immediately, independent of the canResume didSet
                    // (which only fires on a value transition and can miss a queue
                    // entry seeded by the launch reconcile or a prior VM).
                    if let sid = self.sessionId {
                        SessionBadgeStore.shared.remove(.paused, for: sid)
                    }
                    // [T-ios-ipad-sidebar-spinner-stale-after-resend] Re-assert
                    // the draft→real alias on every activation. On iPad the
                    // sidebar keeps showing the new chat's row under its DRAFT
                    // id (ContentView.displaySessions builds a proxy with
                    // id=draftId so List(selection:) stays valid), and that row
                    // reads `isActive(draftId)`. The alias was registered once at
                    // draft→real migration, but `setInactive(real)` CLEARS it
                    // (it drops aliases pointing at a now-inactive session). So
                    // after the first stop the alias is gone; a resend calls
                    // setActive(real) but the sidebar proxy — still keyed by
                    // draftId — no longer resolves, and its spinner never spins
                    // again until the user navigates away (which collapses the
                    // proxy to the real id). Re-registering the alias here on
                    // each true-transition keeps the draft-keyed row in sync.
                    if let did = self.draftId, did != activeKey, self.sessionId != nil {
                        SessionActivityTracker.shared.setDraftAlias(draft: did, real: activeKey)
                    }
                } else {
                    SessionActivityTracker.shared.setInactive(activeKey, source: src)
                    // [T-ios-session-completed-badge-not-cleared] The loop just
                    // stopped. If it didn't stop in a resumable state, the session
                    // completed normally — clear any ⏸ that lingers. The canResume
                    // didSet handles the true→false transition, but a turn that
                    // finished with canResume ALREADY false (the common completion
                    // path: line ~4044 sets false even when it was false → no
                    // didSet) leaves a stale badge (seeded by reconcile / a prior
                    // VM) untouched. Gating on !canResume preserves a genuine
                    // interruption (Stop / bg-suspend) that ends the loop with
                    // canResume=true — that badge must stay.
                    if !self.canResume, let sid = self.sessionId {
                        SessionBadgeStore.shared.remove(.paused, for: sid)
                    }
                    // Safety net: if the draft id ever ended up in the tracker
                    // (e.g. from a prior send() that started before ensureSession
                    // returned), scrub it on this transition too so it can't
                    // orphan.
                    if let did = self.draftId, did != activeKey {
                        SessionActivityTracker.shared.setInactive(did, source: src + " (stray draftId)")
                    }
                    self.browserTabPool.releaseAllTabs()
                    // [T-deferred-sync-reload] Drain any sync reloads that
                    // arrived during the send so the UI catches up with the DB
                    // now that the stream finished.
                    // [T-ios-defer-icloud-sync-after-stop] BUT not while the
                    // post-stop hold is active — replaying a reload here is the
                    // exact overwrite we're preventing. Keep the flag armed; the
                    // hold release (timer / leave / background) replays it.
                    if self.pendingSyncReloadOnIdle, let sid = self.sessionId {
                        if self.isSyncHeld {
                            logger.info("[ReloadTrace] HOLD reason=isProcessing→false sid=\(sid.prefix(8)) — deferred reload kept until post-stop hold releases")
                        } else {
                            self.pendingSyncReloadOnIdle = false
                            logger.info("[ReloadTrace] DRAIN reason=isProcessing→false sid=\(sid.prefix(8)) — replaying deferred sync reload")
                            Task { @MainActor in
                                await self.reloadMessagesFromDB(reason: "deferredSyncReloadOnIdle")
                            }
                        }
                    }
                }
            }

        // When the mic starts capturing, immediately silence any in-progress
        // reply TTS (capture and playback are mutually exclusive — no echo). New
        // speech is already suppressed by `canSpeakNow`; this stops the current
        // System utterance too (the cloud queue is stopped by the panel).
        captureSuppressCancellable = VoiceModePreference.shared.$isCapturing
            .removeDuplicates()
            .sink { [weak self] capturing in
                if capturing { self?.stopSpeech() }
            }

        // A media attachment preempted reply TTS — stop the System synthesizer
        // (cloud queue already stopped by the coordinator). Don't auto-resume.
        mediaPreemptCancellable = NotificationCenter.default
            .publisher(for: AudioSessionCoordinator.replyTTSPreemptedNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.speechSynthesizer.isSpeaking {
                    self.speechSynthesizer.stopSpeaking(at: .immediate)
                }
                self.isReadingAloud = false
                self.speechPaused = false
            }

        // Read-replies is now GLOBAL state (VoiceOutputState.shared). Forward its
        // changes so views observing `vm.speakEnabled` refresh, and stop this VM's
        // System TTS the moment it's turned off anywhere.
        voiceStateCancellable = VoiceOutputState.shared.$isEnabled
            .dropFirst()                 // skip the synchronous current-value emit
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.objectWillChange.send()
                if !enabled { self.stopSpeech() }
            }
    }

    deinit {
        let vmId = vmInstanceId
        // Snapshot tracker-relevant state at deinit so we can spot leaks: if
        // isProcessing was still true when the vm is about to die, the
        // corresponding sessionId/draftId keys will remain stuck in
        // `SessionActivityTracker.activeSessions` because the `$isProcessing`
        // sink won't fire once self is gone. Fields are MainActor-isolated
        // and deinit is nonisolated; `_deinitSnapshot` is updated on the
        // main actor during normal flow so we can read it here safely.
        logger.info("🔄SESSION [vm=\(vmId)] deinit lastKnown: \(self._deinitSnapshot)")
        if let observer = fontChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = syncChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = backgroundSyncHoldObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = bgHintForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = snapshotForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = detachedLoopEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Published State

    @Published var messages: [ChatMessage] = []
    /// [T-voice-input-mode-preference-ios] True when a voice session
    /// contributed to the CURRENT composition (set on recording start by any
    /// path: mic tap, quick action, preference auto-entry). Cleared whenever
    /// the composer empties, so send() can detect "composed without voice
    /// since the composer was last cleared" and flip the remembered
    /// input-mode preference back to "text".
    var voiceUsedInComposition = false
    @Published var inputText = "" {
        didSet {
            if inputText.isEmpty && !oldValue.isEmpty {
                voiceUsedInComposition = false
                #if DEBUG
                logger.info("🔑DRAFT [vm=\(self.vmInstanceId)] inputText CLEARED (was '\(String(oldValue.prefix(30)))') sessionId=\(self.sessionId ?? "nil") draftId=\(self.draftId ?? "nil") isProcessing=\(self.isProcessing)")
                #else
                logger.info("🔑DRAFT [vm=\(self.vmInstanceId)] inputText CLEARED (was \(oldValue.count)ch) sessionId=\(self.sessionId ?? "nil") draftId=\(self.draftId ?? "nil") isProcessing=\(self.isProcessing)")
                #endif
            }
            updateSlashMenuState()
            updateMentionMenuState()
        }
    }
    /// Caret position (character offset) published by the input text view.
    /// Used by the `@` mention detector to locate the active token.
    @Published var inputCaret: Int = 0 {
        didSet {
            updateMentionMenuState()
            // If the caret arrived at the desired location, clear the pending
            // request so subsequent edits aren't forced back.
            if let p = pendingCaret, p == inputCaret {
                pendingCaret = nil
            }
        }
    }
    /// One-shot request to move the caret to a specific offset. Cleared once
    /// the text view publishes a matching caret position via `inputCaret`.
    @Published var pendingCaret: Int?
    /// Plain string capture of the vm state for diagnostic logging from deinit
    /// (which is nonisolated and can't touch @Published MainActor properties).
    /// Updated on every isProcessing flip and on send entry.
    nonisolated(unsafe) var _deinitSnapshot: String = "isProcessing=false session=nil draft=nil"

    @Published var isProcessing = false {
        didSet {
            _deinitSnapshot = "isProcessing=\(isProcessing) session=\(sessionId ?? "nil") draft=\(draftId ?? "nil")"
            if isProcessing && !oldValue {
                // Agent loop starting — defer iCloud sync sends until completion
                Task { await ChatStore.shared.setSyncSendDeferred(true) }
                // [T-ios-defer-icloud-sync-after-stop] A new turn supersedes any
                // pending post-stop hold; clear it WITHOUT a catch-up sync (the
                // new turn re-pauses sync via setSyncSendDeferred anyway).
                if postStopSyncHoldUntil != nil {
                    postStopSyncHoldUntil = nil
                    postStopSyncHoldTimer?.invalidate()
                    postStopSyncHoldTimer = nil
                    logger.info("[SyncHold] CLEAR — new turn started, superseding post-stop hold")
                }
                // Begin watching for main-thread hangs while streaming is
                // active. Captures a backtrace whenever the main runloop
                // doesn't drain for >1s, plus a snapshot of streamed text
                // around the stall, so we can confirm whether the 0x8BADF00D
                // watchdog lands inside _fillLayoutHole, SwiftUI Layout, or
                // elsewhere — and correlate with the content being rendered.
                StreamingHangLogger.shared.acquire(reason: "isProcessing=true session=\(sessionId ?? "nil")")
            } else if !isProcessing && oldValue {
                // [T-ios-defer-icloud-sync-after-stop] Agent loop finished. Do
                // NOT flush the deferred iCloud push or replay a pull reload now
                // — that immediate sync is what overwrote the just-finished
                // candidate. Instead enter the post-stop hold: both directions
                // stay paused for the grace window, then a single catch-up sync
                // runs on release (60s timer / leave session / background).
                beginPostStopSyncHold()
                StreamingHangLogger.shared.release(reason: "isProcessing=false session=\(sessionId ?? "nil")")
                // [T-ios-ui-frozen-on-tool-while-loop-runs] Force one snapshot
                // re-apply from the CURRENT in-memory messages at loop end.
                //
                // Why this is needed: during a multi-turn agent loop, tool blocks
                // are appended to the EXISTING last-assistant ChatMessage. The
                // messages ARRAY doesn't change, so the Coordinator's `$messages`
                // sink never re-fires and the per-message block-count subscription
                // can miss the appends — the new tool capsules are in the data
                // model but never get cells. The loop-end full reload that should
                // rebuild them goes through `reloadMessagesFromDB`, which is held
                // by the post-stop SyncHold and then SKIP-LOADs (`hashSame=true`,
                // because the DB baseline already advanced as the loop persisted),
                // so it never repaints. Result: the UI froze on the last-rendered
                // capsule for minutes while many turns ran un-rendered.
                //
                // `retrySnapshotReloadSignal` already does exactly the right thing
                // — re-applies the diffable snapshot from `vm.messages` even when
                // the array identity is unchanged (its original use: in-place
                // block mutation on retry). It is a pure UI re-render from memory:
                // it does NOT touch the DB / reload / SyncHold, so it can't
                // overwrite unpersisted content. Idempotent (the snapshot diff is
                // a no-op when nothing changed).
                //
                // CRITICAL guard — only fire when FOREGROUND and not UI-suspended:
                // the Coordinator's applySnapshot does a synchronous
                // `layoutIfNeeded()` (cell creation + self-sizing) on the main
                // thread. For a large history that is heavy work; running it while
                // backgrounded risks the 0x8BADF00D background-render watchdog
                // SIGKILL that `streamingUIUpdatesSuspended` exists to prevent. If
                // the loop ends while suspended/backgrounded, the Coordinator
                // already has `hasPendingSnapshot=true` and the suspend-resume hook
                // (T-ios-ui-blocks-lost-suspend-resume) flushes it on the next
                // foreground transition — so we must NOT force-apply here. We only
                // cover the foreground case (the actual freeze: block-count sub
                // missed in-place appends with NO suspend involved). Also gated on
                // `!transitionSuspended` so a session-switch outgoing VM doesn't
                // poke a tearing-down view graph (same guard as the manual
                // objectWillChange.send sites).
                // [T-blockslost-defensive defect ③] The flag ASSIGNMENT is no
                // longer wrapped in the `!transitionSuspended` gate: setting
                // `needsSnapshotReloadOnResume` touches no view, so the gate —
                // which exists to keep view-graph pokes out of the 0.4s
                // session-switch animation window — was pure collateral here.
                // A loop that ended inside that window previously left NO flag
                // behind, so nothing ever replayed for it. The gate still
                // protects the only view-touching action (the immediate
                // signal send below), whose conditions are unchanged.
                let inTransitionWindow = transitionSuspended
                if !inTransitionWindow,
                   !streamingUIUpdatesSuspended,
                   UIApplication.shared.applicationState == .active,
                   let sid = sessionId, Self.activeSessionId == sid {
                    retrySnapshotReloadSignal.send()
                } else {
                    needsSnapshotReloadOnResume = true
                    let totalBlocks = messages.reduce(0) { $0 + $1.blocks.count }
                    let lastBlocks = messages.last?.blocks.count ?? 0
                    let reason: String
                    if streamingUIUpdatesSuspended {
                        reason = "suspended"
                    } else if UIApplication.shared.applicationState != .active {
                        reason = "backgrounded"
                    } else if let sid = sessionId, Self.activeSessionId != sid {
                        reason = "no subscriber (active=\(Self.activeSessionId?.prefix(8) ?? "nil"))"
                    } else {
                        reason = "transition window"
                    }
                    logger.info("[BlocksLost] DEFERRED retrySnapshot — \(reason) at loop end. sid=\(sessionId?.prefix(8) ?? "nil") vm=\(vmInstanceId) transitionWindow=\(inTransitionWindow) totalBlocks=\(totalBlocks) lastMsgBlocks=\(lastBlocks) msgCount=\(messages.count)")
                }
                // [T-ios-detached-vm-loop-end] When an agent loop finishes on
                // a VM that is NOT the currently-displayed one (user navigated
                // away mid-loop), the final DB writes are invisible to the
                // displayed VM. Post a notification so the active VM for this
                // session reloads from DB and picks up the new data.
                if let sid = sessionId, Self.activeSessionId != sid {
                    logger.info("[BlocksLost] DETACHED loop end — posting reload for sid=\(sid.prefix(8)) (active=\(Self.activeSessionId?.prefix(8) ?? "nil"))")
                    NotificationCenter.default.post(name: .sessionAgentLoopDidEnd, object: sid)
                }
                // Also drain any skill-filesystem rescan that the AI's
                // shell tools may have queued during this turn. We hold
                // the rescan off the hot path so it runs once at quiet
                // time, not interleaved with every iSH write event.
                if #available(iOS 17.0, *) {
                    SkillFilesystemNotifier.shared.drainIfDirty(reason: "agent turn finished")
                }
            }
        }
    }
    /// [T-ios-group-pause-badge-restamp] Set only while a load / pre-warm is
    /// flipping `canResume` because the persisted tail STILL looks interrupted —
    /// i.e. the session was already paused and we are re-deriving that fact, not
    /// observing a new interruption. The `canResume` didSet reads this to decide
    /// whether the badge's entry timestamp may be overwritten. Not `@Published`:
    /// it is a transient annotation on the assignment, never UI state.
    /// Internal (not `private`) because the detecting site lives in the
    /// `+Persistence` extension, i.e. a different file.
    var isRedetectingInterruptedTail = false

    @Published var canResume = false {
        didSet {
            // [T-session-paused-badge-active-false-positive] Drive the session-
            // list PAUSED badge directly off canResume — the authoritative "this
            // session is interrupted (tap Resume)" flag and the single chokepoint
            // over every canResume setter. true → badge on; false (resumed / new
            // turn / completed) → badge off. Replaces the prior push at the
            // background-interruption point + clear-on-open, so a session merely
            // glanced at keeps its badge and a running/resolved session never
            // shows one. (Mirrors the Android canResume collector.)
            if oldValue != canResume, let sid = sessionId {
                if canResume {
                    // [T-ios-group-pause-badge-restamp] Only a REAL interruption
                    // re-stamps the badge's entry time. This didSet is the single
                    // chokepoint over every canResume setter, so it also fires
                    // when a load/pre-warm merely RE-DETECTS an old interrupted
                    // tail — that is not a new entry into the paused state, and
                    // re-stamping it there is what let a days-old pause keep
                    // looking "fresh" to the group card's 24h window forever.
                    // The detecting site sets `isRedetectingInterruptedTail`
                    // around its assignment; everything else is a live event.
                    SessionBadgeStore.shared.pushFront(
                        .paused, for: sid,
                        restamp: !isRedetectingInterruptedTail,
                        source: isRedetectingInterruptedTail ? .redetect : .push)
                } else {
                    SessionBadgeStore.shared.remove(.paused, for: sid)
                }
            }
            // [T-ios-cancel-reload-overwrite] reloadMessagesFromDB defers a
            // sync reload while `canResume` is true and the in-memory candidate
            // holds unpersisted interrupted content (so the reload can't
            // overwrite it). Once the interrupted state clears (Resume finished
            // / a normal turn completed and persisted everything), replay the
            // deferred reload so iCloud-synced changes finally land.
            if oldValue && !canResume && pendingSyncReloadOnIdle, let sid = sessionId {
                // [T-ios-retry-usermsg-vanish] Don't replay the deferred reload
                // if canResume is being cleared as the FIRST step of a retry
                // truncation — the reload would race the in-flight
                // messages/DB truncation and can drop the retried user message
                // from the UI. Leave pendingSyncReloadOnIdle armed; the retry's
                // own completion (isProcessing→false) drains it safely.
                if isTruncatingForRetry {
                    logger.info("[ReloadTrace] SKIP reason=canResume→false sid=\(sid.prefix(8)) — retry truncation in progress; deferred reload stays armed")
                } else {
                    pendingSyncReloadOnIdle = false
                    logger.info("[ReloadTrace] DRAIN reason=canResume→false sid=\(sid.prefix(8)) — replaying deferred sync reload after interrupted state cleared")
                    Task { @MainActor [weak self] in
                        await self?.reloadMessagesFromDB(reason: "deferredAfterResumeCleared")
                    }
                }
            }
        }
    }
    @Published var isSuspended = false
    /// [T-ios-streamdiag-phantom-model] LEGACY FALLBACK DEFAULT — never
    /// written anywhere; permanently holds `.claudeHaiku45`. The real model
    /// selection flows through `activeEntryId` → `ProviderConfigStore`
    /// (see runAgentLoop). The only legitimate reads are `?? selectedModel`
    /// last-resort fallbacks when entry resolution fails (documented in
    /// +ToolDefinitions). NEVER log or display this as "the current model":
    /// the SSE stall diagnostics did exactly that, and a stall investigation
    /// was nearly pinned on claude-haiku-4-5 — a model the session never used.
    @Published var selectedModel: LLMModel = .claudeHaiku45
    @Published var isLoadingSession = false
    /// False until the FIRST loadSession() for this vm completes. Lets the view
    /// distinguish "entering the session, nothing rendered yet" (show the soft
    /// centered loading card) from every later reload — iCloud sync, compaction,
    /// stale-cache refresh — which must keep the unobtrusive spinner and never
    /// cover content the user is already reading. Not @Published on purpose: it
    /// only ever changes alongside isLoadingSession, whose publish already
    /// re-evaluates the view.
    var hasCompletedInitialLoad = false
    @Published var errorMessage: String?

    /// [T-ios-retry-keyboard] Marks the in-flight turn as one the user started
    /// by tapping Retry / Resume on an EXISTING failed message, rather than by
    /// sending something new.
    ///
    /// The auto-focus-after-reply observer keys off the `isProcessing` true→false
    /// edge, and a retry produces exactly that edge — so re-running an old
    /// failure looked identical to "a reply just finished" and popped the
    /// keyboard. That is wrong for a retry specifically: the user's gesture was
    /// "send this again", not "let me type", and the composer rising covers the
    /// error they are trying to read.
    ///
    /// Deliberately NOT "suppress focus whenever a turn fails": auto-focus at
    /// the moment a fresh send fails is existing, wanted behaviour. The
    /// distinction being drawn is the ORIGIN of the turn, not its outcome.
    ///
    /// Not @Published — the observer reads it synchronously inside the
    /// isProcessing handler, and publishing it would re-render the whole chat
    /// on every retry for no visual reason.
    var turnStartedByRetry = false
    /// Transient banner / toast message for in-loop notices (e.g. "older
    /// N image(s) elided from request to fit 25MB budget"). Set by the
    /// request-level image budget pass when it had to drop history images;
    /// UI clears it after a short display window.
    @Published var transientNotice: String?
    @Published var autoRetryAttempt: Int = 0
    @Published var autoRetryCountdown: Int = 0
    /// [T-ios-empty-after-toolresult-reminder] Guards the one-shot
    /// `<system-reminder>` retry when the server returns an empty response
    /// right after a tool result. Set the first time we inject the reminder in
    /// a given agent loop; if the reminder round is ALSO empty we report an
    /// error instead of injecting again — so it can never loop. Reset at the
    /// start of each agent loop (a fresh user turn).
    var didInjectEmptyToolReminderThisRun = false
    /// Incremented when a model fallback occurs so the UI can animate the model name change.
    @Published var fallbackTrigger: Int = 0
    /// Signal to trigger scroll-to-bottom in views (not @Published to avoid full view diff).
    let scrollToBottomSignal = PassthroughSubject<Void, Never>()
    /// Fired when the view model wants the composer to grab keyboard focus
    /// (e.g. after a `/skill` tap fills the input — the user expects to
    /// immediately type their question without an extra tap on the field).
    let requestComposerFocusSignal = PassthroughSubject<Void, Never>()
    /// Force scroll-to-bottom AND re-enable auto-scroll. Used only for explicit user actions
    /// (send, enqueue, session reuse) — NOT during streaming, so user scroll position is respected.
    let forceScrollToBottom = PassthroughSubject<Void, Never>()
    /// Force scroll-to-top (first message). Used by the floating "scroll to
    /// first message" button — a counterpart to forceScrollToBottom that does
    /// NOT change auto-scroll mode (jumping to the top is always a browse action).
    let forceScrollToTop = PassthroughSubject<Void, Never>()
    /// Signal sent when a text block transitions from empty to non-empty content.
    /// The coordinator reconfigures the affected cell so UIHostingConfiguration
    /// re-measures its height (UIKit doesn't always trigger preferredLayoutAttributesFitting
    /// reliably when the SwiftUI body changes inside a UIHostingConfiguration).
    let blockContentFilledSignal = PassthroughSubject<(messageId: UUID, blockId: UUID), Never>()
    /// Content offset Y published on each scroll event (for debug jitter monitoring).
    let contentOffsetYSignal = PassthroughSubject<CGFloat, Never>()
    /// Content size height delta signal (for debug jitter monitoring).
    let contentSizeDeltaSignal = PassthroughSubject<CGFloat, Never>()
    /// Fired after a retry truncation to force the message list to re-apply its
    /// diffable snapshot. Needed because `retryFromToolBlock`'s sub-message path
    /// mutates `messages[i].blocks` in-place without changing the messages
    /// array count, so `$messages` won't fire a new value and the UIKit-backed
    /// `CollectionViewMessageListV3` (which doesn't observe `objectWillChange`)
    /// would otherwise keep showing the pre-cut block identifiers.
    let retrySnapshotReloadSignal = PassthroughSubject<Void, Never>()
    /// Whether the message list is scrolled near the bottom. Updated by CollectionViewMessageList.
    @Published var isNearBottom: Bool = true

    /// Whether the viewport is already at the very first user turn's top — i.e.
    /// the up-button ("scroll to previous turn") has nowhere further up to go.
    /// Drives ONLY the up-button's visibility (the down-button still keys off
    /// isNearBottom): once the user has walked all the way up, the up-button
    /// hides. Updated by CollectionViewMessageList on scroll/jump.
    @Published var isAtFirstTurn: Bool = false

    /// [ScrollDiag] View-layer record of a scroll-jump button's actual SwiftUI
    /// mount/unmount, so a ring dump (debug.scrollMetrics) can be diffed against
    /// the VM-side buttonsVisible. `up` picks which button; `visible` is true on
    /// appear, false on disappear. DEBUG-only; compiled out in Release.
    func recordScrollButtonRender(up: Bool, visible: Bool) {
        #if DEBUG
        ScrollMetricsRecorder.shared.record(
            kind: "btnRender",
            a: visible ? 1 : 0,
            pos: "\(up ? "up" : "down")-\(visible ? "appear" : "disappear") vmNearBottom=\(isNearBottom)")
        #endif
    }

    // Note: Stream throttle timestamps (lastTextDeltaFlush, lastFileWriteStreamUpdate,
    // lastToolInputStreamUpdate) are now local vars inside processStreamEvents().
    @Published var kernelStatus: KernelStatus = .notBooted
    /// When enabled, agent responses and tool descriptions are spoken aloud.
    /// Initialized from the persisted "Read replies" preference so an already-on
    /// toggle drives streaming TTS for new chats.
    /// Read-replies on/off. NOT per-session state — proxies the GLOBAL
    /// `VoiceOutputState.shared` so toggling in any session (or the home screen)
    /// is reflected everywhere. `voiceStateCancellable` (set in init) forwards the
    /// global object's changes to this VM so views observing `vm.speakEnabled`
    /// still refresh.
    var speakEnabled: Bool {
        get { VoiceOutputState.shared.isEnabled }
        set { VoiceOutputState.shared.isEnabled = newValue }
    }
    /// When enabled, uses 1-hour cache TTL instead of 5-minute for Anthropic requests.
    @Published var enhancedCacheEnabled = false

    /// Whether the Enhanced Cache toggle should be visible. Only Anthropic
    /// official API (no custom base URL) supports the cache TTL protocol.
    var showEnhancedCacheToggle: Bool {
        guard let entry = resolveCurrentEntry(),
              let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)
        else { return false }
        guard inst.providerType == .anthropic else { return false }
        if let url = inst.customBaseURL, !url.isEmpty { return false }
        return true
    }

    // MARK: - Compact State
    /// Whether the slash command menu should be shown.
    @Published var showSlashMenu = false
    /// Filter text after "/" in the input.
    @Published var slashFilter = ""
    /// Currently highlighted index in the slash menu (-1 = none selected).
    @Published var slashMenuSelectedIndex = -1
    /// Whether a compaction is in progress.
    @Published var isCompacting = false
    /// When true, shows a prompt asking user to compact before sending.
    @Published var showCompactBeforeSendPrompt = false
    /// [T-chat-auto-compact-opt-in] Global (cross-session) opt-in: when the
    /// context-capacity threshold fires, compact automatically instead of
    /// prompting — the same no-UI path shortcut sessions already use. Set
    /// from the confirm dialog's "Compact & Enable Auto-Compact" button or
    /// the "..." menu's Auto Compact toggle; persisted in UserDefaults so
    /// future conversations inherit it.
    @Published var autoCompactEnabled: Bool = UserDefaults.standard.bool(forKey: "autoCompactOnThreshold") {
        didSet {
            guard autoCompactEnabled != oldValue else { return }
            UserDefaults.standard.set(autoCompactEnabled, forKey: "autoCompactOnThreshold")
        }
    }
    /// When true, shows a prompt telling user to start a new session or clear chat.
    @Published var showContextExhaustedPrompt = false
    /// Message text held back while the compact-before-send prompt is shown.
    var pendingSendText: String?
    /// Attachments held back while the compact-before-send prompt is shown.
    var pendingSendAttachments: [InputAttachment] = []
    /// When true, skip the needsCompactBeforeSend check (used after compactAndSend to avoid loop).
    var skipCompactCheck = false
    /// When false, memory_write tool calls are skipped (returns "Memory disabled") in this session.
    @Published var memoryEnabled = true

    // MARK: - Session Stats
    @Published var sessionCostSummary: SessionCostSummary?
    /// 请求序号拒绝迟到结果；持久记录独立于页面缓存。
    var contextUsageState = ContextUsageState()
    @Published var loadedContextUsage: PersistedContextUsage?
    var contextUsageGeneration: UInt64 = 0

    /// Accumulated streaming duration (seconds) for output token speed calculation.
    var sessionStreamDuration: TimeInterval = 0
    /// Total output tokens produced during streaming (for speed calculation).
    var sessionStreamOutputTokens: Int = 0
    /// Cumulative cache read tokens across all API calls in this session.
    var sessionCacheReadTokens: Int = 0
    /// Cumulative cache write (creation) tokens across all API calls in this session.
    var sessionCacheWriteTokens: Int = 0
    /// Cumulative input tokens (excl. cache) across all API calls in this session.
    var sessionInputTokens: Int = 0
    /// Cumulative output tokens across all API calls in this session.
    var sessionOutputTokens: Int = 0

    // Tool snapshots
    @Published var toolSnapshots: [ToolSnapshotItem] = []

    // Attachments
    @Published var attachments: [InputAttachment] = []
    /// Number of videos currently being imported from the photo picker.
    @Published var loadingVideoCount = 0

    /// Old iOS releases visibly jitter when the actively streaming markdown block
    /// re-self-sizes during user scroll/deceleration. While this flag is set, the
    /// newest streamed text snapshot is buffered and only applied after scrolling settles.
    struct DeferredStreamingTextUpdate {
        let messageId: UUID
        let blockId: UUID
        let text: String
        let parsedMarkdown: MarkdownContent?
        let cacheAttributedString: Bool
    }
    var deferredStreamingTextUpdates: [DeferredStreamingTextUpdate] = []
    var streamingUIUpdatesSuspended = false

    /// Set when `isProcessing` transitions to false but `retrySnapshotReloadSignal`
    /// cannot fire because `streamingUIUpdatesSuspended` is true. Cleared when the
    /// suspend lifts — at that point the snapshot rebuild is safe and is replayed.
    var needsSnapshotReloadOnResume = false

    /// [T-ios-ui-blocks-lost-suspend-resume] Fired on the main thread whenever
    /// `streamingUIUpdatesSuspended` transitions from true → false, from ANY
    /// path (scroll-settle resume, transition resume, explicit clear). The
    /// message-list Coordinator registers this so it can rebuild a snapshot it
    /// deferred while suspended (`hasPendingSnapshot`). Without it, a suspend
    /// window that opens during a multi-tool agent loop and closes after the
    /// stream ends has no subscription left to trigger the deferred flush, so
    /// the trailing assistant blocks never render even though they're in the DB.
    var onStreamingUIUpdatesResumed: (() -> Void)?

    /// True while this vm is the OUTGOING side of a session-switch transition.
    /// During the brief window when the UICollectionView/SwiftUI host views of
    /// the previous session are being torn down and the new session's views
    /// are being mounted, both ViewGraphs share the same AsyncRenderer thread.
    /// A concurrent mutation on the outgoing vm here can cause
    /// AG::Subgraph::NodeCache::~NodeCache to deref a dangling pointer
    /// (FB13213926, recurring), evidenced by build-48 crash
    /// Minis-2026-06-01-134710.ips: user switched sessions while both vms had
    /// `isProcessing=true`, EXC_BAD_ACCESS in
    /// `_UIHostingView.isHiddenForReuse.setter → ViewGraphHost.updateRemovedState
    /// → AG::Subgraph::invalidate_now → AG::Subgraph::NodeCache::~NodeCache`.
    /// While `transitionSuspended` is true:
    ///   * `streamingUIUpdatesSuspended` is force-true (text-block flush defer)
    ///   * Manual `objectWillChange.send()` callers consult `isTransitionSuspended`
    ///     and elide the publish when true (retry / edit / thinking-level
    ///     paths). The next genuine state change after resume re-publishes.
    var transitionSuspended = false
    /// True for the synchronous window of `retryFromMessage` /
    /// `retryFromToolBlock`: from the moment we start clearing `canResume` /
    /// truncating `messages` until the DB truncation (`deleteMessagesAfter`)
    /// has completed. While set, a deferred iCloud-sync `reloadMessagesFromDB`
    /// must NOT run — it would rebuild `messages` from a DB snapshot taken
    /// mid-truncation (before/around the delete) and can drop the retried user
    /// message from the UI even though it survives in agentHistory (so the
    /// reply is based on it but its bubble vanishes). Reload calls skip+rearm
    /// while this is true, and the canResume didSet does not replay the
    /// deferred reload; the next safe idle drains it. [T-ios-retry-usermsg-vanish]
    var isTruncatingForRetry = false

    // MARK: - Browser
    let browserTabPool = BrowserTabPool()
    /// 可注入的匿名网页读取服务，生产默认使用进程级资源预算。
    var webReadService: WebReadService = .shared
    /// 当前工具批次的 web_read 标识；Stop 通过它取消排队及活动读取。
    var activeWebReadBatchID: String?
    /// 匿名关键词搜索服务与当前工具批次，用于 Stop 和请求作用域清理。
    var webSearchService: WebSearchService = .shared
    var activeWebSearchBatchID: String?
    /// When true, the agent loop pauses at the next checkpoint to let the user operate the browser.
    @Published var browserTakeoverActive = false

    // MARK: - Prompt Queue
    /// Prompts queued by the user while the agent loop is running.
    @Published var promptQueue: [QueuedPrompt] = []

    // MARK: - Speech

    let speechSynthesizer = AVSpeechSynthesizer()
    lazy var speechDelegate = SpeechFinishedDelegate()
    /// True when speech is paused (not stopped). Toggled by the floating speech button.
    @Published var speechPaused = false

    /// Accumulates reasons for provider fallbacks within a single attempt, consumed by runAgentLoop to insert info blocks.
    var fallbackReasons: [(model: String, instance: String, reason: String)] = []

    /// True when the synthesizer is actively speaking or has queued utterances.
    var isSpeaking: Bool {
        speechSynthesizer.isSpeaking
    }

    /// Current read-replies speed multiplier, mirrored for the player control.
    /// Source of truth is VoiceOutputPreferences.speedMultiplier.
    @Published var speechSpeed: Float = VoiceOutputPreferences.speedMultiplier

    /// True once the first reply utterance has been handed to a TTS engine — used
    /// by the player control to collapse from expanded to compact on first speak.
    @Published var isReadingAloud = false

    /// Whether the floating speech player control is expanded (vs compact). Lives
    /// here so the chat view can overlay a tap-to-dismiss layer while expanded.
    /// Defaults to COMPACT — expansion is only initiated by an explicit user action
    /// that turns reading on (so a new session / relaunch shows compact).
    @Published var speechPlayerExpanded = false

    /// Sentence-ender set used by the coherent-cut fallback (mirrors the SSE
    /// segmenter's tier-1 enders).
    nonisolated static let speechEndersForCut: Set<Character> = ["。", "！", "？", ".", "!", "?", "；", ";"]

    /// Per-reply snapshot of the TTS engine choice; cleared at each reply start.
    var replyUsesCloudTTS: Bool?

    /// True once THIS turn (one user send, spanning ALL agent-loop iterations)
    /// has cleared the previous turn's TTS leftovers. Lives on the vm — NOT on
    /// StreamResult, which is recreated per loop iteration: a per-iteration
    /// flag made every iteration's first textDelta call stopSession and cut
    /// off the previous iteration's still-playing speech. One turn = one
    /// read-aloud context; iterations append and play back-to-back.
    var hasClearedTTSForCurrentTurn = false

    // MARK: - Auto-Play Audio

    /// Regex to find Markdown image syntax with audio extensions and ?auto_play=true query.
    /// Matches: ![...](minis://attachments/file.mp3?auto_play=true)
    static let autoPlayAudioPattern: NSRegularExpression? = {
        // Match ![alt](url) where url ends with audio extension and has auto_play=true/1
        try? NSRegularExpression(
            pattern: #"!\[[^\]]*\]\(([^)]+\.(?:mp3|m4a|wav|aac|ogg|flac)\?[^)]*auto_play=(?:true|1)[^)]*)\)"#,
            options: .caseInsensitive
        )
    }()

    // MARK: - Private

    /// Approximate current time string, rounded to the hour for cache stability.
    var _cachedTimeString: String = ""
    var _cachedTimeDate: Date = .distantPast
    /// Session ID for persistence integration. Set by the view on appear.
    var sessionId: String? {
        didSet { browserTabPool.sessionId = sessionId }
    }

    /// The draft ID assigned by the parent view (e.g. "__new__<UUID>").
    /// Included in `.sessionDidCreate` notification so the parent can correlate.
    var draftId: String?

    /// Source tag written to the session record on creation (e.g. "shortcut").
    var sessionSource: String?

    /// [T-shortcut-duplicate-completion-notification] Suppresses the *generic*
    /// background-completion notification for this run, because a Shortcuts
    /// intent already posts its own via `ShortcutNotification`. Without this the
    /// user gets two overlapping notifications for one task: "Minis Task
    /// Completed" from the intent and "✅ {sessionTitle}" from
    /// `endBackgroundProcessing`.
    ///
    /// Deliberately NOT keyed off `sessionSource == "shortcut"`: that value also
    /// drives near-capacity auto-compaction and the context-exhausted error path
    /// (see `send()`), and RetryRun/FollowUp operate on sessions the user may
    /// have created by hand in the app. Tagging those as "shortcut" to get the
    /// notification behaviour would silently opt them into auto-compaction too.
    /// This flag carries exactly one meaning and nothing else reads it.
    ///
    /// Run-scoped and CONSUMED on read: `endBackgroundProcessing` clears it as it
    /// checks it, so it suppresses exactly the one completion it was set for.
    /// That matters because a VM is cached and reused — if the user opens the
    /// same session later and sends a message by hand, that run must still get
    /// its normal completion notification. A sticky flag would silence the
    /// session forever. Not persisted; each intent sets it fresh.
    var suppressGeneralCompletionNotification: Bool = false

    /// Model group to bind when creating a new session (from long-press FAB).
    var initialGroupId: String?

    /// Currently active session ID — accessible from anywhere for minis:// URL resolution.
    /// Updated whenever a session is loaded.
    nonisolated(unsafe) static var activeSessionId: String?
    /// REPRO-DIAG(2026-05-16): global round counter — each runAgentLoop
    /// invocation bumps this. Use `ROUND \d+` to slice the log by attempt.
    nonisolated(unsafe) private static var diagRoundCounter: Int = 0
    nonisolated static func bumpDiagRound() -> Int {
        // Not atomic because runAgentLoop is invoked from main actor and
        // serialised per ViewModel; concurrent rounds across VMs may race
        // and skip/dup a number, which is acceptable for a diagnostic id.
        diagRoundCounter &+= 1
        return diagRoundCounter
    }
    nonisolated static func currentDiagRound() -> Int { diagRoundCounter }
    /// Timestamp when onAppear fires — used to measure end-to-end load latency.
    nonisolated(unsafe) static var onAppearTimestamp: CFAbsoluteTime = 0

    /// Number of title generation attempts for this session (max 3).
    var titleGenAttempts = 0
    /// Whether a title generation request is currently in-flight.
    var isTitleGenerating = false

    /// Unified conversation history used by both Anthropic and Gemini agent loops.
    var agentHistory: [AgentMessage] = []

    #if DEBUG
    /// [T-ios-log-noise-reduction] High-water mark of how many agentHistory
    /// entries the Debug `📋 agentHistory[i]` dump has already printed. The
    /// per-API-call dump only NSLogs entries at index ≥ this value (the delta
    /// since the previous call) instead of re-printing the whole growing
    /// history every iteration. Reset to 0 when the history shrinks.
    var lastDumpedAgentHistoryCount: Int = 0
    #endif

    /// Detects tool-call loops (repeated unknown tools, no-progress polling, runaway
    /// retries) and either injects warnings or short-circuits execution.
    let toolLoopDetector = ToolLoopDetector()

    // MARK: - Cache Keep-Alive State
    /// Snapshot of agent loop state for cache keep-alive warmup requests.
    /// Updated each iteration so the manager can replay the same prefix.
    var keepAliveHistory: [AgentMessage] = []
    var keepAliveSystemPrompt: String?
    var keepAliveTools: [AgentToolDefinition] = []

    // MARK: - Compact Marker (Phase B)
    /// Cached latest compact marker for this session. Phase B agent loop uses this
    /// (via effectiveAgentHistory) to inject the summary at inference time instead
    /// of mutating agentHistory. Updated by loadSession, compactBefore, and any
    /// path that writes a new marker.
    var cachedLatestMarker: CompactMarker?
    /// The session's persisted model id (from ChatStore.getSession). Cached at
    /// loadSession time so resolveCurrentEntry can fall back to it without an
    /// async hop to the actor. Empty string means "not yet loaded" — treat as
    /// no fallback.
    var cachedSessionModelId: String = ""
    /// The ModelEntry used in the current/last agent loop, for rebuilding the provider.
    var keepAliveEntry: ModelEntry?
    /// Pending thought signatures loaded from persisted session, keyed by tool call ID.
    /// Applied to GeminiAgentProvider when the agent loop starts.
    var pendingThoughtSignatures: [String: ToolCallMetadata] = [:]
    // `internal` (not `private`): the +Compaction extension's
    // schedulePostCompactDrain() runs the post-compact queue drain on this
    // task so cancel() can stop it. [T-compact-queued-drain]
    var currentTask: Task<Void, Never>?
    var compactTask: Task<Void, Never>?
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// [T-ios-bgkeepalive-diag] Process-wide count of LIVE
    /// `beginBackgroundTask` grants, so crash diagnostics can report whether a
    /// real `UIBackgroundTaskIdentifier` was held — previously the crash report's
    /// "BG task active" field showed `BackgroundKeepAliveManager.isActive`, a
    /// keep-alive *intent* flag with no relation to the OS grant, which made
    /// every report read as "background task healthy" even when no task was held.
    /// Maintained by begin/endBackgroundProcessing; `nonisolated(unsafe)` +
    /// lock-free because it is only mutated on the MainActor.
    @MainActor
    private(set) static var liveBackgroundTaskCount = 0

    @MainActor
    static func noteBackgroundTaskBegan() { liveBackgroundTaskCount += 1 }

    @MainActor
    static func noteBackgroundTaskEnded() {
        liveBackgroundTaskCount = max(0, liveBackgroundTaskCount - 1)
    }
    /// Tracks how many blocks on the current assistant message have been fully committed
    /// to agentHistory. Used by retry()/resume() to trim partial iteration content.
    var committedBlockCount: Int = 0
    /// The committedBlockCount before the current/last iteration started.
    /// Used by handleUserCancelledCleanup to roll back the last iteration.
    var prevCommittedBlockCount: Int = 0
    /// Set by cancel() so the task's error handler knows this was a user stop.
    /// Internal-access so concurrent tool extensions can read it. [T-concurrent-tools]
    var userDidCancel = false
    /// Reentrancy guard for `drainQueuedPrompts()`. After a Stop with queued
    /// prompts, `cancel()` hands off to a fresh Task via `resumeQueueAfterCancel()`,
    /// but the original (superseded) send/retry/resume Task ALSO reaches its own
    /// post-loop `drainQueuedPrompts()` call. Without a guard both Tasks could run
    /// the queued turn, firing the next LLM request — and thus every tool call +
    /// reply — TWICE. Set/cleared only on @MainActor, so the check-and-set is
    /// atomic and spans the `await runAgentLoop()` suspension where the second
    /// drainer would otherwise slip in. [T-ios-concurrent-stop-double-request]
    var isDrainingQueue = false
    /// [T-compact-queued-drain] True while a post-compact queue drain has been
    /// scheduled (task created) but not finished. Dedup guard so the two
    /// schedulers (compactBefore's success tail + compactAndSend's failure
    /// backstop) can't spawn two racing drain tasks for the same compact.
    var postCompactDrainPending = false
    /// When non-nil, the next send() acts as an edit: truncates conversation from this
    /// message index and re-sends. Cleared after the edit is applied.
    @Published var editingMessageIndex: Int?
    /// Set when the background task expires mid-agent-loop; cleared on resume.
    var backgroundSuspended = false
    /// Continuation used to pause the agent loop while suspended in background.
    var foregroundContinuation: CheckedContinuation<Void, Never>?
    /// Continuation used to pause the agent loop during browser takeover (between turns).
    var takeoverContinuation: CheckedContinuation<Void, Never>?
    /// Continuation used to pause mid-action when the user takes over during a browser action.
    var midActionTakeoverContinuation: CheckedContinuation<Void, Never>?
    /// Timeout task for mid-action takeover (5 minutes).
    var takeoverTimeoutTask: Task<Void, Never>?
    var foregroundObserver: NSObjectProtocol?
    /// Timer that logs tool execution status while the app is backgrounded.
    var backgroundStatusTimer: Timer?
    let defaultCommandTimeout: TimeInterval = 900 // 15 minutes
    /// PID of the currently running shell command (0 = none).
    @Published var runningCommandPid: Int32 = 0
    /// Start time of the currently running command (nil = no command running).
    @Published var commandStartTime: Date?
    /// Set to `true` when the user explicitly stops a running command via the stop button.
    /// Checked after command completion so the tool_result can inform the model.
    var commandCancelledByUser = false

    /// Number of shell_execute tools currently in their pre-execution `delay`
    /// countdown. Lets `stopCurrentCommand()` treat the stop button as a valid
    /// cancel during the wait even though no iSH process exists yet.
    /// [T-delay-stop-latency] A COUNTER, not a Bool: under concurrent tool
    /// execution a second delaying tool finishing (and running its `defer`)
    /// would otherwise flip a shared Bool back to false while a sibling was
    /// still counting down, making the stop button a NOOP for that sibling.
    var toolDelayWaitCount = 0

    /// True while at least one shell_execute tool is in its pre-execution
    /// `delay` countdown.
    var toolDelayWaitActive: Bool { toolDelayWaitCount > 0 }

    /// Whether at least one enabled provider instance exists (has selectable models).
    /// Credential validity is checked at send time, not here — avoids blocking the
    /// send button due to Keychain/OAuth state that SwiftUI can't observe.
    var isReady: Bool {
        ProviderConfigStore.shared.instances.contains { $0.isEnabled }
    }

    // MARK: - Send Message

    // MARK: - Session Persistence

    /// Load an existing session's messages from the database and rebuild UI + agent history.
    ///
    /// The DB stores one RawMessage per API turn: user, assistant, user(tool-results), assistant, ...
    /// Reload messages from DB after iCloud sync brings new data.
    /// Only reloads if there are new messages (avoids disrupting active sessions).
    /// Tracks the highest DB sortOrder seen after each load, so iCloud sync reload
    /// only triggers when genuinely new messages arrive from another device.
    var lastKnownDbSortOrder: Int = 0
    /// Tracks the DB message count so we can detect remote deletions (retry propagation).
    var lastKnownDbCount: Int = 0
    /// Hash of the (id, sort_order) pairs from the last DB load. Catches a
    /// silent reorder by another sync path (HEAL on LWW skip) where neither
    /// the count nor the max sort_order changed.
    var lastKnownDbOrderHash: Int = 0
    /// Number of assistant turns in `agentHistory` at the moment we LAST marked
    /// this session unread. `endBackgroundProcessing()` is called from ~15 sites
    /// (normal completions, kernel-failure early-returns, cancel cleanup, the
    /// bgTask-expiration handler, resumeQueueAfterCancel, …), and it used to
    /// push `.unread` unconditionally on every one of them. That made a late or
    /// duplicate call — e.g. a background keep-alive bgTask expiring after the
    /// user already read and left the session — re-add the red dot with NO new
    /// content. We now only re-badge when the assistant-turn count has actually
    /// grown since the last badge, i.e. this run genuinely produced a new
    /// completion. [T-ios-unread-dot-reappears]
    var lastBadgedAssistantTurnCount: Int = -1
    // MARK: - Agent Loop

    // MARK: - Slash Commands (stored state)
    // Method bodies live in AIChatViewModel+SlashCommands.swift; stored
    // properties must stay on the class itself (extensions can't add them).

    /// Set by the slash-command handler to ask the view to show the
    /// "Clear Chat?" confirmation alert. The view mirrors this into its
    /// local @State and resets the flag back to false on observation.
    @Published var clearChatConfirmRequested = false

    /// Text saved before showing slash menu over existing input.
    /// When non-nil, the menu was opened via the "/" button while text existed —
    /// executing a command should restore this text instead of clearing it.
    var savedInputBeforeSlash: String?
    /// Caret offset saved alongside `savedInputBeforeSlash`.
    var savedCaretBeforeSlash: Int?

    // MARK: - File Mention (`@`) Menu

    /// Whether the `@`-file menu is visible.
    @Published var showMentionMenu = false
    /// Currently highlighted row index (-1 = none).
    @Published var mentionSelectedIndex: Int = -1
    /// Live filter extracted from the active `@<token>` in the input.
    @Published var mentionFilter: String = ""
    /// The `@` character's UTF-16 offset in `inputText` for the currently active trigger.
    /// Used to replace the token on selection. -1 when inactive.
    var mentionAnchor: Int = -1



    /// In-memory thinking level for sessions not yet persisted (no sessionId yet).
    /// nil = user hasn't explicitly set one; fall back to the default group's level.
    var pendingThinkingLevel: ThinkingLevel?

    /// Append an ephemeral system info message (not sent to LLM).
    func appendSystemInfo(_ text: String, icon: String) {
        let msg = ChatMessage(role: .systemInfo, content: text)
        msg.systemIcon = icon
        messages.append(msg)
    }

}
