//
//  BridgedAssistantFooterV3.swift
//  Minis - V3 聊天消息列表（Agent/MessageList/CollectionViewMessageListV3）
//
//  助手回合页脚：输入中 / 错误 / 继续 / 用量。
//
//  文件地图与拆分规则：CollectionViewMessageListV3.swift（本目录）。
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// Footer: typing indicator, error, resume banner, token usage.
/// V3: No GeometryReader. Sheet moved to zero-size overlay to prevent
/// inflated self-sizing from sheet-capable view modifiers.
struct BridgedAssistantFooterV3: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat

    // showUsage and usageContentVisible are on bridge, toggled by double-tap on block cells.

    /// [T-ios-typing-indicator-scope] Single source of truth on `ChatMessage`
    /// — see `shouldShowTypingIndicator` for the per-round semantics.
    var showsTypingIndicator: Bool {
        bridge.isActiveMessage && message.shouldShowTypingIndicator
    }

    /// True when any of the footer's conditional sections will actually
    /// render. When false the footer should collapse to zero height so it
    /// doesn't insert a phantom 4pt gap between the last assistant block
    /// and the next user message.
    private var hasFooterContent: Bool {
        let showTyping = showsTypingIndicator
        let showError = message.error != nil
        let showResume = bridge.canResume && message.error == nil
        let showUsageRow = message.streamInterruptCount > 0 || bridge.showUsage
        return showTyping || showError || showResume || showUsageRow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Typing indicator — "request out, nothing back yet", evaluated per
            // ROUND. See `ChatMessage.shouldShowTypingIndicator`.
            if showsTypingIndicator {
                TypingIndicator()
            }

            // Inline error
            if let error = message.error {
                inlineError(error)
            }

            // Resume banner
            if bridge.canResume && message.error == nil {
                resumeBanner
            }

            // Token usage
            if message.streamInterruptCount > 0 || bridge.showUsage {
                HStack(spacing: 6) {
                    if message.streamInterruptCount > 0 {
                        streamInterruptBadge(message.streamInterruptCount)
                    }
                    if bridge.showUsage, let usage = message.usage {
                        usageCapsule(usage)
                            .opacity(bridge.usageContentVisible ? 1 : 0)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, hasFooterContent ? 16 : 0)
        .padding(.vertical, hasFooterContent ? 2 : 0)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantFooter")
        // Sheet + contextMenu on zero-size overlay so they don't inflate self-sizing.
        // Both .sheet and .contextMenu wrap the view in interaction containers that
        // report inflated heights to systemLayoutSizeFitting, causing height oscillation.
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
                    // [T-ios-longpress-menu-preview-background] Opaque preview
                    // for the footer's zero-size Color.clear contextMenu overlay.
                    MessageContextMenuPreview(text: message.blocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.content).joined(separator: "\n\n"))
                }
        }
    }

    // MARK: - Footer sub-views

    @ViewBuilder
    private func inlineError(_ error: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = error
                } label: {
                    Label(AppLocalized("Copy Error"), systemImage: "doc.on.doc")
                }
            }
            Spacer()
            if bridge.autoRetryAttempt > 0 {
                Text("Retry in \(bridge.autoRetryCountdown)s (\(bridge.autoRetryAttempt)/\(AIChatViewModel.retryDelays.count))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12)).clipShape(Capsule())
            } else if let onRetry = bridge.onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold))
                        Text(AppLocalized("Retry")).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(ChatColors.primaryText.opacity(0.15)).clipShape(Capsule())
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var resumeBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill").font(.caption).foregroundStyle(.orange)
                Text(AppLocalized("Interrupted — tap Resume to continue")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let onResume = bridge.onResume {
                Button(action: onResume) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.caption.weight(.semibold))
                        Text(AppLocalized("Resume")).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.orange).clipShape(Capsule())
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func usageCapsule(_ usage: TokenUsage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer").font(.system(size: 9))
            Text(usageSummary(usage)).font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(ChatColors.userBubble.opacity(0.6)).clipShape(Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    @ViewBuilder
    private func streamInterruptBadge(_ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
            Text("\(count)").font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(Color.orange.opacity(0.8))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.orange.opacity(0.12)).clipShape(Capsule())
    }

    private func usageSummary(_ u: TokenUsage) -> String {
        var parts: [String] = []
        if u.latestContextTokens > 0 { parts.append("ctx:\(fmtTok(u.latestContextTokens))") }
        parts.append("in:\(fmtTok(u.inputTokens))")
        parts.append("out:\(fmtTok(u.outputTokens))")
        if u.cacheReadTokens > 0 { parts.append("cache:\(fmtTok(u.cacheReadTokens))") }
        if u.cacheCreationTokens > 0 { parts.append("+cache:\(fmtTok(u.cacheCreationTokens))") }
        return parts.joined(separator: " ")
    }
    private func fmtTok(_ c: Int) -> String {
        c >= 1000 ? (c >= 10000 ? "\(c/1000)k" : String(format: "%.1fk", Double(c)/1000)) : "\(c)"
    }
}
