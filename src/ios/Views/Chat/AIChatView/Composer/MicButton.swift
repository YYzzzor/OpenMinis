//
//  MicButton.swift
//  Minis - 聊天页（AIChatView）
//
//  输入区麦克风按钮。
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

// MARK: - Mic Button (touch-release activation)

/// 点击一次直接进入录音；图标保留原尺寸，命中区域使用 44pt。
struct MicButton: View {
    @Binding var inputFocused: Bool
    var onTap: () -> Void

    var body: some View {
        Button {
            inputFocused = false
            onTap()
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(ChatColors.secondaryText)
                .frame(width: 34, height: 34)
                .background(ChatColors.inputIconBg, in: Circle())
                .overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))
                .frame(width: VoiceComposerStyle.buttonSize, height: VoiceComposerStyle.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("开始语音输入")
        .accessibilityIdentifier("voice.enter")
    }
}
