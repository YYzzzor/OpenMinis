//
//  ContentView+Navigation.swift
//  Minis - 首页（Views/ContentView）
//
//  选中辅助、新建对话、Quick Action、导航路径提交、后台导航延迟、打开 / 切换会话。
//
//  ContentView 文件地图见 ContentView/ContentView.swift。
//

import SwiftUI

private let shareLog = AppLogger(category: "Share")
private let draftLog = AppLogger(category: "DraftSession")

extension ContentView {
    // MARK: - Selection Helpers

    /// Whether a session row should be highlighted as selected.
    func isSessionHighlighted(_ sessionId: String) -> Bool {
        if selectedSessionId == sessionId { return true }
        // Highlight the real session when a draft is selected and it has been persisted
        if let selId = selectedSessionId, Self.isNewSessionId(selId), sessionId == newSessionRealId { return true }
        return false
    }

    func fetchAlarmsIfNeeded() {
        // AlarmOffloadBridge references AlarmKit types (AlarmMetadata).
        // On OS versions where AlarmKit doesn't exist (e.g. macOS 14),
        // merely referencing the class triggers Swift runtime type resolution
        // that crashes in swift_getTypeByMangledNameInContextImpl.
        // Use a helper that isolates the reference behind @available.
        guard #available(iOS 26.0, *) else { return }
        _fetchAlarmsImpl()
    }

    @available(iOS 26.0, *)
    private func _fetchAlarmsImpl() {
        AlarmOffloadBridge.listAlarms { arr, _ in
            DispatchQueue.main.async {
                hasAlarms = (arr?.count ?? 0) > 0
            }
        }
    }

    // MARK: - Navigation Helper

    /// Handle a "new chat" request (notification or Quick Action trigger).
    ///
    /// Contract: "land on a fresh new chat, never hijack an existing one."
    /// Concretely:
    ///
    ///   1. If any chat is currently open (real OR draft, on iPad detail
    ///      OR iPhone navigation stack), unwind back to the session list
    ///      root WITHOUT animation — animated transitions race the
    ///      subsequent `openSession()` and the new chat sometimes never
    ///      appears (push coalesced into the running pop).
    ///   2. Once the unwind has settled (NavigationStack path empty on
    ///      iPhone, `selectedSessionId == nil` on iPad), open the new
    ///      draft session.
    ///   3. AIChatView's onAppear then consumes any
    ///      `QuickActionRouter.pendingChatAction` (.startVoice / .openCamera)
    ///      so voice / camera fires *inside* the new chat — never inside
    ///      the previous one.
    func handleNewChatRequest() {
        let newId = Self.makeNewSessionId()
        // Clear any stale flags left over from a prior quick-action
        // request that didn't run to completion (user backgrounded the
        // app, the pop-then-push dance got interrupted, etc).
        pendingNewChatAfterPop = false
        pendingNewChatTargetId = nil
        // If a workflow is mid-flight in ensuringHome, ContentView's
        // observers (`onChange(navigationPath)` / `onChange(selectedSessionId)`)
        // drive the home-then-open sequence. Otherwise this call came
        // from a non-quick-action source (in-app menu "New Chat") and
        // we just open directly.
        let workflowEnsuringHome: Bool = {
            if case .ensuringHome = QuickActionWorkflow.shared.state { return true }
            return false
        }()
        if workflowEnsuringHome {
            popToHomeForQuickAction()
            return
        }
        if isWideLayout {
            openSession(newId)
        } else {
            commitNavigationPath(NavigationPath([newId]))
            currentStackSessionId = newId
        }
    }

    /// Drive the quick-action workflow's `ensuringHome → pendingDispatch
    /// → waitingForChatMount` sequence. Pops whatever session is on top
    /// without animation; observers (see below) call `markHome` once
    /// the unwind is observable, and a separate observer for
    /// `pendingDispatch` opens the new session.
    private func popToHomeForQuickAction() {
        // [T-ios-bg-nav-push-watchdog] A pop supersedes any push still held
        // back from the background — flushing it later would resurrect a
        // session the workflow just asked us to leave. Dropped before the
        // `alreadyHome` check so the early return can't strand it either.
        //
        // Popping itself is NOT deferred: it tears a screen down rather than
        // laying a new one out (so it doesn't carry the cost this gate exists
        // to keep out of the watchdog window), and the quick-action state
        // machine advances from the `onChange(of: navigationPath)` observer
        // this write triggers — holding it back would stall `markHome`.
        pendingBackgroundNavigation = nil
        let alreadyHome = isWideLayout ? (selectedSessionId == nil) : navigationPath.isEmpty
        if alreadyHome {
            // Same-runloop advance — no SwiftUI commit needed.
            QuickActionWorkflow.shared.markHome()
            return
        }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            if isWideLayout {
                selectedSessionId = nil
            } else {
                navigationPath = NavigationPath()
                currentStackSessionId = nil
            }
        }
        // `onChange(navigationPath)` / `onChange(selectedSessionId)`
        // will fire next runloop with the empty state and call
        // `markHome` from there.
    }

    /// React to workflow state advancing past ensuringHome. When the
    /// workflow says it's ready for a session, mint a fresh draft id
    /// and open it; attach to the workflow so AIChatView's modifier
    /// can match.
    func openSessionForPendingQuickAction() {
        guard case .pendingDispatch = QuickActionWorkflow.shared.state else { return }
        let newId = Self.makeNewSessionId()
        if isWideLayout {
            openSession(newId)
        } else {
            commitNavigationPath(NavigationPath([newId]))
            currentStackSessionId = newId
        }
        QuickActionWorkflow.shared.attachTargetSession(newId)
    }

    /// Switch to `id` as the one and only session on screen, replacing whatever
    /// is currently there.
    ///
    /// [T-ios-moveto-transfer-race] Use this for any "jump straight to session
    /// X" navigation that can fire while another session is already on the
    /// stack (move-to, notification/intent opens). The compact branch must NOT
    /// do "animated pop, then push after a blind delay": the push lands inside
    /// the ~0.35s pop animation and SwiftUI coalesces or drops it, leaving the
    /// user on the session list with `currentStackSessionId` already updated —
    /// which then makes the retry guard swallow a second attempt at the same
    /// target. Replacing the path atomically inside a disabled-animation
    /// transaction is the pattern `handleNewChatRequest` already proved safe,
    /// and it commits in one runloop with no window for the race.
    /// [T-ios-bg-nav-push-watchdog] Commit a compact-layout `navigationPath`
    /// change, or hold it until the app is active again.
    ///
    /// Every compact navigation helper routes its path write through here so
    /// the background gate cannot be bypassed by adding a new caller. See
    /// `pendingBackgroundNavigation` for the crash evidence.
    ///
    /// `currentStackSessionId` is still assigned by the callers, exactly as
    /// before — it is the app's own "which session did we navigate to" record,
    /// read by the quick-action / move-to retry guards, and it must reflect the
    /// requested target immediately even when the UIKit push is deferred.
    /// `previousStackSessionId` stays in lockstep because it is maintained by
    /// the `onChange(of: navigationPath)` observer, which simply runs later —
    /// when the deferred path is actually committed.
    private func commitNavigationPath(_ newPath: NavigationPath) {
        // [T-share-first-tap-no-response] `.inactive` is NOT the state this
        // gate was built for. The watchdog kills it prevents come from a push
        // running AIChatView's whole first layout while the app is genuinely
        // BACKGROUNDED (T-ios-bg-nav-push-watchdog); `.inactive` means the app
        // is on its way to the foreground — the system is about to give it a
        // full frame budget — and iOS delivers `openURL` in exactly that state.
        //
        // Device log 2026-08-18 23:55:31: the share URL arrived at .478 with
        // the app `.inactive`, the navigation was deferred, and `.active` only
        // landed 31ms later. The user saw the app open on the home screen with
        // nothing happening and tapped Share a second time — the reported
        // "first tap does nothing". Deferring here bought no safety: the flush
        // performs the identical push moments later, just after the user has
        // already given up on it.
        let appState = UIApplication.shared.applicationState
        if appState == .background {
            // Coalesce: only the newest requested destination matters. An
            // earlier pending push that never became visible has nothing to
            // preserve. Overwriting also restarts the TTL, which is correct —
            // the newest request is the one whose freshness we care about.
            pendingBackgroundNavigation = (newPath, Date())
            shareLog.info("🔄SESSION deferring nav commit — app backgrounded (count=\(newPath.count))")
            return
        }
        pendingBackgroundNavigation = nil
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            navigationPath = newPath
        }
    }

    /// Apply a navigation change that was held back while backgrounded.
    /// Called from the `scenePhase == .active` observer.
    func flushPendingBackgroundNavigation() {
        guard let pending = pendingBackgroundNavigation else { return }
        // Re-check rather than trust the caller: the `.onAppear` backstop can
        // run while still backgrounded, and committing there would reinstate
        // exactly the synchronous background push this gate exists to prevent.
        // Keep it pending — a later flush will take it.
        // [T-share-first-tap-no-response] Mirrors commitNavigationPath: only a
        // genuinely BACKGROUNDED app must hold the push back. Blocking on
        // `.inactive` here too would re-deny the flush during the very
        // foreground transition that is supposed to release it.
        guard UIApplication.shared.applicationState != .background else { return }
        // Consume before the staleness check, not after: an expired request is
        // dropped for good. Leaving it parked would let a later foreground —
        // which is even further from the original intent — try again.
        pendingBackgroundNavigation = nil
        let age = Date().timeIntervalSince(pending.deferredAt)
        guard age <= Self.pendingBackgroundNavigationTTL else {
            shareLog.info("🔄SESSION discarding deferred nav commit — stale (age=\(Int(age))s > \(Int(Self.pendingBackgroundNavigationTTL))s, count=\(pending.path.count))")
            return
        }
        shareLog.info("🔄SESSION flushing deferred nav commit (count=\(pending.path.count) age=\(Int(age))s)")
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            navigationPath = pending.path
        }
    }

    func switchToSession(_ id: String) {
        if isWideLayout {
            openSession(id)
            return
        }
        searchFocused = false
        commitNavigationPath(NavigationPath([id]))
        currentStackSessionId = id
    }

    /// Opens a session in the appropriate layout mode.
    func openSession(_ id: String) {
        draftLog.info("🔑DRAFT openSession id=\(id) isWide=\(isWideLayout) prevSel=\(selectedSessionId ?? "nil") prevReal=\(newSessionRealId ?? "nil") prevDraft=\(activeDraftId ?? "nil")")
        // Dismiss keyboard when navigating to a session
        searchFocused = false
        if isWideLayout {
            // Reset new-session tracking when navigating away
            if Self.isNewSessionId(id) {
                newSessionRealId = nil
                activeDraftId = nil
            } else if let current = selectedSessionId, Self.isNewSessionId(current) {
                newSessionRealId = nil
                activeDraftId = nil
            }
            selectedSessionId = id
            draftLog.info("🔑DRAFT openSession DONE selectedSessionId=\(id)")
        } else {
            // [T-ios-bg-nav-push-watchdog] Append onto whatever the path WILL
            // be — a deferred commit is the newer truth, so basing the append
            // on the still-stale live `navigationPath` would drop it.
            var next = pendingBackgroundNavigation?.path ?? navigationPath
            next.append(id)
            commitNavigationPath(next)
            currentStackSessionId = id
        }
    }
}
