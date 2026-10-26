//
//  SidebarGroups.swift
//  Minis - 首页（Views/ContentView）
//
//  侧边栏分组的轻量模型：SidebarGroup、FolderGlyph、分组缓存的 key 和 memo。
//
//  ContentView 文件地图见 ContentView/ContentView.swift。
//

import SwiftUI

/// One sidebar section: a date bucket (folderId == nil) or a folder section.
/// Equatable and cheap on purpose — the sidebar ForEach diffs this on every
/// transaction flush, so it must stay a [String] + small scalars, never a
/// [ChatSession] ([T-ios-session-list-equatable-jank]).
struct SidebarGroup: Equatable {
    var label: String            // English key for date buckets; folder name otherwise
    var ids: [String]            // emptied when the folder is collapsed
    var folderId: String? = nil
    var totalCount: Int = 0      // member count incl. hidden-by-collapse rows
    var glyphs: [FolderGlyph] = []   // top-3 distinct member category glyphs
    var anyUnread = false
    var anyActive = false
    var anyPaused = false
    var isCollapsed = false
    var isFolderPinned = false
    var latestDate: Date? = nil      // newest member updatedAt (nil = empty folder)
    var summaryTitle: String? = nil  // newest member's title, for the subtitle line
    /// True on the FIRST folder group only: renders the "Groups" divider
    /// label (styled like the date-bucket headers) above the folder block.
    var showsGroupsHeader = false
}

/// A single composed-icon glyph. Small struct instead of a tuple because
/// tuples can't satisfy Equatable inside SidebarGroup's array.
struct FolderGlyph: Equatable {
    var systemName: String
    var color: Color
}

/// Projection of EXACTLY the per-session fields the sidebar grouping reads —
/// the memo key's session component. Deliberately excludes `lastMessage`
/// (the expensive field at the heart of [T-ios-session-list-equatable-jank]);
/// comparing N of these is a handful of short-string compares per element,
/// far cheaper than re-running the grouping.
struct SidebarSessionKey: Equatable {
    let id: String
    let updatedAt: Date
    let pinnedAt: Date?
    let isPinned: Bool
    let folderId: String?
    let category: String?
    let title: String?
}

/// Every input `groupedSessionIDs` depends on. Compared (not hashed) so a
/// hit is provably identical input — no collision risk. The badge/activity
/// sets are IN the key on purpose: they're both the aggregation inputs and
/// the invalidation signal (a badge aging past the 24h window changes the
/// freshly-built set, which misses the memo — same "next ambient refresh"
/// timing the unmemoized per-member query had). `dayStamp` invalidates the
/// date buckets when the calendar day flips.
struct SidebarGroupsMemoKey: Equatable {
    let sessions: [SidebarSessionKey]
    let folders: [ChatFolder]
    let collapsedFolderIds: Set<String>
    let pendingDraftId: String?
    let pendingDraftFolderId: String?
    let isSearching: Bool
    let unreadIds: Set<String>
    let freshCornerIds: Set<String>
    let activeIds: Set<String>
    let dayStamp: Date
}

/// Reference-type memo box held in @State: mutating its contents during a
/// body evaluation is legal (no observed value changes, so no re-entrant
/// invalidation), and identity survives ContentView struct re-inits. A memo
/// hit returns the SAME [SidebarGroup] array instance, so the downstream
/// ForEach diff takes the identical-storage fast path instead of comparing
/// element-wise.
final class SidebarGroupsMemo {
    var key: SidebarGroupsMemoKey?
    var groups: [SidebarGroup] = []
}
