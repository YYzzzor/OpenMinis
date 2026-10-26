//
//  SelectableMarkdownTextView+EditMenu.swift
//  MinisX - Markdown 渲染模块（Views/Chat/Markdown）
//
//  层级：TextKit - SelectableMarkdownTextView，编辑菜单
//
//  canPerformAction 过滤、菜单动作（复制 Markdown / 富文本 / 全文、分享、加入聊天输入框、
//  朗读回复 / 朗读选中）和 buildMenu（把系统朗读项换成 Minis TTS 项）。
//  朗读闭包 onReadAloud / onSpeakText 存放在核心文件。
//
//  模块地图与约定：Bridge/SelectableMarkdownView.swift。
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

extension SelectableMarkdownTextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Block edit-related actions since we're read-only; allow everything else
        // (select, copy, look up, share, Copy Markdown, etc.)
        let blocked: Set<String> = ["paste:", "cut:", "delete:", "_addShortcut:"]
        if blocked.contains(NSStringFromSelector(action)) {
            return false
        }
        // iOS 16: long-pressing inline NSTextAttachment objects that carry a
        // transparent placeholder UIImage (TableAttachment, CodeBlockAttachment,
        // MathAttachment, etc.) makes the system add "Copy Image" / "Save
        // Image" / "Share Image" entries to UIMenuController. The image is a
        // 1×1 transparent placeholder used so UIKit doesn't render a default
        // "?" glyph — copying it is meaningless. Filter the relevant
        // selectors so the menu only surfaces actions that work on the
        // underlying text. iOS 17+ uses UIEditMenuInteraction and doesn't
        // present these by default.
        let actionName = NSStringFromSelector(action)
        if actionName.localizedCaseInsensitiveContains("image") {
            return false
        }
        if action == #selector(copyMarkdown(_:))
            || action == #selector(copyRichText(_:))
            || action == #selector(copyScreenshotFromMenu(_:)) {
            return true
        }
        if action == #selector(addSelectionToChatInput(_:)) {
            return selectedRange.length > 0
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Append the currently-selected text to the active chat's input field
    /// via the `chatInputAppendRequested` notification. AIChatView listens
    /// and routes to `AIChatViewModel.appendToInputText`, which handles the
    /// `<existing> <selected> ` / `<selected> ` formatting.
    @objc func addSelectionToChatInput(_ sender: Any?) {
        guard selectedRange.length > 0,
              let range = Range(selectedRange, in: text) else { return }
        // [T-ios-inline-code-long-path-wrap] Strip the invisible spacers before
        // handing the text to the input bar, the same way `plainTextWithTables`
        // does for Copy / Read Selection. This path reads `text` directly, so it
        // would otherwise carry the ZWSPs that inline-code wrapping (and the CJK
        // emphasis pre-pass) inject into the rendered string.
        let snippet = String(text[range])
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200A}", with: "")
            .replacingOccurrences(of: MinisLayoutManager.inlineCodeLeadingPad, with: "")
        NotificationCenter.default.post(
            name: .chatInputAppendRequested,
            object: nil,
            userInfo: ["text": snippet]
        )
        // Drop the selection / dismiss the edit menu so the user sees the
        // result land in the input. Mirrors the system Copy behaviour.
        resignFirstResponder()
    }

    /// Copies the raw Markdown source to the pasteboard.
    @objc func copyMarkdown(_ sender: Any?) {
        // [T-ios-math-copy-latex-delimiters] Normalize LaTeX delimiters to the
        // $...$ / $$...$$ form that most LaTeX editors expect. LLM output often
        // uses the \(...\) / \[...\] alternate delimiters which are valid LaTeX
        // but not recognized by many markdown renderers.
        var md = rawMarkdown
        md = md.replacingOccurrences(of: "\\(", with: "$")
        md = md.replacingOccurrences(of: "\\)", with: "$")
        md = md.replacingOccurrences(of: "\\[", with: "$$")
        md = md.replacingOccurrences(of: "\\]", with: "$$")
        UIPasteboard.general.string = md
    }

    /// Override the standard Copy so selections spanning tables include table
    /// cell text instead of a single space (the default attachment fallback).
    override func copy(_ sender: Any?) {
        let range = selectedRange.length > 0 ? selectedRange : NSRange(location: 0, length: attributedText.length)
        UIPasteboard.general.string = plainTextWithTables(in: range)
    }

    /// Invokes the Copy Screenshot closure plumbed through from SwiftUI.
    @objc func copyScreenshotFromMenu(_ sender: Any?) {
        onCopyScreenshot?()
    }

    // MARK: - [T-selection-menu-minis-tts] Minis TTS menu actions

    @objc func readReplyFromMenu(_ sender: Any?) {
        onReadAloud?()
    }

    @objc func readSelectionFromMenu(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        // plainTextWithTables expands table/math attachments into speakable text.
        onSpeakText?(plainTextWithTables(in: selectedRange))
    }

    /// Copies the rendered rich text (RTF) to the pasteboard.
    @objc func copyRichText(_ sender: Any?) {
        let range = selectedRange.length > 0 ? selectedRange : NSRange(location: 0, length: attributedText.length)
        let subAttr = attributedText.attributedSubstring(from: range)
        if let rtfData = try? subAttr.data(from: NSRange(location: 0, length: subAttr.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            UIPasteboard.general.setData(rtfData, forPasteboardType: "public.rtf")
        }
        // Also write plain-text fallback that includes table cell content (the
        // RTF substring's NSTextAttachment for tables collapses to a space when
        // pasted into plain-text targets).
        UIPasteboard.general.string = plainTextWithTables(in: range)
    }

    /// Returns the plain-text representation of `range`, expanding any
    /// `TableAttachment` runs into tab-separated cell text so multi-block
    /// selections that span a table preserve table content on copy.
    private func plainTextWithTables(in range: NSRange) -> String {
        let attr = attributedText ?? NSAttributedString()
        guard range.location >= 0, NSMaxRange(range) <= attr.length else {
            return attr.string
        }
        var out = ""
        attr.enumerateAttribute(.attachment, in: range, options: []) { value, subRange, _ in
            if let table = value as? TableAttachment {
                out += table.plainText()
            } else if let math = value as? MathAttachment {
                // [T-ios-math-copy-latex-delimiters] Emit LaTeX with $...$ / $$...$$.
                if math.isBlock {
                    out += "$$\(math.latex)$$"
                } else {
                    out += "$\(math.latex)$"
                }
            } else {
                out += (attr.string as NSString).substring(with: subRange)
            }
        }
        // [T-md-cjk-emphasis-pairs] Strip the invisible spacers the markdown
        // pre-pass injects to fix CommonMark flanking around CJK punctuation
        // (ZWSP now; hair space from the pre-2026-05 fixers may survive in
        // cached attributed strings) — they must not leak into the clipboard
        // or the TTS text.
        return out
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200A}", with: "")
            .replacingOccurrences(of: MinisLayoutManager.inlineCodeLeadingPad, with: "")
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // [T-selection-menu-minis-tts] Remove the SYSTEM speech menu ("Speak…"
        // / "Spell") — it reads with the OS voice, bypassing the Minis TTS
        // stack (provider voices, sanitizer, fail-over). Replaced below with
        // our own Read Selection / Read Reply entries.
        builder.remove(menu: .speech)
        let copyMd = UICommand(
            title: AppLocalized("Copy Markdown"),
            image: UIImage(systemName: "text.quote"),
            action: #selector(copyMarkdown(_:))
        )
        let copyRtf = UICommand(
            title: AppLocalized("Copy Rich Text"),
            image: UIImage(systemName: "doc.richtext"),
            action: #selector(copyRichText(_:))
        )
        var extras: [UIMenuElement] = [copyMd, copyRtf]
        if onCopyScreenshot != nil {
            extras.append(UICommand(
                title: AppLocalized("Copy Screenshot"),
                image: UIImage(systemName: "camera.viewfinder"),
                action: #selector(copyScreenshotFromMenu(_:))
            ))
        }
        // [T-selection-menu-minis-tts] Minis-owned read-aloud entries. "Read
        // Selection" speaks just the selected range; "Read from Start" replays
        // the whole reply — both through the in-app TTS stack.
        // Matching speaker glyph family so the two read-aloud entries read as
        // one feature: selection = plain speaker, whole reply = speaker+waves.
        if selectedRange.length > 0, onSpeakText != nil {
            extras.append(UICommand(
                title: AppLocalized("Read Selection"),
                image: UIImage(systemName: "speaker.wave.1"),
                action: #selector(readSelectionFromMenu(_:))
            ))
        }
        if onReadAloud != nil {
            extras.append(UICommand(
                title: AppLocalized("Read from Start"),
                image: UIImage(systemName: "speaker.wave.2"),
                action: #selector(readReplyFromMenu(_:))
            ))
        }
        let extrasMenu = UIMenu(title: "", options: .displayInline, children: extras)
        // insertSibling(afterMenu: .standardEdit) pushes successive inserts
        // toward the anchor — i.e. the LAST inserted sibling lands closest to
        // standardEdit. Insert the secondary copy commands first so the
        // high-frequency "Add to Chat Input" action ends up immediately after
        // the system Copy item.
        builder.insertSibling(extrasMenu, afterMenu: .standardEdit)
        if selectedRange.length > 0 {
            let addToInput = UIMenu(title: "", options: .displayInline, children: [
                UICommand(
                    title: AppLocalized("Add to Chat Input"),
                    image: UIImage(systemName: "text.insert"),
                    action: #selector(addSelectionToChatInput(_:))
                )
            ])
            builder.insertSibling(addToInput, afterMenu: .standardEdit)
        }
    }
}
