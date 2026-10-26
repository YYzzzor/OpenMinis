//
//  SidebarActionChannels.swift
//  Minis - 首页（Views/ContentView）
//
//  会话上下文菜单的动作通道（SessionMenuActionChannel）和动作枚举。
//
//  ContentView 文件地图见 ContentView/ContentView.swift。
//

import SwiftUI

// MARK: - Session context-menu action channel

/// [T-ios-crash-contextmenu-uaf] Action relay for the sidebar session context
/// menu. Stored as @State in ContentView (stable lifetime); the concrete
/// SessionContextMenu view holds a reference to it but Equatable ignores it,
/// so SwiftUI's attribute-graph copy/release of the view struct only
/// retains/releases this single class reference — no closure captures that
/// could dangle.
@MainActor
final class SessionMenuActionChannel {
    var handler: ((SessionMenuAction) -> Void)?
    func send(_ action: SessionMenuAction) { handler?(action) }
}

enum SessionMenuAction {
    case togglePin(String)
    case exportJSON(String)
    case exportText(String)
    case editTitle(String)
    case regenerateTitle(String)
    case lockSession(String)
    case unlockSession(String)
    case duplicate(String)
    case forceSync(String)
    case forcePull(String)
    case select(String)
    case moveToFolder(String)
    case delete(String)
}
