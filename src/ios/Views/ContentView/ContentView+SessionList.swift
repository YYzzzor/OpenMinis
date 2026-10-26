//
//  ContentView+SessionList.swift
//  Minis - 首页（Views/ContentView）
//
//  侧边栏的 List / ForEach：行与文件夹分组。
//
//  ContentView 文件地图见 ContentView/ContentView.swift。
//

import SwiftUI

extension ContentView {
    // MARK: - Session List

    @ViewBuilder
    func sessionList(useNavigationLinks: Bool) -> some View {
        Group {
            if useNavigationLinks {
                stackList
            } else {
                splitList
            }
        }
        // Hardware ⌘F → focus search, available while the session list is on
        // screen (iPad/Mac keyboards). A zero-opacity button carries the
        // shortcut without affecting layout; it lives in the list's view tree so
        // the command only fires when the list is visible, not inside a chat.
        .background {
            Button(action: focusSearch) { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // [T-ios-migration-timer-toolbar-uaf-crash / T-ios-migration-timer-sessionlist-uaf-crash]
        // Own the migration-subtitle refresh driver here, on the stable sidebar list
        // body, instead of on the churny toolbar principal item (see `titleLabel`).
        // This Group has identity-stable lifetime across the sidebar's life — the
        // inner if/else only swaps which List renders, the wrapper itself is never
        // torn down — so the driver isn't rebuilt when the list content changes.
        //
        // The driver is a `.task` async loop, NOT a `Timer.publish().autoconnect()`
        // subscribed via `.onReceive`. The earlier `.onReceive(migrationProgressTimer)`
        // form still crashed (build 1.10(1)): a process-lived publisher's sink is a
        // SwiftUI attribute that AttributeGraph re-creates on every `body` transaction,
        // and a 5s tick delivered while that attribute is being torn down/rebuilt
        // releases the dangling sink closure → use-after-free (KERN_PROTECTION_FAILURE
        // in _AppearanceActionModifier.MergedCallbacks.updateValue → swift_release_dealloc).
        // The `.task` loop has no graph-bound publisher: SwiftUI owns the Task's
        // lifetime by view identity and cancels it deterministically on teardown, so
        // there is no sink to release mid-transaction. The loop also parks while the
        // app is backgrounded (the crash reproduced with the app in the background).
        // refreshMigrationSubtitle is idempotent (Task{@MainActor} + diff-before-assign).
        .task { await migrationSubtitleLoop() }
        // [T-ios-soul-name-sidebar-stale] Refresh the sidebar title from SOUL.md.
        // Moved here off the churny toolbar `titleLabel` Text (which rebuilds on
        // every canOpenSync/soulName/migrationSubtitle/isSelecting change) for the
        // same reason as the migration timer above: this Group's identity is stable
        // across the sidebar's life, so the sink is never torn down mid-transaction
        // and can't drop a .soulMdChanged notification arriving during reconstruction.
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            let n = SoulStore.cachedMetadata.displayName
            soulName = n.isEmpty ? "MinisX" : n
        }
    }

    /// Plain List with NavigationLink for stack (iPhone) layout.
    /// ScrollViewReader feeds the mini-bar's "back to header" jump; wrapping
    /// the List is inert otherwise (no layout/behavior change).
    private var stackList: some View {
        ScrollViewReader { scrollProxy in
        List {
            // [T-ios-session-list-equatable-jank] id-list projection — see splitList.
            let groups = groupedSessionIDs(filteredSessions)
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                Section {
                    // Folder card as the section's FIRST ROW, not its header:
                    // plain-List headers carry platform-specific chrome
                    // (spacing/padding differ between iPhone, iPad sidebar and
                    // Catalyst), which visibly detached the card from its
                    // member rows on iPad/macOS. Row-to-row adjacency is a
                    // guaranteed 0pt on every platform, so the container
                    // segments actually weld. (Cost: the card no longer pins
                    // while its members scroll — acceptable, accordion keeps
                    // sections short.)
                    if group.folderId != nil, !isSelecting {
                        folderSectionHeader(group, scrollProxy: scrollProxy)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .modifier(SelectionDisabledIfAvailable())
                    }
                    ForEach(group.ids, id: \.self) { sessionId in
                        // [T-ios-session-list-equatable-jank] Resolve via the
                        // @State cache (sessionForRow), NOT a captured
                        // [String:ChatSession] — see sessionsByIdCache.
                        if let session = sessionForRow(sessionId) {
                        if isSelecting {
                            selectableRow(session)
                                .id("select-\(session.id)")
                                .listRowInsets(EdgeInsets())
                        } else {
                            SessionRow(
                                session: session,
                                // [T-ios-ipad-sidebar-running-indicator-stale]
                                // Pass running/suspended as VALUES so a flip
                                // changes the SessionRow value → body re-evals
                                // in place (same identity, no cell rebuild).
                                isActive: sidebarActivityTracker.isActive(session.id),
                                isSuspended: sidebarConcurrencyManager.isSuspended(session.id),
                                highlightQuery: isSearching ? searchText : nil,
                                matchSnippet: isSearching ? searchMatchSnippets[session.id] : nil
                            )
                                // [T-ios-session-list-equatable-jank] Gate
                                // parent-driven re-eval on SessionRow's cheap
                                // custom == (rendered fields only), so a
                                // transaction flush from unrelated ContentView
                                // state churn doesn't deep-compare ChatSession.
                                .equatable()
                                // Entry D: long-press then move = drag the
                                // session id (never the ChatSession value —
                                // same id-only discipline as the list
                                // projection and the menu's value-semantics
                                // constraint). The SYSTEM arbitrates against
                                // .contextMenu on the same press: hold still →
                                // menu, hold then move → drag. Do not replace
                                // with a hand-rolled gesture sequence — the
                                // gesture layer is where system gestures are
                                // beaten (see the WebView sheet-dismiss fix).
                                .draggable(session.id)
                                .overlay {
                                    if regeneratingTitleSessionId == session.id {
                                        ZStack {
                                            Color(.systemBackground).opacity(0.7)
                                            ProgressView()
                                        }
                                    }
                                }
                                .background(
                                    NavigationLink(value: session.id) { EmptyView() }
                                        .opacity(0)
                                )
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Group {
                                if group.folderId != nil {
                                    FolderMemberRowBackground(isLast: sessionId == group.ids.last)
                                } else {
                                    Color(.systemBackground)
                                }
                            })
                            .contextMenu {
                                // [T-ios-crash-contextmenu-uaf] Value-only menu view,
                                // no closure captures — see SessionContextMenu.
                                SessionContextMenu(
                                    key: MenuKey(sid: session.id, pinned: session.isPinned, title: session.title, filed: session.isFiled),
                                    actions: menuActions
                                )
                                .equatable()
                            }
                        }
                        }  // if let session
                    }
                } header: {
                    // Folder groups render their card as the section's first
                    // ROW (above); the header slot serves the date buckets,
                    // the select-mode select-all, and — on the first folder
                    // group only — the "Groups" divider label.
                    if group.folderId == nil || isSelecting {
                        sectionHeader(index: index, group: group)
                    } else if group.showsGroupsHeader {
                        Text("Groups")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(UIColor.secondaryLabel))
                            .textCase(nil)
                    }
                }
            }

        }
        .listStyle(.plain)
        #if DEBUG
        // TEMPORARY scroll-phase markers to bracket the jitter window in the
        // log. Pair with the [ROWH] probe: a [ROWH] line appearing during
        // `decelerating`/`idle` = a self-size correction mid/post-scroll =
        // the visible jump. Remove with the probe. (iOS 18+ only.)
        .modifier(ScrollPhaseProbe())
        #endif
        .opacity(didInitialLoad ? 1 : 0)
        .overlay { if didInitialLoad, filteredSessions.isEmpty, !isSearching { emptyState } }
        .overlay(alignment: .top) { folderMiniBarOverlay(scrollProxy) }
        .safeAreaInset(edge: .bottom) { if isSelecting { selectionToolbar } else { fabRow } }
        // [T-home-fab-keyboard-inset] Mirror of the voice panel's structural
        // immunity (604a9947 / T-voice-bg-fg-gap): with the inline search bar
        // closed, nothing down here accepts text — any keyboard inset reaching
        // this list is a stale/zombie one (stranded responder, interrupted
        // bg-snapshot dismiss) and must not push the 新建/搜索 FABs up. With
        // the search bar open its TextField legitimately rises with the
        // keyboard, so normal avoidance is restored.
        .ignoresSafeArea(.keyboard, edges: showSearchBar ? [] : .bottom)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { sidebarToolbarContent }
        }
    }

    /// Selection-bound List for split (iPad) layout.
    /// ScrollViewReader: same mini-bar jump wiring as stackList.
    private var splitList: some View {
        ScrollViewReader { scrollProxy in
        List(selection: $selectedSessionId) {
            // [T-ios-session-list-equatable-jank] Diff a (label, ids) projection
            // so SwiftUI compares a [String] id list, not a [ChatSession] value
            // array. Rows resolve the model via displaySessionsById.
            let groups = groupedSessionIDs(displaySessions)
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                Section {
                    // Folder card as first row — see the sidebar list's
                    // comment: plain-List headers carry platform-specific
                    // chrome and detached the card from its members on
                    // iPad/macOS; row adjacency welds on every platform.
                    if group.folderId != nil, !isSelecting {
                        folderSectionHeader(group, scrollProxy: scrollProxy)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .modifier(SelectionDisabledIfAvailable())
                    }
                    ForEach(group.ids, id: \.self) { sessionId in
                        // [T-ios-session-list-equatable-jank] Resolve via the
                        // @State cache (sessionForRow), NOT a captured
                        // [String:ChatSession] — see sessionsByIdCache.
                        if let session = sessionForRow(sessionId) {
                        if isSelecting {
                            selectableRow(session)
                                .id("select-\(session.id)")
                                .listRowInsets(EdgeInsets())
                        } else {
                            SessionRow(
                                session: session,
                                isHighlighted: isSessionHighlighted(session.id),
                                // [T-ios-ipad-sidebar-running-indicator-stale]
                                // Pass running/suspended as VALUES so a flip
                                // changes the SessionRow value → body re-evals
                                // in place (same identity, no cell rebuild).
                                isActive: sidebarActivityTracker.isActive(session.id),
                                isSuspended: sidebarConcurrencyManager.isSuspended(session.id),
                                highlightQuery: isSearching ? searchText : nil,
                                matchSnippet: isSearching ? searchMatchSnippets[session.id] : nil
                            )
                                // [T-ios-session-list-equatable-jank] Gate
                                // parent-driven re-eval on SessionRow's cheap
                                // custom == (rendered fields only), so a
                                // transaction flush from unrelated ContentView
                                // state churn doesn't deep-compare ChatSession.
                                .equatable()
                                // Entry D: long-press then move = drag the
                                // session id (never the ChatSession value —
                                // same id-only discipline as the list
                                // projection and the menu's value-semantics
                                // constraint). The SYSTEM arbitrates against
                                // .contextMenu on the same press: hold still →
                                // menu, hold then move → drag. Do not replace
                                // with a hand-rolled gesture sequence — the
                                // gesture layer is where system gestures are
                                // beaten (see the WebView sheet-dismiss fix).
                                .draggable(session.id)
                                .overlay {
                                    if regeneratingTitleSessionId == session.id {
                                        ZStack {
                                            Color(.systemBackground).opacity(0.7)
                                            ProgressView()
                                        }
                                    }
                                }
                                // [T-ios-selected-session-contextmenu] Attach the
                                // contextMenu to the row CONTENT, not to the list-row
                                // modifier chain. On iPadOS / macOS this List uses
                                // `List(selection:)` + `.tag()`; the currently-selected
                                // row's selection gesture swallows the long-press (iPad)
                                // / right-click (mac), so a contextMenu placed at the
                                // list-row level never fires for the open session
                                // (GH#30 / TG36272). Binding it to the SessionRow view
                                // itself puts it below the selection layer, so it
                                // triggers on every row regardless of selection state.
                                // iPhone uses `stackList` (no selection:) and is
                                // unaffected.
                                .contextMenu {
                                    // [T-ios-ipad-new-session-contextmenu-broken / GH#30]
                                    // The selected new-chat row keeps the DRAFT id as its
                                    // tag even after the user sends a message and the
                                    // session is persisted (displaySessions swaps in a
                                    // proxy with realSession data under the draft id, so
                                    // List(selection:) stays matched). The old guard
                                    // `if !isNewSessionId(session.id)` then suppressed the
                                    // context menu for that row forever — until the user
                                    // switched away and the id resolved to the real one.
                                    // Fix: a draft row that has already been persisted
                                    // (newSessionRealId != nil) is a real, operable
                                    // session — surface the menu, targeting the REAL id.
                                    // Only a truly empty, never-sent draft (no realId)
                                    // still has no menu.
                                    // [T-ios-crash-contextmenu-uaf] Value-only menu, no closure.
                                    let menuSid = Self.isNewSessionId(session.id)
                                        ? newSessionRealId
                                        : session.id
                                    if let menuSid {
                                        SessionContextMenu(
                                            key: MenuKey(sid: menuSid, pinned: session.isPinned, title: session.title, filed: session.isFiled),
                                            actions: menuActions
                                        )
                                        .equatable()
                                    }
                                }
                                .tag(session.id)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    ZStack {
                                        if group.folderId != nil {
                                            let isLast = sessionId == group.ids.last
                                            FolderMemberRowBackground(isLast: isLast)
                                            // Flush selection band inside the group;
                                            // the last member's band takes the
                                            // container's bottom radii so it stays
                                            // wrapped by the corners.
                                            if isSessionHighlighted(session.id) {
                                                UnevenRoundedRectangle(
                                                    topLeadingRadius: 0,
                                                    bottomLeadingRadius: isLast ? 16 : 0,
                                                    bottomTrailingRadius: isLast ? 16 : 0,
                                                    topTrailingRadius: 0,
                                                    style: .continuous
                                                )
                                                .fill(Color(red: 183/255.0, green: 175/255.0, blue: 150/255.0).opacity(0.3))
                                                .padding(.horizontal, 6)
                                                .padding(.bottom, isLast ? 4 : 0)
                                            }
                                        } else {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(isSessionHighlighted(session.id)
                                                      ? Color(red: 183/255.0, green: 175/255.0, blue: 150/255.0).opacity(0.3)
                                                      : Color.clear)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                        }
                                    }
                                )
                        }
                        }  // if let session
                    }
                } header: {
                    // Folder groups render their card as the section's first
                    // ROW (above); the header slot serves the date buckets,
                    // the select-mode select-all, and — on the first folder
                    // group only — the "Groups" divider label.
                    if group.folderId == nil || isSelecting {
                        sectionHeader(index: index, group: group)
                    } else if group.showsGroupsHeader {
                        Text("Groups")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(UIColor.secondaryLabel))
                            .textCase(nil)
                    }
                }
            }

        }
        .listStyle(.plain)
        .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 500)
        .opacity(didInitialLoad ? 1 : 0)
        .overlay { if didInitialLoad, displaySessions.isEmpty, !isSearching { emptyState } }
        .overlay(alignment: .top) { folderMiniBarOverlay(scrollProxy) }
        .safeAreaInset(edge: .bottom) { if isSelecting { selectionToolbar } else { fabRow } }
        // [T-home-fab-keyboard-inset] Same structural immunity as the compact
        // list above — see that call site for the full rationale. On iPad the
        // sidebar column never hosts a keyboard unless the inline search bar
        // is open (the chat column's composer avoidance is its own subtree).
        .ignoresSafeArea(.keyboard, edges: showSearchBar ? [] : .bottom)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { sidebarToolbarContent }
        }
    }
}
