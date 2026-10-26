//
//  BridgedWholeMessageV3.swift
//  Minis - V3 聊天消息列表（Agent/MessageList/CollectionViewMessageListV3）
//
//  用户 / 分隔线 / 系统信息消息行。
//
//  文件地图与拆分规则：CollectionViewMessageListV3.swift（本目录）。
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// Wraps the existing ChatMessageRow for user / compactDivider / systemInfo messages.
/// V3: No GeometryReader.
struct BridgedWholeMessageV3: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat

    var body: some View {
        ChatMessageRow(
            message: message,
            isActiveMessage: false,
            commandStartTime: nil,
            onStop: nil,
            onRetry: bridge.onRetry,
            onEdit: bridge.onEdit,
            onDeleteFrom: bridge.onDeleteFrom,
            onWithdraw: bridge.onWithdraw,
            autoRetryAttempt: 0,
            autoRetryCountdown: 0,
            canResume: false,
            onResume: nil,
            onCompact: bridge.onCompact,
            onCopyScreenshot: bridge.onCopyScreenshot,
            onShowCompactSummary: bridge.onShowCompactSummary,
            browserPool: nil,
            toolSnapshots: []
        )
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(message.role == .user ? "userMessage" : "wholeMessage")
    }
}
