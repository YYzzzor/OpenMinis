//
//  ContentView+Search.swift
//  Minis - 首页（Views/ContentView）
//
//  搜索栏：搜索调度、收起、聚焦。
//
//  ContentView 文件地图见 ContentView/ContentView.swift。
//

import SwiftUI

extension ContentView {
    // MARK: - Search Bar

    func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchMatchedIds = nil
            searchMatchSnippets = [:]
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            let results = await ChatStore.shared.searchSessions(query: query)
            if !Task.isCancelled {
                searchMatchedIds = Set(results.map(\.session.id))
                // Build a sessionId → snippet map for body-only matches
                // (title matches don't need a snippet — the highlighted
                // title already shows the hit). T-search-highlight 8edb74f2.
                var snippets: [String: String] = [:]
                for r in results {
                    if !r.titleMatched, let snip = r.matchSnippet, !snip.isEmpty {
                        snippets[r.session.id] = snip
                    }
                }
                searchMatchSnippets = snippets
            }
        }
    }

    func dismissSearch() {
        withAnimation(.easeInOut(duration: 0.2)) { showSearchBar = false }
        searchText = ""
        searchMatchedIds = nil
        searchMatchSnippets = [:]
        searchTask?.cancel()
        searchFocused = false
    }

    /// [T-ios-search-focus-sticky] Auto-exit the search bar when the user
    /// navigates into a session (or starts a new chat) WITHOUT having typed an
    /// actual query. Rationale: tapping the search field then tapping a chat
    /// without searching used to leave the field revealed + focused on return,
    /// forcing a manual tap on the ✕. If there IS a non-blank query, we keep the
    /// search state intact so the user returns to their results. Whitespace-only
    /// text counts as empty. No-op when the search bar isn't shown.
    func dismissSearchIfEmptyOnNavigate() {
        guard showSearchBar else { return }
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissSearch()
    }

    /// Reveal the search bar (if hidden) and focus its text field. Bound to the
    /// hardware ⌘F shortcut while the session list is on screen. Focusing inside
    /// the reveal animation is unreliable, so set focus on the next runloop tick
    /// once the field exists in the view tree.
    func focusSearch() {
        if !showSearchBar {
            withAnimation(.easeInOut(duration: 0.2)) { showSearchBar = true }
        }
        DispatchQueue.main.async { searchFocused = true }
    }
}
