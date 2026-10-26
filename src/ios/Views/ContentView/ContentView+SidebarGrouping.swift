//
//  ContentView+SidebarGrouping.swift
//  Minis - 首页（Views/ContentView）
//
//  日期 / 置顶 / 文件夹分组，文件夹折叠与 mini bar，便于 diff 的 SidebarGroup 投影，行查找缓存。
//
//  ContentView 文件地图见 ContentView/ContentView.swift。
//

import SwiftUI

extension ContentView {
    // MARK: - Display Sessions

    /// Sessions filtered by active search query, or all sessions if not searching.
    var filteredSessions: [ChatSession] {
        guard let matchedIds = searchMatchedIds else { return sessions }
        return sessions.filter { matchedIds.contains($0.id) }
    }

    /// Group sessions by date period for section display, with pinned sessions at the top.
    private func groupedSessions(_ list: [ChatSession]) -> [(label: String, sessions: [ChatSession])] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [(label: String, sessions: [ChatSession])] = []
        var pinned: [ChatSession] = []
        var today: [ChatSession] = []
        var yesterday: [ChatSession] = []
        var thisWeek: [ChatSession] = []
        var thisMonth: [ChatSession] = []
        var earlier: [ChatSession] = []

        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) ?? now

        for session in list {
            if session.isPinned {
                pinned.append(session)
                continue
            }
            let d = session.updatedAt
            if calendar.isDateInToday(d) {
                today.append(session)
            } else if calendar.isDateInYesterday(d) {
                yesterday.append(session)
            } else if d > weekAgo {
                thisWeek.append(session)
            } else if d > monthAgo {
                thisMonth.append(session)
            } else {
                earlier.append(session)
            }
        }

        // Sort pinned by last-modified first, then pin time as tiebreaker
        pinned.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast)
        }

        if !pinned.isEmpty    { buckets.append(("Pinned", pinned)) }
        if !today.isEmpty     { buckets.append(("Today", today)) }
        if !yesterday.isEmpty { buckets.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty  { buckets.append(("This Week", thisWeek)) }
        if !thisMonth.isEmpty { buckets.append(("This Month", thisMonth)) }
        if !earlier.isEmpty   { buckets.append(("Earlier", earlier)) }
        return buckets
    }

    // MARK: - Sidebar diff cost (T-ios-session-list-equatable-jank)
    //
    // The sidebar `ForEach(groups)` fed SwiftUI the full `(label, [ChatSession])`
    // tuples. SwiftUI deep-compares the ForEach data on every transaction flush,
    // so it ran `Array<ChatSession>.==` over the whole list — O(session count) ×
    // a per-element ChatSession compare. On a device with many sessions that
    // pinned the main thread for ~1s (Debug only; Release optimizes the compare
    // away, and a small-library iPad never hit the threshold). Cheapening
    // ChatSession.== helped but didn't remove the O(N) array compare.
    //
    // These two helpers let the ForEach diff a `[String]` id list instead of a
    // `[ChatSession]` value array: the outer ForEach carries only labels + ids,
    // and rows look the session up by id. Grouping/sorting logic is unchanged —
    // groupedSessionIDs() just projects groupedSessions() down to ids.

    /// Grouped sidebar sections carrying only session IDs (cheap to diff),
    /// with folder sections interleaved after Pinned.
    ///
    /// Folder aggregates (glyphs / unread / active / paused) are computed HERE,
    /// in this single pass, and never in the header's body: the header is a
    /// high-frequency recompute path, and deriving "any member active" there
    /// would cost O(members) × folders × every AttributeGraph re-eval.
    func groupedSessionIDs(_ list: [ChatSession]) -> [SidebarGroup] {
        // Build the store snapshots ONCE per evaluation (each is O(its own
        // small population), replacing per-member store entry + per-member
        // Date allocation), then memo-check: on a hit — the common case for
        // the high-frequency re-eval paths (activity ticks, badge publishes
        // that changed nothing the sidebar shows) — the whole partition +
        // aggregation below is skipped and the previous array instance is
        // returned.
        let unreadIds = sidebarBadgeStore.unreadSessionIds
        let freshCornerIds = sidebarBadgeStore.freshCornerBadgeSessionIds(within: 24 * 3600)
        let activeIds = sidebarActivityTracker.resolvedActiveSessionIds
        let key = SidebarGroupsMemoKey(
            sessions: list.map {
                SidebarSessionKey(
                    id: $0.id, updatedAt: $0.updatedAt, pinnedAt: $0.pinnedAt,
                    isPinned: $0.isPinned, folderId: $0.folderId,
                    category: $0.category, title: $0.title)
            },
            folders: folders,
            collapsedFolderIds: collapsedFolderIds,
            pendingDraftId: pendingFolderDraft?.draftId,
            pendingDraftFolderId: pendingFolderDraft?.folderId,
            isSearching: isSearching,
            unreadIds: unreadIds,
            freshCornerIds: freshCornerIds,
            activeIds: activeIds,
            dayStamp: Calendar.current.startOfDay(for: Date()))
        if sidebarGroupsMemo.key == key {
            return sidebarGroupsMemo.groups
        }
        let groups = computeGroupedSessionIDs(
            list, unreadIds: unreadIds, freshCornerIds: freshCornerIds, activeIds: activeIds)
        sidebarGroupsMemo.key = key
        sidebarGroupsMemo.groups = groups
        #if DEBUG
        // [T-ios-badge-diag] Why the group card decided to light (or not).
        //
        // Placed AFTER the memo check on purpose: this is the miss path, which
        // only runs when something the sidebar actually shows has changed, so
        // it cannot spam. It is further gated to groups that have at least one
        // paused member, and to DEBUG — the aggregation itself is a hot
        // AttributeGraph path and must not pay for logging in Release.
        //
        // `paused` vs `fresh` is the whole diagnosis in one line: a group with
        // paused=3 fresh=0 badge=false is the window working; paused=3 fresh=3
        // on days-old sessions is the bug returning.
        // `g.ids` is emptied for a COLLAPSED folder — the very case the badge is
        // about — so member ids come from the source list by folderId instead.
        for g in groups {
            guard let fid = g.folderId else { continue }
            let members = list.filter { $0.folderId == fid }.map(\.id)
            let pausedCount = members.filter {
                sidebarBadgeStore.topCornerBadge(for: $0) == .paused
            }.count
            guard pausedCount > 0 else { continue }
            let freshCount = members.filter { freshCornerIds.contains($0) }.count
            AppLogger(category: "SessionBadgeStore").debug(
                "[BadgeGroup] folder=\(fid.prefix(8)) members=\(members.count) " +
                "paused=\(pausedCount) freshWithin24h=\(freshCount) collapsed=\(g.isCollapsed) " +
                "badgeLit=\(g.isCollapsed && g.anyPaused)")
        }
        #endif
        return groups
    }

    private func computeGroupedSessionIDs(
        _ list: [ChatSession],
        unreadIds: Set<String>,
        freshCornerIds: Set<String>,
        activeIds: Set<String>
    ) -> [SidebarGroup] {
        let folderById = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var filed: [(fid: String, session: ChatSession)] = []
        var unfiled: [ChatSession] = []
        for s in list {
            // Folder membership outranks pin FOR PLACEMENT: a filed session
            // renders inside its group even when pinned. (The original
            // pin-wins rule made "file a pinned session" look like a no-op —
            // the write succeeded but the session stayed in Pinned and the
            // group showed empty, reported as a bug.) The pin itself is NOT
            // touched: pinned members sort first within their group and keep
            // the row's pin glyph — filing must never silently unpin.
            //
            // A folder_id pointing at a folder we don't have locally (record
            // not yet synced in, or folder deleted on a peer) renders as
            // ungrouped rather than vanishing — the orphan-reference rule
            // from the design doc's sync section.
            //
            // A "New Chat in Group" DRAFT has no sessions row yet (folder_id
            // is written at promotion), so it rides pendingFolderDraft: the
            // draft renders inside its target group from the first moment
            // instead of popping into Today until the first message lands.
            let effectiveFid: String? = s.folderId
                ?? (pendingFolderDraft?.draftId == s.id ? pendingFolderDraft?.folderId : nil)
            if let fid = effectiveFid, folderById[fid] != nil {
                filed.append((fid: fid, session: s))
            } else {
                unfiled.append(s)
            }
        }

        let dateGroups = groupedSessions(unfiled).map {
            SidebarGroup(label: $0.label, ids: $0.sessions.map(\.id))
        }

        // `list` arrives updated_at DESC, so first-encounter order over the
        // filed sessions IS the folders' activity order (max member updatedAt
        // descending) — no separate sort needed.
        var folderOrder: [String] = []
        var members: [String: [ChatSession]] = [:]
        for entry in filed {
            if members[entry.fid] == nil { folderOrder.append(entry.fid) }
            members[entry.fid, default: []].append(entry.session)
        }
        // Folders with no (visible) members still render — a folder that
        // disappears whenever its sessions are filtered out reads as data
        // loss. EXCEPT during an active search: there the list is a result
        // set, and padding it with every non-matching folder as an empty card
        // is noise (found in review — search for a message and every folder
        // you own would tag along).
        if !isSearching {
            for f in folders.sorted(by: { $0.updatedAt > $1.updatedAt }) where members[f.id] == nil {
                folderOrder.append(f.id)
                members[f.id] = []
            }
        }

        var folderGroups: [SidebarGroup] = []
        for fid in folderOrder {
            guard let folder = folderById[fid] else { continue }
            let m = members[fid] ?? []
            // Display order: pinned members first (stable partition), the
            // rest by recency. Aggregates below deliberately keep using the
            // recency-ordered `m` — latestDate/summary mean "newest activity",
            // not "first displayed row".
            let displayOrdered = m.filter(\.isPinned) + m.filter { !$0.isPinned }
            var g = SidebarGroup(label: folder.name, ids: displayOrdered.map(\.id), folderId: fid)
            g.totalCount = m.count
            // Top-3 DISTINCT category glyphs by recency (m is recency-sorted).
            // Distinct because three code sessions rendering three identical
            // terminal glyphs carries no information.
            var seenCategories = Set<String>()
            for s in m where seenCategories.insert(s.category ?? "").inserted {
                let icon = sessionCategoryIcon(for: s.category)
                g.glyphs.append(FolderGlyph(systemName: icon.systemName, color: icon.color))
                if g.glyphs.count == 3 { break }
            }
            // Status passthrough as ONE early-exiting pass of hash lookups
            // (was three `contains` passes entering the observed stores per
            // member). anyPaused carries only FRESH corner badges (entered in
            // the last 24h; covers paused and every future non-unread kind) —
            // rows keep rendering their badges unfiltered; the window only
            // stops long-stale states from flagging the whole group forever.
            if !unreadIds.isEmpty || !activeIds.isEmpty || !freshCornerIds.isEmpty {
                for s in m {
                    if !g.anyUnread, unreadIds.contains(s.id) { g.anyUnread = true }
                    if !g.anyActive, activeIds.contains(s.id) { g.anyActive = true }
                    if !g.anyPaused, freshCornerIds.contains(s.id) { g.anyPaused = true }
                    if g.anyUnread, g.anyActive, g.anyPaused { break }
                }
            }
            g.isCollapsed = collapsedFolderIds.contains(fid)
            g.isFolderPinned = folder.isPinned
            // m is recency-sorted, so .first is the newest member.
            g.latestDate = m.first?.updatedAt
            g.summaryTitle = m.first?.title
            if g.isCollapsed { g.ids = [] }
            folderGroups.append(g)
        }
        // Pinned folders float above unpinned ones. Within each half the
        // activity order (first-encounter over the updated_at-DESC list) is
        // preserved — stable partition, not a re-sort.
        folderGroups = folderGroups.filter(\.isFolderPinned) + folderGroups.filter { !$0.isFolderPinned }
        // "Groups" divider above the folder block, mirroring the Today/
        // Yesterday labels, so the block separates from the pinned sessions
        // above it at a glance.
        if !folderGroups.isEmpty { folderGroups[0].showsGroupsHeader = true }

        // Assembly: Pinned → folders (by activity) → date buckets. This is the
        // design doc's simplified layout — a fixed folder block rather than
        // folders mixed into the date buckets — chosen because interleaving
        // would push cross-bucket decisions into groupedSessions, a function
        // already implicated in [T-ios-session-list-equatable-jank].
        if let first = dateGroups.first, first.label == "Pinned" {
            return [first] + folderGroups + dateGroups.dropFirst()
        }
        return folderGroups + dateGroups
    }

    /// Toggle a folder section collapsed/expanded and persist the set.
    /// Expansion is EXCLUSIVE (accordion): opening a folder closes every
    /// other one — only one folder interior is on screen at a time, which
    /// keeps the wrapped-container look unambiguous and the list short.
    func toggleFolderCollapsed(_ folderId: String, scrollProxy: ScrollViewProxy? = nil) {
        // [T-ios-folder-accordion-scroll-anchor] Keep the tapped folder in view
        // across the swap.
        //
        // Opening folder B closes folder A (accordion). When A sat ABOVE B and
        // the user had scrolled deep into A's long member list, A's rows are
        // removed from the List and everything below — including B, the folder
        // they just tapped — slides UP by A's full expanded height. That height
        // is routinely taller than the viewport, so B lands off-screen above the
        // top edge and the user has to scroll back to find what they opened.
        //
        // Fix: after the state change, bring B's header back into view IF it
        // left. This reuses the same anchor and proxy the mini-bar's "back to
        // header" jump already uses, so no new scroll infrastructure is
        // introduced. See the correction block at the end of this function for
        // why the scroll is conditional rather than unconditional.
        //
        // Only on EXPAND — collapsing is self-anchoring (the header the user
        // tapped stays exactly where it is; scrolling then would move content
        // out from under the finger for no reason).
        let willExpand = collapsedFolderIds.contains(folderId)

        // Animated again by request — with the jitter history baked into the
        // parameters. The original shaking had two ingredients: per-row glass
        // segments re-rendering every animation frame (that structure is gone;
        // the group is now ONE card, one glass shape), and a springy curve
        // whose oscillation read as continuous wobble. Hence a short plain
        // easeInOut: monotonic (no overshoot to re-measure), brief enough
        // that the List's per-frame self-size pass stays cheap.
        withAnimation(.easeInOut(duration: 0.25)) {
            if collapsedFolderIds.contains(folderId) {
                collapsedFolderIds = Set(folders.map(\.id))
                collapsedFolderIds.remove(folderId)
            } else {
                collapsedFolderIds.insert(folderId)
            }
        }
        UserDefaults.standard.set(Array(collapsedFolderIds), forKey: "collapsedFolderIds")

        // Deferred one runloop turn on purpose: the rows removed by the collapse
        // are still in the List when this returns, so measuring now would read
        // the pre-collapse geometry. Letting SwiftUI apply the structural change
        // first means the probe values below describe the layout the user will
        // actually see.
        //
        // MINIMAL CORRECTION, not "scroll to top". The first version of this fix
        // called `scrollTo(anchor: .top)` unconditionally on every expand, which
        // did keep the folder on screen but slammed it to the top edge even when
        // it had never moved — the tap read as "jump to top" rather than "expand
        // in place". Now the header's post-layout position is measured and a
        // scroll happens ONLY when it actually left the viewport:
        //
        //   - still fully on screen  → do nothing at all (the true in-place case)
        //   - pushed above the top   → bring it just inside the top edge
        //   - pushed below the bottom→ bring it just inside, still near the top,
        //                              since an expanded folder needs the space
        //                              BELOW its header to show members
        //
        // `anchor: .top` is still the landing spot when a correction is needed —
        // what changed is that it is now conditional. SwiftUI's ScrollViewProxy
        // has no "scroll by delta" primitive, so top-anchoring is the only way to
        // express "bring this into view"; the win is that the common case no
        // longer triggers it.
        if willExpand, let scrollProxy {
            DispatchQueue.main.async {
                let topEdge = folderMiniBarTopY
                let bottomEdge = folderListBottomY
                guard let headerY = folderHeaderTopY[folderId], bottomEdge > topEdge else {
                    // No probe reading yet (header never rendered, e.g. expanded
                    // programmatically while off screen). Fall back to the old
                    // unconditional behaviour rather than risk leaving the user
                    // staring at the wrong part of the list.
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scrollProxy.scrollTo("folderHeader-\(folderId)", anchor: .top)
                    }
                    return
                }

                // Keep a little slack at the top so a header sitting *exactly* on
                // the boundary isn't judged off-screen by a sub-point rounding
                // difference, and so a corrected header lands visibly inside the
                // edge rather than flush against it.
                let slack: CGFloat = 8
                let isAboveViewport = headerY < topEdge + slack
                let isBelowViewport = headerY > bottomEdge - slack

                guard isAboveViewport || isBelowViewport else {
                    // In place — the whole point of this refinement.
                    return
                }
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollProxy.scrollTo("folderHeader-\(folderId)", anchor: .top)
                }
            }
        }
    }

    /// Probe report sink. Animated so the mini-bar's insertion/removal
    /// transition actually plays; guarded so the (per-frame-capable) probe
    /// only ever mutates state on a real transition.
    func setFolderHeaderOffscreen(_ folderId: String, _ offscreen: Bool) {
        guard offscreenFolderHeaderIds.contains(folderId) != offscreen else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            if offscreen {
                offscreenFolderHeaderIds.insert(folderId)
            } else {
                offscreenFolderHeaderIds.remove(folderId)
            }
        }
    }

    /// The folder the mini-bar represents, or nil = no bar. Requires an
    /// EXPANDED folder (collapse may happen while the header is culled, with
    /// no probe alive to retract the offscreen mark — this guard is what
    /// keeps the bar honest) whose header is scrolled out, outside select
    /// mode. Deterministic pick in folder order when several qualify (only
    /// possible before the accordion has ever run).
    private var folderMiniBarFolder: ChatFolder? {
        guard !isSelecting else { return nil }
        return folders.first {
            offscreenFolderHeaderIds.contains($0.id) && !collapsedFolderIds.contains($0.id)
        }
    }

    /// Top-aligned overlay for both list layouts: measures the list's visible
    /// top edge (the probe threshold — the GeometryReader content respects
    /// the safe area, so its global minY IS "just under the nav bar") and
    /// floats the mini-bar when an expanded group's header is scrolled out.
    /// Pure overlay: the List's structure is untouched, and everything but
    /// the bar itself passes touches through.
    func folderMiniBarOverlay(_ scrollProxy: ScrollViewProxy) -> some View {
        GeometryReader { geo in
            let topY = geo.frame(in: .global).minY
            ZStack(alignment: .top) {
                if let folder = folderMiniBarFolder {
                    folderMiniBar(for: folder, scrollProxy: scrollProxy)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .onAppear {
                folderMiniBarTopY = topY
                folderListBottomY = geo.frame(in: .global).maxY
            }
            .onChange(of: topY) { folderMiniBarTopY = $0 }
            .onChange(of: geo.frame(in: .global).maxY) { folderListBottomY = $0 }
        }
    }

    /// Composed-icon glyphs for the mini-bar, resolved from the memoized
    /// groups (same aggregation that feeds the home card, so the two icons
    /// can't drift). The memo box may briefly hold the PREVIOUS evaluation's
    /// groups mid-update — visually identical for an icon tint, and the next
    /// evaluation converges.
    private func folderMiniBarGlyphs(_ folderId: String) -> [FolderGlyph] {
        sidebarGroupsMemo.groups.first { $0.folderId == folderId }?.glyphs ?? []
    }

    /// The floating mini-bar, 48pt capsule with TWO interaction zones:
    /// icon + name (leading) scrolls the list back to the group's header;
    /// the trailing filled-circle chevron collapses the group. Split per the
    /// redesign — the whole-bar-collapses behavior made "where am I" and
    /// "close this" the same target.
    private func folderMiniBar(for folder: ChatFolder, scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollProxy.scrollTo("folderHeader-\(folder.id)", anchor: .top)
                }
            } label: {
                HStack(spacing: 8) {
                    FolderComposedIcon(glyphs: folderMiniBarGlyphs(folder.id), diameter: 30)
                    // Folder names are user data — verbatim.
                    Text(folder.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(UIColor.label))
                        .lineLimit(1)
                }
                // Widen the tap zone to everything left of the chevron.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                // Retract the mark ourselves: if the header cell is culled
                // there is no probe alive to do it, and the display guard
                // alone would leave a stale entry pinning the NEXT
                // expansion's bar on.
                withAnimation(.easeInOut(duration: 0.2)) {
                    _ = offscreenFolderHeaderIds.remove(folder.id)
                }
                toggleFolderCollapsed(folder.id)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(UIColor.secondaryLabel))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(UIColor.tertiarySystemFill)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Collapse Group"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 48)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(UIColor.separator).opacity(0.5), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.15), radius: 8, y: 2)
        .padding(.top, 8)
        .padding(.horizontal, 24)
    }

    /// [T-ios-session-list-equatable-jank] Rebuild the id→ChatSession cache.
    /// Called from `.onChange(of: sessions)` — NOT per body eval — so the
    /// dictionary value is stable between session-list mutations and the row
    /// closures never trigger a per-frame Dictionary.== / ChatSession.== diff.
    func rebuildSessionsByIdCache() {
        sessionsByIdCache = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Resolve a session for a sidebar row by id, reading the @State cache.
    /// `displaySessions` may prepend a transient draft proxy (id ==
    /// selectedSessionId) that isn't in `sessions`; overlay that one case here
    /// so the iPad split list still resolves the New-Chat placeholder row.
    func sessionForRow(_ id: String) -> ChatSession? {
        if let cached = sessionsByIdCache[id] { return cached }
        // Draft proxy / placeholder rows live only in displaySessions, never in
        // `sessions` — fall back to a linear scan of that (tiny: base + 1).
        return displaySessions.first(where: { $0.id == id })
    }

    /// Sessions to display in the sidebar. Prepends a placeholder entry
    /// in iPad split mode when the user has opened a new (unsaved) session.
    /// The placeholder keeps the draft ID as its tag so `List(selection:)` stays matched.
    var displaySessions: [ChatSession] {
        let base = filteredSessions
        guard isWideLayout, let selId = selectedSessionId, Self.isNewSessionId(selId) else {
            return base
        }
        if let realId = newSessionRealId {
            // Session has been persisted — show it under the draft tag so the selection stays valid.
            // Use the real session's data (title, lastMessage) but with the draft ID.
            if let realSession = sessions.first(where: { $0.id == realId }) {
                let proxy = ChatSession(
                    id: selId,
                    title: realSession.title,
                    category: realSession.category,
                    modelId: realSession.modelId,
                    createdAt: realSession.createdAt,
                    updatedAt: realSession.updatedAt,
                    lastMessage: realSession.lastMessage
                )
                // Replace the real session with the proxy so there's no duplicate
                return [proxy] + base.filter { $0.id != realId }
            }
        }
        // Not yet persisted — show a "New Chat" placeholder
        let placeholder = ChatSession(
            id: selId,
            title: "New Chat",
            category: nil,
            modelId: "",
            createdAt: Date(),
            updatedAt: Date(),
            lastMessage: nil
        )
        return [placeholder] + base
    }
}
