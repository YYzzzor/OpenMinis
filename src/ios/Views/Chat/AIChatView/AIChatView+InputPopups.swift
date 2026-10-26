//
//  AIChatView+InputPopups.swift
//  Minis - 聊天页（AIChatView）
//
//  斜杠命令和 @ 提及弹层、行视图、弹层外观、附件网格。
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
    /// Single overlay containing whichever input popup is active (slash or
    /// `@`-mention). Kept in one overlay slot to avoid compounding SwiftUI
    /// generic types on the body, which previously caused a runtime
    /// type-metadata recursion crash.
    /// [T-slash-picker-constant-band] Fixed top reserve for the slash /
    /// mention popup. Dynamic Island + navbar + a comfortable visual
    /// gap below the title block. Using a constant beats reading
    /// `topSafeAreaInset` because that value reports the bare safe-area
    /// inset (status bar + Dynamic Island, ~59pt) and skips the
    /// principal-toolbar title — so any computation off it leaves the
    /// popup overlapping the title row. 260pt covers the worst case
    /// (iOS 18, 3-line custom titleView).
    private static let slashPickerTopReserve: CGFloat = 260
    private static let slashPickerBottomMargin: CGFloat = 16
    /// [T-slash-picker-fixed-height] Locked popup height: shows up to
    /// 4 rows, then scrolls. Row visual height ≈ 46pt (13pt title +
    /// 11pt subtitle + per-row vertical padding); +8pt accounts for
    /// the inner VStack's first/last cap. The popup is now strictly
    /// `slashPickerRowHeight * 4 + 8 = 192pt` regardless of how many
    /// commands match, so the band is predictable and rows beyond the
    /// 4th are reachable via the visible scrollbar.
    // 54pt covers the tallest standard slash row including the `/thinking`
    // entry — its inline ThinkingLevel picker pushes the row above the
    // 44pt minHeight baseline. Earlier 46pt + visible=4 → 192pt clipped
    // the 4th row's tail. ×4 + 8pt bottom breathing = 224pt.
    private static let slashPickerRowHeight: CGFloat = 54
    private static let slashPickerVisibleRows: Int = 4
    private static let slashPickerFixedHeight: CGFloat =
        slashPickerRowHeight * CGFloat(slashPickerVisibleRows) + 8

    @ViewBuilder
    var inputPopupOverlay: some View {
        ZStack {
            if vm.showSlashMenu && !vm.filteredSlashCommands.isEmpty {
                popupOverlayContainer(onDismiss: { vm.dismissSlashMenu() }) {
                    slashCommandMenu
                }
            } else if vm.showMentionMenu {
                popupOverlayContainer(onDismiss: { vm.dismissMentionMenu() }) {
                    mentionMenu
                }
            }
        }
        // Single spring drives both popups' show/hide transitions. Short
        // snappy curve (~0.22s) — instant on `/` / `@` keypress with a
        // touch of overshoot to read as iOS 26-native.
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: vm.showSlashMenu)
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: vm.showMentionMenu)
    }

    /// [T-ipad-inputbar-height-zero] Bounds of the window hosting the chat, in
    /// the same GLOBAL space `onGeometryChange(.global)` reports.
    ///
    /// `UIScreen.main.bounds` is NOT a valid stand-in: under Mac Catalyst and in
    /// iPad multitasking the app's window is a sub-rect of the screen, and the
    /// chat pane is further inset by the sidebar — so screen-relative math
    /// misjudges a perfectly on-screen composer as offscreen. Falls back to the
    /// screen when no key window is available (early layout / previews).
    func inputBarWindowBounds() -> CGRect {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let window else { return UIScreen.main.bounds }
        // SwiftUI's .global space is the window's own coordinate space, so the
        // window's bounds (origin .zero) — not its frame — is the right rect.
        return window.bounds
    }

    /// Shared transition modifier for the `/` and `@` popups. Layout (popup
    /// position relative to input bar top) is now driven by SwiftUI itself
    /// — popup sits as `.overlay(alignment: .bottom)` on a catcher view
    /// directly above the input bar, so the bottom edge of the popup is
    /// pinned to the input bar's top edge. No more `inputBarHeight` @State
    /// math, no more screen-bottom relative padding.
    ///
    /// What this container does:
    /// - Wraps `content()` with the slide-from-bottom + fade transition
    ///   so the popup shows / hides smoothly.
    /// - Sets `.frame(maxHeight: .infinity, alignment: .bottom)` so when
    ///   the catcher's frame is larger than the popup card, the card
    ///   stays bottom-aligned (matches input bar top).
    @ViewBuilder
    private func popupOverlayContainer<Content: View>(
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            // .compositingGroup() flattens the popup card (chrome + ScrollView
            // + rows) into a single rendering layer BEFORE the transition
            // applies. Without this, SwiftUI animates each child view
            // independently — the text rows often appear instantly at their
            // final position while the chrome background slides up behind
            // them ("text shows first, card catches up"). Forcing a single
            // compositing pass makes the whole card move/fade as one unit.
            .compositingGroup()
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
    }

    /// Slash command popup — matches FloatingToolBar width/radius/shadow, overlays on top of it.
    /// [T-slash-picker-scroll] Wrapped in ScrollView with a half-screen height
    /// cap so long command lists (skills + builtin actions) stay reachable
    /// even when their natural height would push the bottom rows behind the
    /// input bar / keyboard. Tap-outside dismiss lives in `inputPopupOverlay`.
    private var slashCommandMenu: some View {
        InputBarPopupChrome(maxContentWidth: maxContentWidth) {
            ScrollView {
                VStack(spacing: 0) {
                    let commands = vm.filteredSlashCommands
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, cmd in
                        let isSelected = index == vm.slashMenuSelectedIndex
                        // [T-slash-picker-section-divider] Hairline between
                        // builtin commands and user-installed Skills so the
                        // two groups are visually distinct. Fires when this
                        // row is the first skill row in the list.
                        if cmd.isSkill && index > 0 && !commands[index - 1].isSkill {
                            Divider()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                        }
                        if cmd.id == "thinking" {
                            let supported = vm.currentModelSupportsReasoning
                            SlashCommandRow(
                                cmd: cmd,
                                isSelected: isSelected,
                                memoryEnabled: vm.memoryEnabled,
                                thinkingLevel: vm.currentThinkingLevel,
                                thinkingSupported: supported,
                                availableLevels: vm.availableThinkingLevels,
                                onSetThinkingLevel: supported ? { level in
                                    vm.setThinkingLevel(level)
                                } : nil,
                                onToggleThinking: supported ? {
                                    let newLevel: ThinkingLevel = vm.currentThinkingLevel.isEnabled ? .off : .medium
                                    vm.setThinkingLevel(newLevel)
                                    vm.dismissSlashMenu()
                                } : nil
                            )
                        } else {
                            Button {
                                vm.executeSlashCommand(cmd)
                            } label: {
                                SlashCommandRow(
                                    cmd: cmd,
                                    isSelected: isSelected,
                                    memoryEnabled: vm.memoryEnabled
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(SlashMenuButtonStyle(isSelected: isSelected))
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(height: Self.slashPickerFixedHeight)
        }
    }

    /// `@` file-mention popup — mirrors slashCommandMenu styling.
    private var mentionMenu: some View {
        let rows = vm.filteredMentionEntries
        #if DEBUG
        let preview = rows.prefix(6).map { $0.basename }.joined(separator: ",")
        print("[MentionRender] mentionMenu body filter=\"\(vm.mentionFilter)\" rows.count=\(rows.count) first6=[\(preview)]")
        #endif
        return InputBarPopupChrome(maxContentWidth: maxContentWidth) {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    // Lock empty-state height to slashPickerFixedHeight so
                    // the popup card stays the same size whether matches
                    // are present or not — otherwise it collapses to a
                    // single-line height and the visual top edge jumps
                    // toward the input bar, breaking position parity with
                    // the slash popup (which is always 4-rows tall).
                    VStack {
                        HStack(spacing: 8) {
                            if FileMentionIndex.shared.isScanning {
                                ProgressView().scaleEffect(0.7)
                            }
                            Text(FileMentionIndex.shared.isScanning
                                 ? AppLocalized("Scanning files…")
                                 : AppLocalized("No matching files"))
                                .font(.system(size: 13))
                                .foregroundStyle(ChatColors.secondaryText)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        Spacer(minLength: 0)
                    }
                    .frame(height: Self.slashPickerFixedHeight)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                // The LazyVStack outer `.id(vm.mentionFilter)`
                                // forces a full re-create on every query change,
                                // which dodges any stale-row reuse pathology;
                                // inside, the per-row id can stay simple
                                // (positional index).
                                ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                                    let isSelected = index == vm.mentionSelectedIndex
                                    Button {
                                        vm.selectMention(entry)
                                    } label: {
                                        MentionRow(entry: entry, isSelected: isSelected, query: vm.mentionFilter)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(SlashMenuButtonStyle(isSelected: isSelected))
                                    .id(index)
                                }
                            }
                            // Tag the LazyVStack with the current filter so
                            // SwiftUI throws away its layout state when the
                            // search query changes. Without this, the lazy
                            // stack sometimes reused stale body content keyed
                            // off the previous query (the `@codex showing
                            // mteam-hub` symptom).
                            .id(vm.mentionFilter)
                        }
                        // [T-slash-picker-fixed-height] Match slash popup:
                        // exactly 4 rows tall, scrolls on overflow with the
                        // visible indicator above.
                        .scrollIndicators(.visible)
                        .frame(height: Self.slashPickerFixedHeight)
                        .onChange(of: vm.mentionSelectedIndex) { newIndex in
                            guard newIndex >= 0, newIndex < rows.count else { return }
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                    if FileMentionIndex.shared.isScanning {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.6)
                            Text("Scanning more locations…")
                                .font(.system(size: 11))
                                .foregroundStyle(ChatColors.secondaryText)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    /// Shared chrome wrapper for the `/` and `@` input-bar popups — locks
    /// the visual styling (dark/light background, 10pt rounded corners,
    /// 0.5pt border, soft shadow, width clamp via `maxWidth`, 12pt
    /// horizontal inset) so the two pickers stay pixel-identical. The
    /// caller supplies the content (ScrollView, LazyVStack, etc.) and
    /// owns its own height. We deliberately do NOT wrap the content in
    /// a ScrollView here because the two pickers want different scroll
    /// reader / lazy semantics — chrome only.
    ///
    /// Putting both popups behind the same chrome means matchedGeometryEffect
    /// in `inputPopupOverlay` interpolates the same outer frame regardless
    /// of which popup is firing, so the pop-from-`/`-button animation
    /// reads identically across the two.
    private struct InputBarPopupChrome<Content: View>: View {
        let maxContentWidth: CGFloat?
        @ViewBuilder let content: () -> Content

        var body: some View {
            content()
                .frame(maxWidth: .infinity)
                .background(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.15, alpha: 1) : UIColor.systemBackground }))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(UIColor.separator).opacity(0.3), lineWidth: 0.5)
                )
                .shadow(color: Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.08, alpha: 0.75) : UIColor(white: 0, alpha: 0.12) }), radius: 8, x: 0, y: 4)
                .frame(maxWidth: maxContentWidth)
                .padding(.horizontal, 12)
        }
    }

    /// A single row in the file-mention menu.
    private struct MentionRow: View {
        let entry: FileMentionEntry
        let isSelected: Bool
        let query: String

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : ChatColors.secondaryText)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.basename)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : ChatColors.primaryText)
                        .lineLimit(1)
                    Text(entry.displayPath)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : ChatColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(entry.mountName ?? entry.scope.displayLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : ChatColors.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            isSelected
                            ? Color.white.opacity(0.2)
                            : Color(UIColor.systemGray5)
                        )
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }

        private var iconName: String {
            if entry.isDirectory { return "folder" }
            switch entry.scope {
            case .workspace:   return "doc.text"
            case .attachments: return "paperclip"
            case .shared:      return "folder.badge.person.crop"
            case .skills:      return "sparkles"
            case .memory:      return "brain.head.profile"
            case .mount:       return "externaldrive"
            }
        }
    }

    /// Attachment grid extracted to help the Swift type-checker.
    @ViewBuilder
    var inputAttachmentGrid: some View {
        InputAttachmentGridView(
            attachments: vm.attachments,
            loadingVideoCount: vm.loadingVideoCount,
            onRemove: { attachment in vm.removeAttachment(attachment) },
            onMove: { fromID, toID in
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.moveAttachment(fromID: fromID, toID: toID)
                }
            }
        )
    }

    /// Button style for slash menu items — shows highlight on press.
    private struct SlashMenuButtonStyle: ButtonStyle {
        let isSelected: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background((isSelected || configuration.isPressed) ? Color.accentColor : Color.clear)
        }
    }

    /// Single row in the slash command menu.
    private struct SlashCommandRow: View {
        let cmd: AIChatViewModel.SlashCommand
        let isSelected: Bool
        let memoryEnabled: Bool
        var thinkingLevel: ThinkingLevel = .off
        var thinkingSupported: Bool = true
        var availableLevels: [ThinkingLevel] = ThinkingLevel.allCases
        var onSetThinkingLevel: ((ThinkingLevel) -> Void)?
        var onToggleThinking: (() -> Void)?

        var body: some View {
            HStack(spacing: 8) {
                // Label area — tap to toggle thinking on/off and dismiss
                HStack(spacing: 8) {
                    Group {
                        if cmd.id == "thinking" {
                            Image("ThinkingIcon")
                                .resizable()
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: cmd.icon)
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .foregroundStyle(thinkingIconColor)
                    .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        let isThinkingActive = cmd.id == "thinking" && thinkingLevel.isEnabled && thinkingSupported
                        let titleColor: Color = isThinkingActive
                            ? .blue : (isSelected ? .white : ChatColors.primaryText)
                        let subtitleText = (cmd.id == "thinking" && !thinkingSupported)
                            ? AppLocalized("Not supported by current model")
                            : cmd.subtitle
                        let subtitleColor: Color = (cmd.id == "thinking" && !thinkingSupported)
                            ? .secondary
                            : (isThinkingActive ? .blue.opacity(0.7) : (isSelected ? .white.opacity(0.7) : ChatColors.secondaryText))
                        // [T-slash-picker-product-rules] Title + subtitle
                        // each clamped to a single line. Long skill names
                        // and descriptions used to wrap and pump the row
                        // height past 60pt, which then snowballed into a
                        // multi-screen picker.
                        Text("/\(cmd.title.lowercased())")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitleText)
                            .font(.system(size: 11))
                            .foregroundStyle(subtitleColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .allowsHitTesting(cmd.id == "thinking")
                .onTapGesture { onToggleThinking?() }
                if cmd.id == "memory" {
                    // [T-ios-voiceover-labels] Status glyph, not a control:
                    // give it the on/off meaning in words instead of letting
                    // VoiceOver read "checkmark circle fill" / "slash circle".
                    Image(systemName: memoryEnabled ? "checkmark.circle.fill" : "slash.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(memoryEnabled ? (isSelected ? .white : .green) : (isSelected ? .white.opacity(0.6) : .secondary))
                        .accessibilityLabel(Text(
                            memoryEnabled
                                ? AppLocalized("Memory on", comment: "VoiceOver label for the memory status icon when enabled")
                                : AppLocalized("Memory off", comment: "VoiceOver label for the memory status icon when disabled")
                        ))
                }
                if cmd.id == "thinking" && thinkingSupported {
                    thinkingLevelPicker
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
        }

        private var thinkingIconColor: Color {
            guard cmd.id == "thinking" else {
                return isSelected ? .white.opacity(0.8) : ChatColors.secondaryText
            }
            if !thinkingSupported { return .secondary }
            return thinkingLevel.isEnabled ? .blue : (isSelected ? .white.opacity(0.8) : ChatColors.secondaryText)
        }

        private var thinkingLevelPicker: some View {
            let maxAvailable = availableLevels.last
            let isClamped = thinkingLevel.isEnabled && maxAvailable != nil && thinkingLevel > (maxAvailable ?? thinkingLevel)

            return HStack(spacing: 0) {
                ForEach(availableLevels, id: \.self) { level in
                    let isExactMatch = thinkingLevel == level
                    let isClampedHighlight = isClamped && level == maxAvailable
                    let isHighlighted = isExactMatch || isClampedHighlight

                    HStack(spacing: 1) {
                        Text(level.displayName)
                            .font(.system(size: 11, weight: isHighlighted ? .bold : .regular))
                        if isClampedHighlight {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .foregroundStyle(isHighlighted ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        isHighlighted
                            ? (isClampedHighlight
                                ? Color.orange.opacity(0.75)
                                : Color.blue)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onSetThinkingLevel?(isHighlighted ? .off : level) }
                    .id(level)
                }
            }
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
