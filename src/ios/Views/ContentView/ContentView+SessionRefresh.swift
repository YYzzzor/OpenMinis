//
//  ContentView+SessionRefresh.swift
//  Minis - 首页（Views/ContentView）
//
//  会话列表刷新与防抖。MinisX：首屏会话加载（loadInitialSessionState）。
//
//  ContentView 文件地图见 ContentView/ContentView.swift。
//

import SwiftUI

private let shareLog = AppLogger(category: "Share")

extension ContentView {
    /// [T-ios-session-coldload-listsessions-block] Refresh the session list to
    /// pick up any preview change in the session the user just left, but only
    /// AFTER the incoming session's loadSession() has claimed and released the
    /// ChatStore actor for its DB reads. Firing listSessions() synchronously on
    /// navigation raced it onto the (non-preemptible, serialized) actor and hung
    /// the incoming spinner ~1.5s. A 0.6s debounce clears the incoming load
    /// (~50-150ms) with margin and coalesces bursts of session switching into a
    /// single trailing scan.
    func scheduleOutgoingPreviewRefresh() {
        outgoingPreviewRefreshWork?.cancel()
        let work = DispatchWorkItem {
            refreshSessionList()
        }
        outgoingPreviewRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// [T-ios-listsessions-refresh-coalesce] Single serialized entry point for
    /// refreshing `sessions` from the store. If a refresh is already running,
    /// mark one trailing run pending instead of spawning a concurrent Task —
    /// collapsing bursts (navigation + sync + streaming ticks) into at most one
    /// in-flight + one queued run. The ChatStore cache makes a clean run cheap.
    @MainActor
    func refreshSessionList() {
        guard !sessionRefreshInFlight else {
            sessionRefreshPending = true
            return
        }
        sessionRefreshInFlight = true
        Task(priority: .utility) { @MainActor in
            sessions = await ChatStore.shared.listSessions()
            folders = await ChatStore.shared.listFolders()
            sessionRefreshInFlight = false
            if sessionRefreshPending {
                sessionRefreshPending = false
                refreshSessionList()
            }
        }
    }

    // 启动加载独立于 View 表达式，保留原有异步顺序和任务生命周期。
    @MainActor
    func loadInitialSessionState() async {
        sessions = await ChatStore.shared.listSessions()
        // Folders must load WITH the first session batch: groupedSessionIDs
        // treats a folder_id whose folder isn't loaded as an orphan and
        // renders the session ungrouped, so a first paint with sessions
        // but no folders shows a flat list and the folder cards only
        // "appear after a while" (whenever refreshSessionList next ran —
        // the exact symptom reported from the Mac build).
        folders = await ChatStore.shared.listFolders()
        let shareAlreadyHandled = shareCoordinator.bufferVersion > 0
        // A Home Screen Quick Action that fired during launch will
        // open the right session itself via `quickActionRouter.newChatTrigger`.
        // Skip the Launch Session logic so we don't open a second,
        // conflicting session (the "last session" / "new chat"
        // launchScreen branch races the shortcut and the user ends
        // up watching one view replaced by the other).
        // Two signals indicate a quick-action launch is in flight:
        //   1. Router bumped newChatTrigger but ContentView hasn't
        //      consumed it yet (race: .task runs before .onAppear).
        //   2. QuickActionWorkflow is past .idle — router already
        //      called start(), workflow owns the next session to
        //      open. Even if (1) flipped because .onAppear already
        //      ran and consumed the trigger, the workflow is still
        //      mid-flight and the launch session would clobber it.
        let workflowActive: Bool = {
            if case .idle = QuickActionWorkflow.shared.state { return false }
            return true
        }()
        let quickActionPending = quickActionRouter.newChatTrigger != consumedQuickActionTrigger || workflowActive
        shareLog.info("[Share] .task: hasPendingShare=\(shareCoordinator.hasPendingShare) launchScreen=\(launchScreen) sessions=\(sessions.count) bufferVersion=\(shareCoordinator.bufferVersion) shareAlreadyHandled=\(shareAlreadyHandled) quickActionPending=\(quickActionPending) workflowActive=\(workflowActive)")

        // [T-notification-tap-vs-launch-session] A notification tap's
        // explicit target session outranks every launch-screen default.
        // Cold launch: didReceive fired before our .onReceive subscriber
        // existed, so the post was lost — the buffered copy is the only
        // surviving signal. Consume it and navigate. Warm-ish overlap: the
        // post arrived while this .task was awaiting listSessions() and
        // .onReceive already navigated — handledRecently suppresses the
        // launch-screen default so it can't clobber that navigation.
        if let notificationTarget = NotificationNavigationStore.shared.takePending() {
            shareLog.info("[Share] .task: notification tap target=\(notificationTarget.prefix(8)) — overriding launchScreen logic")
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { openSession(notificationTarget) }
        } else if NotificationNavigationStore.shared.handledRecently {
            shareLog.info("[Share] .task: notification navigation just handled — skipping launchScreen logic")
        } else if quickActionPending {
            shareLog.info("[Share] .task: quick action pending — deferring launchScreen logic to QuickActionRouter")
        } else if shareAlreadyHandled {
            // onChange(hasPendingShare) already processed the share and
            // opened a new session before .task ran. Skip normal launch
            // screen logic so we don't clobber it with a different session.
            shareLog.info("[Share] .task: share already handled by onChange — skipping launchScreen logic")
        } else if shareCoordinator.hasPendingShare {
            // onChange hasn't fired yet (e.g. onOpenURL arrived during await).
            // Process share here and open a new session for it.
            shareLog.info("[Share] .task: processing pending share")
            processPendingShare()
            shareLog.info("[Share] .task: buffer stored, bufferVersion=\(shareCoordinator.bufferVersion) buffer=\(shareCoordinator.pendingShareBuffer != nil)")
            // [T-share-routes-to-background-session] Cold launch: nothing is
            // on screen yet (this branch runs before any launch-screen
            // navigation), so the "foreground session" the warm path looks
            // for does not exist and a new session IS the right
            // destination. It is still stamped onto the buffer, which is
            // what stops a session restored moments later — e.g. the
            // Launch-Session default, or a chat resuming an agent loop —
            // from mounting first and swallowing the share.
            let target = Self.makeNewSessionId()
            shareCoordinator.setBufferTarget(target)
            shareLog.info("[Share] .task: cold launch — opening new session \(target.prefix(16)) for share")
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { openSession(target) }
        } else if CrashReporter.shared.shouldBypassSessionRestore {
            // [T-ios-session-crash-loop] The last two launches both died in
            // the foreground within a minute of each other — the signature
            // of a session that faults while loading and is then re-opened
            // automatically on the next launch, which the user cannot
            // escape from inside the app (they can reach neither Settings
            // to change the launch screen nor the list to delete it).
            //
            // Open nothing: fall through to the session list so the app is
            // usable again. Deliberately placed AFTER the notification-tap
            // and share branches — those are explicit, just-expressed user
            // intent, and a stale crash flag must not swallow them.
            CrashReporter.shared.clearCrashLoopFlag()
            shareLog.warning("[Share] .task: crash-loop detected — skipping session restore, landing on the session list")
        } else {
            // No share — normal launch screen behavior
            switch launchScreen {
            case 1:
                if let latest = sessions.first {
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { openSession(latest.id) }
                }
            case 2:
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { openSession(Self.makeNewSessionId()) }
            case 3:
                break
            default:
                if !sessions.isEmpty,
                   let latest = sessions.first,
                   Date().timeIntervalSince(latest.updatedAt) > 15 * 60 {
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { openSession(Self.makeNewSessionId()) }
                } else if isWideLayout, let latest = sessions.first {
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { openSession(latest.id) }
                }
            }
        }
        // iPad split launch: every launchScreen branch above has resolved
        // by now, so if the restored selection lives inside a collapsed
        // folder, expand that folder (accordion — closes the others) so
        // the selected row is actually visible in the sidebar instead of
        // hidden behind a collapsed card.
        if isWideLayout, let sid = selectedSessionId,
           let fid = sessions.first(where: { $0.id == sid })?.folderId,
           collapsedFolderIds.contains(fid) {
            toggleFolderCollapsed(fid)
        }
        didInitialLoad = true
        fetchAlarmsIfNeeded()
        await refreshRemoteDeviceSessions()
    }
}
