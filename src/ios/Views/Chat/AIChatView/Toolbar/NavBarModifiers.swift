//
//  NavBarModifiers.swift
//  Minis - 聊天页（AIChatView）
//
//  导航栏标题 frame 和样式 modifier。
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

// MARK: - Swipe-to-Send Hint

/// Floating "send arrow + Release to send" hint shown while the user is
/// dragging the input bar upward. Extracted out of `inputBar` because
/// inlining `.overlay { HStack { … } .offset(…).animation(…) }` deepens
/// SwiftUI's already-fragile generic chain on `inputBar.body` and crashes
/// the runtime type-metadata decoder via deep recursion
/// (`swift_getTypeByMangledName...`). Keeping the overlay as a single named
/// struct lets the parent's generic signature collapse to one slot.
///
/// - `progress` 0...1: drag distance as a fraction of the send threshold.
///   Arrow opacity = `min(1, progress * 1.4)`. Capsule opacity ramps in
///   over `[0.4, 0.8]` so it reaches full opacity exactly at the arming
///   fraction (`kSendSwipeArmFraction = 0.8`), where the haptic tick
///   fires and lifting the finger sends.
/// - `armFraction`: the threshold at which release fires send. Drives the
///   spring "pop" animation so the visual confirmation matches behavior.
/// - `location`: live fingertip position in the input bar's coordinate
///   space. The hint sits ~60pt above the finger (about one thumb-tip).

// MARK: - Nav Bar Modifiers

struct NavTitleFrameModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // [NavTitleTopClip 2026-07-23] The principal titleView aligns to the
            // liquid-glass navbar's ~44pt band. Give it 46pt centered so tall
            // title glyphs (semibold 16pt + CJK/caps ascenders) render in full.
            //
            // [NavTitleTransitionClip 2026-07-23] Do NOT `.clipped()`. During a
            // push/pop transition the system interpolates the principal item's
            // frame/scale/alpha; a hard clip rectangle cuts the mid-transition
            // frames along the 46pt box far more aggressively than the steady
            // state (users saw the title sliced to half a line during the
            // animation). The 46pt frame only *sizes* the item for band
            // alignment — the 3-row stack's natural height already fits within
            // it at steady state (spacing -2, ~44pt), so there is nothing to clip
            // away, and letting transition frames render uncropped restores the
            // standard system title transition.
            content
                .frame(height: 46, alignment: .center)
        } else {
            content
        }
    }
}

struct NavBarStyleModifier: ViewModifier {
    @Binding var topSafeAreaInset: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // iOS 26: extend content behind nav bar so liquid-glass has
            // something to show through; the collection view's
            // contentInsetAdjustmentBehavior = .automatic keeps messages
            // starting below the bar.
            content
                .ignoresSafeArea(.container, edges: .top)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        } else {
            // iOS 16–18: opaque navbar background
            content
                .toolbarBackground(ChatColors.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .overlay(alignment: .top) {
                    // [T-ios-geometry-observer-crash] onGeometryChange replaces
                    // the GeometryReader scaffold (async-renderer SIGTRAP — see
                    // the floating-bar site). The proxy measures the same
                    // Color.clear the reader wrapped; ignoresSafeArea/frame
                    // stay outside it exactly as before, and the action's
                    // initial fire covers the old onAppear seed.
                    Color.clear
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.safeAreaInsets.top
                        } action: { topSafeAreaInset = $0 }
                        .ignoresSafeArea()
                        .frame(height: 0)
                }
        }
    }
}
