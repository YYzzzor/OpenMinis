//
//  ComposerSurface.swift
//  Minis - 聊天页（AIChatView）
//
//  输入区背景材质（文字 / 语音 / Canvas 共用）。
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

// MARK: - Composer Surface

/// Background + shadow for the composer's outer rounded container.
///
/// **[T-popup-white-patch 7a0e3d62] — the invariant both branches must keep.**
/// The fill is painted INSIDE a rounded shape, never as a rectangular
/// `.background(color)` + `.clipShape(...)` pair. With that older pairing the
/// host CALayer carried a rectangular backing colour which the system
/// text-selection / edit-menu pop animation snapshotted *before* SwiftUI's mask
/// applied, flashing a square of colour around the rounded corners mid-animation.
/// Filling the shape directly leaves the host layer's `backgroundColor` at
/// `.clear`, so the snapshot is already rounded. `clipShape` is still applied so
/// child views (text view, attachment grid) are clipped to the same rect.
///
/// `glassEffect(in:)` composites the material into the shape it is given, for
/// the same reason: it does not set a rectangular layer background, so it
/// preserves the invariant rather than reintroducing the bug. Verified on device
/// by long-pressing composer text to raise the edit menu — see the task notes.
///
/// The two hand-rolled shadows are dropped on the glass path (Liquid Glass
/// renders its own edge and shadow; stacking the old ones reads as a dark halo —
/// the same finding as the FAB conversion). The sub-26 branch keeps the original
/// fill and BOTH shadows byte-for-byte, including the dark-mode-only top shadow
/// that lifts the bar off the message list.
// 正式文字/语音输入及 Canvas 共用材质，切换模式只改变容器尺寸与圆角。
struct ComposerSurface: ViewModifier {
    var voiceStyle = false
    var isEnabled = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: voiceStyle ? VoiceComposerStyle.cornerRadius : 20, style: .continuous)
    }

    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
        } else {
            content
                .background(shape.fill(ChatColors.inputBg))
                .clipShape(shape)
                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 2)
                .shadow(color: Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.5) : UIColor(white: 0, alpha: 0) }), radius: 8, x: 0, y: -4)
        }
    }
}
