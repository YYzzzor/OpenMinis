//
//  AIChatViewModel+EditMessage.swift
//  Minis - AIChatViewModel 扩展（Agent/Chat）
//
//  编辑已发送的消息：回填输入框、进入和取消编辑。
//  代码从 AIChatViewModel.swift 逐字移出。
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UIKit
import os.log

private let logger = AppLogger(category: "AIChatVM")

extension AIChatViewModel {

    /// Append text to the chat input, separated by a single space on each side
    /// of an existing draft so quoted snippets stay visually distinct. A
    /// trailing space is always appended so the caret lands after a separator
    /// when the input regains focus. Whitespace-only inserts are dropped.
    ///
    /// Wired up to the `chatInputAppendRequested` notification posted by the
    /// long-press selection menu's "Add to Chat Input" action across markdown
    /// bubbles, table cells, etc.
    func appendToInputText(_ snippet: String) {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // [T-ios-append-to-input-eats-draft] Trim the incoming SNIPPET only.
        // The old code trimmed `inputText` too and assigned the trimmed copy
        // back, so "Add to input" silently rewrote the user's existing draft:
        // a deliberate trailing newline (paragraph break they had just typed)
        // was swallowed and replaced by the separator space. The draft is the
        // user's own text and must come back byte-for-byte.
        //
        // The emptiness test still runs on a trimmed view — a draft of only
        // whitespace should be treated as empty rather than producing a
        // leading blank run — but that trimmed value is used for the decision
        // ONLY, never for the assignment.
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = trimmed + " "
        } else {
            // Preserve the draft verbatim; only add a separator when it does
            // not already end in whitespace (a trailing newline is already a
            // separator, and appending a space after it would re-indent the
            // new line).
            let needsSeparator = !(inputText.last?.isWhitespace ?? false)
            inputText += (needsSeparator ? " " : "") + trimmed + " "
        }
    }

    /// Populate the input bar with the content of a user message for editing.
    /// The next call to send() will truncate the conversation from this message
    /// and re-run the agent loop with the edited content.
    func editMessage(_ messageId: UUID) {
        guard !isProcessing else { return }
        guard let idx = messages.firstIndex(where: { $0.id == messageId }),
              messages[idx].role == .user else { return }

        invalidateContextUsage()

        let msg = messages[idx]

        // Strip <user-attached-files> XML from content to get clean user text
        var text = msg.content
        if let start = text.range(of: "<user-attached-files>") {
            let end = text.range(of: "</user-attached-files>")
            let endBound = end?.upperBound ?? text.endIndex
            text = String(text[text.startIndex..<start.lowerBound] + text[endBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        inputText = text
        editingMessageIndex = idx

        // Restore attachments: convert AttachmentMeta back to InputAttachment
        // by locating the files in the session uploads directory.
        if !msg.attachments.isEmpty, let sid = sessionId {
            let uploadsDir = Self.minisUploadsDir(for: sid)
            var restored: [InputAttachment] = []
            for meta in msg.attachments {
                let fileName = (meta.path as NSString).lastPathComponent
                let fileURL = uploadsDir.appendingPathComponent(fileName)
                guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
                // Copy to Caches so the normal send() flow works
                let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("InputAttachments")
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                let cacheURL = cacheDir.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: cacheURL)
                try? FileManager.default.copyItem(at: fileURL, to: cacheURL)

                let ext = (fileName as NSString).pathExtension.lowercased()
                let kind: InputAttachment.Kind
                if ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext) {
                    kind = .image
                } else if ["mp4", "mov", "m4v"].contains(ext) {
                    kind = .video
                } else {
                    kind = .document
                }
                restored.append(InputAttachment(fileName: fileName, cacheURL: cacheURL, kind: kind))
            }
            attachments = restored
        }

        scrollToBottomSignal.send()
        logger.info("✏️ editMessage idx=\(idx) text=\(text.count)ch attachments=\(msg.attachments.count)")
    }

    func cancelEdit() {
        editingMessageIndex = nil
        inputText = ""
        attachments = []
        logger.info("✏️ cancelEdit")
    }

}
