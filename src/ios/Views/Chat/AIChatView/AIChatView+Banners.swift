//
//  AIChatView+Banners.swift
//  Minis - 聊天页（AIChatView）
//
//  内核启动遮罩、错误卡片、DEBUG 的复制会话数据和分叉横幅。
//
//  AIChatView 文件地图见 AIChatView/AIChatView.swift。
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

extension AIChatView {
    // MARK: - Kernel Boot Overlay

    @ViewBuilder
    var kernelBootOverlay: some View {
        switch vm.kernelStatus {
        case .booting:
            ZStack {
                ChatColors.background
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    // Same three-dot language as SessionLoadingCard — this
                    // overlay can appear right after the loading card on a
                    // cold entry, so a system spinner here read as "the old
                    // 菊花 came back".
                    LoadingDotsView(dotSize: 9, color: ChatColors.secondaryText)
                        .frame(height: 20)
                    Text("Booting Kernel")
                        .font(.subheadline)
                        .foregroundStyle(ChatColors.secondaryText)
                }
            }
            .transition(.opacity)
        case .failed(let msg):
            ZStack {
                ChatColors.background
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            .transition(.opacity)
        default:
            EmptyView()
        }
    }

    // MARK: - Error Banner

    func errorBanner(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer()
            Button { vm.errorMessage = nil } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
            }
            // [T-ios-voiceover-labels] Otherwise announced as "xmark".
            .accessibilityLabel(Text("Dismiss error", comment: "VoiceOver label for the button that dismisses the error banner"))
        }
        .contentShape(Rectangle())
        .onLongPressGesture {
            UIPasteboard.general.string = error
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
    }

    #if DEBUG
    /// Build a JSON representation of the full agent conversation history and copy it.
    func copySessionDataToClipboard() {
        Task {
            guard let sid = vm.sessionId else {
                UIPasteboard.general.string = "(no session)"
                return
            }
            let rawMessages = await ChatStore.shared.loadMessages(sessionId: sid)
            var entries: [[String: Any]] = []
            for msg in rawMessages {
                var partsJson: [[String: Any]] = []
                for part in msg.parts {
                    switch part {
                    case .text(let text):
                        partsJson.append(["type": "text", "text": text])
                    case .toolUse(let tu):
                        // Parse input JSON string back to dict for clean output
                        let inputObj = (try? JSONSerialization.jsonObject(
                            with: Data(tu.input.utf8))) ?? tu.input
                        partsJson.append(["type": "tool_use", "id": tu.toolUseId,
                                          "name": tu.name, "input": inputObj])
                    case .toolResult(let tr):
                        partsJson.append(["type": "tool_result", "tool_use_id": tr.toolUseId,
                                          "output": tr.output, "is_error": !tr.success])
                    case .mediaRef(let ref):
                        partsJson.append(["type": "media", "mime": ref.mimeType,
                                          "file": ref.originalFileName ?? ref.relativePath])
                    }
                }
                var entry: [String: Any] = [
                    "role": msg.role.rawValue,
                    "parts": partsJson,
                    "created": ISO8601DateFormatter().string(from: msg.createdAt)
                ]
                if let usage = msg.tokenUsage {
                    entry["usage"] = [
                        "input_tokens": usage.inputTokens,
                        "output_tokens": usage.outputTokens,
                        "cache_creation_tokens": usage.cacheCreationTokens,
                        "cache_read_tokens": usage.cacheReadTokens
                    ]
                }
                entries.append(entry)
            }
            if let data = try? JSONSerialization.data(withJSONObject: entries,
                                                      options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                UIPasteboard.general.string = str
            }
        }
    }
    #endif

    // MARK: - Fork Banner (Read-Only Mode)

    #if DEBUG
    var forkBanner: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text("Read-only session from another device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard let sid = sessionId, let devId = remoteDeviceId else { return }
                    Task {
                        if let forked = await SessionForkManager.shared.forkSession(
                            remoteSessionId: sid, remoteDeviceId: devId
                        ) {
                            // Navigate to the forked session
                            NotificationCenter.default.post(
                                name: .sessionDidCreate,
                                object: forked.id,
                                userInfo: ["navigate": true]
                            )
                        }
                    }
                } label: {
                    Label("Fork to Continue", systemImage: "arrow.branch")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }
    #endif
}
