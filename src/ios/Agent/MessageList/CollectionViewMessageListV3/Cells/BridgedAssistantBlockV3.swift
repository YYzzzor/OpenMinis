//
//  BridgedAssistantBlockV3.swift
//  Minis - V3 聊天消息列表（Agent/MessageList/CollectionViewMessageListV3）
//
//  一个助手块（文本 / 思考 / 工具）及其长按菜单。
//
//  文件地图与拆分规则：CollectionViewMessageListV3.swift（本目录）。
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// Single block within an assistant turn — text, tool capsule, or info.
/// V3: No GeometryReader — UIKit self-sizing is the sole height source.
struct BridgedAssistantBlockV3: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat

    private var blockAccessibilityId: String {
        switch block.kind {
        case .text: return "assistantTextBlock"
        case .thinking: return "assistantThinkingBlock"
        case .shellTool: return "assistantShellBlock"
        case .fileReadTool: return "assistantFileReadBlock"
        case .fileWriteTool: return "assistantFileWriteBlock"
        case .fileEditTool: return "assistantFileEditBlock"
        case .browserTool: return "assistantBrowserBlock"
        case .readImageTool: return "assistantReadImageBlock"
        case .memoryTool: return "assistantMemoryBlock"
        case .info: return "assistantInfoBlock"
        }
    }

    var body: some View {
        AssistantBlockView(
            block: block,
            message: message,
            isActiveMessage: bridge.isActiveMessage,
            commandStartTime: bridge.isActiveMessage ? bridge.commandStartTime : nil,
            onStop: bridge.isActiveMessage ? bridge.onStop : nil,
            onTapBlank: { _ in
                toggleUsage()
            },
            onCopyScreenshot: { bridge.onCopyScreenshot?() },
            // [T-selection-menu-minis-tts] Selection-menu TTS: whole-reply
            // replay is suppressed while this reply is still streaming (same
            // rule as the overlay context menu); Read Selection stays available.
            onReadAloud: bridge.isStreaming ? nil : bridge.onReadAloud,
            onSpeakText: bridge.onSpeakText,
            browserPool: bridge.browserPool,
            toolSnapshots: bridge.toolSnapshots,
            highlightedBlockId: .constant(nil),
            detailBlock: $bridge.detailBlock
        )
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier(blockAccessibilityId)
        // Context menu on zero-size overlay so it doesn't inflate self-sizing
        // (same pattern as BridgedAssistantFooterV3).
        .overlay {
            Color.clear.frame(width: 0, height: 0)
                .contextMenu {
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(AppLocalized("Copy All"), systemImage: "doc.on.doc")
                    }
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(AppLocalized("Copy Markdown"), systemImage: "text.quote")
                    }
                    if let onReadAloud = bridge.onReadAloud {
                        Button {
                            onReadAloud()
                        } label: {
                            Label(AppLocalized("Read from Start"), systemImage: "play.circle")
                        }
                        // Greyed out while streaming so it can't clash with the
                        // live streaming TTS of the same reply.
                        .disabled(bridge.isStreaming)
                    }
                    if let onCopyScreenshot = bridge.onCopyScreenshot {
                        Button {
                            onCopyScreenshot()
                        } label: {
                            Label(AppLocalized("Copy Screenshot"), systemImage: "camera.viewfinder")
                        }
                    }
                    if let onForceSync = bridge.onForceSync {
                        Divider()
                        Button {
                            onForceSync()
                        } label: {
                            Label(AppLocalized("Force Sync"), systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    if let onCompact = bridge.onCompact {
                        Divider()
                        Button(role: .destructive) {
                            onCompact()
                        } label: {
                            Label(AppLocalized("Compact Above"), systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                } preview: {
                    // [T-ios-longpress-menu-preview-background] This .contextMenu
                    // is on a zero-size Color.clear overlay (kept zero-size to
                    // avoid inflating self-sizing), so without an explicit preview
                    // SwiftUI snapshots that transparent overlay → see-through
                    // preview. Supply an opaque card of the message text.
                    MessageContextMenuPreview(text: message.blocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.content).joined(separator: "\n\n"))
                }
        }
    }

    private func toggleUsage() {
        guard message.usage != nil else { return }
        if bridge.showUsage {
            withAnimation(.easeInOut(duration: 0.15)) { bridge.usageContentVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                bridge.showUsage = false
                // The footer cell may have been omitted from the snapshot
                // (no content at build time). Notify the coordinator so it
                // re-snapshots and removes the now-empty footer.
                NotificationCenter.default.post(name: .messageListNeedsResnapshot, object: nil)
            }
        } else {
            bridge.showUsage = true
            // The footer cell may not exist yet — notify the coordinator to
            // re-snapshot and insert it.
            NotificationCenter.default.post(name: .messageListNeedsResnapshot, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeInOut(duration: 0.2)) { bridge.usageContentVisible = true }
            }
        }
    }
}
