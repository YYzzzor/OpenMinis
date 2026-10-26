//
//  RawMessage+Conversion.swift
//  Minis - 聊天持久化（Agent/Chat）
//
//  RawMessage 转 ChatMessage（界面）/ AgentMessage（Agent 历史）。
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

// MARK: - UI Conversion

extension RawMessage {
    /// Convert to ChatMessage for UI display.
    /// Images render from file URL — no base64 loading needed.
    func toChatMessage(mediaResolver: (MediaRef) -> URL, showThinking: Bool = true) -> ChatMessage {
        let uiRole: ChatMessageRole = role == .user ? .user : .assistant

        // Build display content from parts
        var textContent = ""
        var blocks: [AssistantBlock] = []
        var userAttachments: [AttachmentMeta] = []

        // ISO8601 parser for attachment metadata
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        /// Track the last known browser URL across tool blocks so actions like
        /// get_readable (which don't carry a url arg) can inherit it.
        var lastBrowserURL: String?

        for part in parts {
            switch part {
            case .text(let s):
                if role == .assistant {
                    let visible = Self.stripSystemReminders(s)
                    if !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // [T-ios-longmsg-cell-split] Split a very long reply into
                        // several text blocks instead of one enormous cell.
                        //
                        // A contiguous assistant reply used to become exactly ONE
                        // `.text` block no matter how long, and the message list
                        // gives each block its own cell — so a 9156-char answer
                        // became a single 20615pt cell backed by one UITextView.
                        // Field log from the render-collapse report shows exactly
                        // that shape: `blocks=288` markdown blocks all inside one
                        // AssistantBlock, and `visibleCells=1` for the whole
                        // 50559pt list while dragging.
                        //
                        // Splitting keeps EVERY character — this is not a clip.
                        // It only changes how many cells carry them, which bounds
                        // each UITextView/CALayer and lets UICollectionView
                        // recycle off-screen parts (the same reasoning as
                        // PaginatedMarkdownView, whose fence-aware splitter is
                        // reused here rather than reimplemented).
                        //
                        // Load-time only, on purpose: this is the DB path, so a
                        // message is split once it is finished and persisted.
                        // The streaming path builds its blocks in memory and is
                        // untouched, which is what keeps split points from
                        // shifting under a growing message.
                        for segment in Self.splitLongAssistantText(visible) {
                            blocks.append(AssistantBlock(kind: .text, content: segment))
                        }
                    }
                }
                // Extract structured attachment metadata from <user-attached-files> XML
                // and strip it from user-visible display text
                var displayStr = s
                if role == .user, s.contains("<user-attached-files>") {
                    let openTag = "<user-attached-files>"
                    let closeTag = "</user-attached-files>"
                    if let range = s.range(of: openTag) {
                        let endBound: String.Index
                        if let endRange = s.range(of: closeTag) {
                            endBound = endRange.upperBound
                            let body = String(s[range.upperBound..<endRange.lowerBound])

                            if body.contains("<file ") {
                                // New XML format: <file path="..." url="..." size="..." modified="..." />
                                let filePattern = try? NSRegularExpression(
                                    pattern: #"<file\s+path="([^"]*)"(?:\s+url="([^"]*)")?(?:\s+size="([^"]*)")?(?:\s+modified="([^"]*)")?\s*/>"#
                                )
                                let nsBody = body as NSString
                                let matches = filePattern?.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) ?? []
                                for match in matches {
                                    let path = match.range(at: 1).location != NSNotFound ? nsBody.substring(with: match.range(at: 1)) : ""
                                    let sizeStr = match.range(at: 3).location != NSNotFound ? nsBody.substring(with: match.range(at: 3)) : "0"
                                    let modStr = match.range(at: 4).location != NSNotFound ? nsBody.substring(with: match.range(at: 4)) : ""
                                    if !path.isEmpty {
                                        userAttachments.append(AttachmentMeta(
                                            path: path,
                                            size: Int(sizeStr) ?? 0,
                                            modified: isoFormatter.date(from: modStr) ?? self.createdAt
                                        ))
                                    }
                                }
                            } else {
                                // Legacy YAML format: - path: ...
                                var currentPath: String?
                                var currentSize: Int?
                                var currentModified: Date?
                                for line in body.components(separatedBy: "\n") {
                                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                                    if trimmed.hasPrefix("- path: ") {
                                        if let path = currentPath {
                                            userAttachments.append(AttachmentMeta(
                                                path: path,
                                                size: currentSize ?? 0,
                                                modified: currentModified ?? self.createdAt
                                            ))
                                        }
                                        currentPath = String(trimmed.dropFirst("- path: ".count))
                                        currentSize = nil
                                        currentModified = nil
                                    } else if trimmed.hasPrefix("size: ") {
                                        currentSize = Int(trimmed.dropFirst("size: ".count))
                                    } else if trimmed.hasPrefix("modified: ") {
                                        currentModified = isoFormatter.date(from: String(trimmed.dropFirst("modified: ".count)))
                                    }
                                }
                                if let path = currentPath {
                                    userAttachments.append(AttachmentMeta(
                                        path: path,
                                        size: currentSize ?? 0,
                                        modified: currentModified ?? self.createdAt
                                    ))
                                }
                            }
                        } else {
                            // No closing tag — strip from opening tag to end
                            endBound = s.endIndex
                        }
                        displayStr = String(s[s.startIndex..<range.lowerBound] + s[endBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                // Strip model-facing attachment markers from user-visible text.
                // These are generated in AIChatViewModel when building the LLM payload
                // (`[attached image: /var/minis/...]` next to inline image data, and
                // `[image omitted to save context — ...]` when eviction replaces
                // image bytes with a text placeholder). The UI already renders the
                // real attachments via `msg.attachments` parsed from the
                // <user-attached-files> XML above, so leaving these markers in the
                // display string produces the duplicated raw-path text users see
                // after reloading history.
                if role == .user && !displayStr.isEmpty {
                    displayStr = Self.stripSystemReminders(displayStr)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if role == .user && !displayStr.isEmpty {
                    displayStr = Self.stripAttachmentMarkers(displayStr)
                }
                if !displayStr.isEmpty {
                    if !textContent.isEmpty { textContent += "\n" }
                    textContent += displayStr
                }

            case .mediaRef(let ref):
                let fileURL = mediaResolver(ref)
                if role == .user {
                    // Legacy: skip mediaRef for user messages — attachment metadata
                    // comes from <user-attached-files> XML which has the correct paths.
                    // Old sessions stored both YAML/XML + mediaRef (with different filenames), causing duplicates.
                } else {
                    let block = AssistantBlock(kind: .text, content: "")
                    block.imageFilePath = fileURL.path
                    blocks.append(block)
                }

            case .toolUse(let tu):
                let kind: AssistantBlockKind
                let content: String
                switch tu.name {
                case "shell_execute":
                    let cmd = extractCommandFromJSON(tu.input)
                    kind = .shellTool(command: cmd)
                    content = "$ \(cmd)"
                case "file_read":
                    let path = extractStringParam("path", from: tu.input)
                    kind = .fileReadTool(path: path)
                    content = "Reading \(path)..."
                case "file_write":
                    let path = extractStringParam("path", from: tu.input)
                    kind = .fileWriteTool(path: path)
                    content = "Writing \(path)..."
                case "file_edit":
                    let path = extractStringParam("path", from: tu.input)
                    kind = .fileEditTool(path: path)
                    content = "Editing \(path)..."
                case "browser_use":
                    let action = extractStringParam("action", from: tu.input)
                    kind = .browserTool(action: action)
                    content = "Browser: \(action)"
                    // Restore browserURL from args or inherit from preceding browser block
                    let argURL = extractStringParam("url", from: tu.input)
                    if !argURL.isEmpty {
                        lastBrowserURL = argURL
                    }
                case "web_search":
                    kind = .browserTool(action: "web_search")
                    content = "Searching public sources..."
                case "read_image":
                    let path = extractStringParam("path", from: tu.input)
                    kind = .readImageTool(path: path)
                    content = "Reading image \(path)..."
                case "memory_write", "memory_get":
                    kind = .memoryTool(action: tu.name)
                    content = tu.name == "memory_write" ? "Writing memory..." : "Reading memory..."
                default:
                    kind = .shellTool(command: tu.name)
                    content = tu.name
                }
                // Seed as .running so applyToolResults (called when the paired
                // tool_result user message is processed) can recognize this block as
                // "not yet finalized". loadSession finalizes any blocks still left in
                // .running / .streaming after all messages are processed — those are
                // orphaned tool_uses (app killed / run cancelled before the result
                // was persisted) and are marked .cancelled.
                let block = AssistantBlock(kind: kind, content: content, toolStatus: .running, toolUseId: tu.toolUseId)
                block.toolSummary = tu.description
                block.toolInputArgs = tu.input
                // Restore browserURL: use arg URL or inherit from last browser block
                if case .browserTool = kind {
                    block.browserURL = lastBrowserURL
                }
                blocks.append(block)

            case .toolResult(let tr):
                // Match this result to its preceding toolUse block and update it.
                if let blockIdx = blocks.lastIndex(where: { $0.toolUseId == tr.toolUseId }) {
                    blocks[blockIdx].content = tr.output
                    // Prefer the explicit persisted status (distinguishes cancelled from failed);
                    // fall back to the success bool for rows written before the status field existed.
                    switch tr.status {
                    case "cancelled": blocks[blockIdx].toolStatus = .cancelled
                    case "failed":    blocks[blockIdx].toolStatus = .failed(message: "")
                    case "success":   blocks[blockIdx].toolStatus = .success
                    default:          blocks[blockIdx].toolStatus = tr.success ? .success : .failed(message: "")
                    }
                    // Restore screenshot image from persisted mediaRef
                    let ref = tr.mediaRef ?? tr.snapshot?.mediaRef
                    if let ref {
                        blocks[blockIdx].imageFilePath = mediaResolver(ref).path
                    }
                    // Restore browserURL from persisted pageURL
                    if let pageURL = tr.pageURL, !pageURL.isEmpty {
                        blocks[blockIdx].browserURL = pageURL
                        lastBrowserURL = pageURL
                    }
                } else {
                    if !textContent.isEmpty { textContent += "\n" }
                    textContent += tr.output
                }
            }
        }

        // Prepend thinking block if reasoning content was stored and thinking display is enabled
        if showThinking, role == .assistant, let rc = reasoningContent, !rc.isEmpty {
            blocks.insert(AssistantBlock(kind: .thinking, content: rc), at: 0)
        }

        let msg = ChatMessage(role: uiRole, content: textContent, blocks: blocks)
        // Deduplicate attachments by path
        var seenPaths = Set<String>()
        msg.attachments = userAttachments.filter { seenPaths.insert($0.path).inserted }
        if let usage = tokenUsage {
            msg.usage = TokenUsage(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationTokens: usage.cacheCreationTokens,
                cacheReadTokens: usage.cacheReadTokens,
                latestContextTokens: usage.latestContextTokens ?? 0
            )
        }
        msg.streamInterruptCount = streamInterruptCount
        // [T-error-persist-ios] Restore the persisted error indicator so a failed
        // past turn still shows its error after session reload / app restart.
        // Treat empty/whitespace as no-error (UI gates on `error != nil`, so an
        // empty string would show a blank banner).
        if let e = errorInfo, !e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            msg.error = e
        }
        return msg
    }

    /// Strip model-facing attachment markers from user display text.
    /// Removes `[attached <kind>: ...]` (image / file / audio / video / …)
    /// and `[image omitted to save context — ...]` tokens produced by the
    /// send/compaction paths for the LLM; the UI surfaces real attachments
    /// via `msg.attachments` parsed from the <user-attached-files> XML, so
    /// these tokens are pure noise to the user.
    static func stripAttachmentMarkers(_ s: String) -> String {
        let patterns = [
            #"\[attached [A-Za-z]+:[^\]]*\]"#,
            #"\[image omitted to save context[^\]]*\]"#,
        ]
        var out = s
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p) {
                let range = NSRange(out.startIndex..., in: out)
                out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "")
            }
        }
        // Collapse blank lines left behind and trim surrounding whitespace.
        let lines = out.components(separatedBy: "\n")
        var cleaned: [String] = []
        var lastBlank = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let blank = trimmed.isEmpty
            if blank && lastBlank { continue }
            cleaned.append(line)
            lastBlank = blank
        }
        return cleaned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove `<system-reminder>...</system-reminder>` segments from display text
    /// before display. Markers are kept in agentHistory so the model still sees them
    /// on resume/continue, but they should never surface in the chat bubble.
    /// [T-ios-longmsg-cell-split] Split an over-long assistant reply into
    /// paragraph-aligned segments so no single cell has to back an enormous
    /// CALayer. Returns `[text]` unchanged for normal replies.
    ///
    /// Thresholds come from measurement, not taste. The reported collapse
    /// carried 9156 chars in one block and measured 20615.3pt on the reporter's
    /// @3x device (61846px) and 20711.5pt when reproduced on an iPhone 11
    /// (41423px). Splitting at 4000 chars puts that message into ~3 cells of
    /// roughly 5-7K pt each — comfortably under any per-layer limit and, more
    /// importantly, small enough that the list stops being one giant cell
    /// (`visibleCells=1` in the field log) and can recycle normally.
    ///
    /// `splitMarkdownIntoSegments` is reused verbatim from
    /// `PaginatedMarkdownView` (T-markdown-preview-paginate), which solved the
    /// same CALayer problem for document preview in May. It is fence-aware, so
    /// a fenced code block is never cut in half, and each returned segment
    /// parses independently under cmark.
    ///
    /// Known limitation: a single markdown TABLE longer than the threshold
    /// still lands in one segment, because the splitter only breaks at blank
    /// lines outside fences and table rows carry none. Tables therefore stay
    /// exactly as they render today — no better, no worse.
    static func splitLongAssistantText(_ text: String) -> [String] {
        guard text.count > longTextSplitThreshold else { return [text] }
        let segments = splitMarkdownIntoSegments(text, targetSize: longTextSegmentTarget)
        // Defensive: never let splitting lose or empty out content. If the
        // splitter returns nothing usable, keep the original single block —
        // a too-tall cell is far better than a vanished reply.
        let rejoinedCount = segments.reduce(0) { $0 + $1.count }
        guard !segments.isEmpty, rejoinedCount >= text.count / 2 else { return [text] }
        return segments
    }

    /// Replies longer than this are split. Below it, behaviour is byte-identical
    /// to before (one block, one cell).
    private static let longTextSplitThreshold = 4000
    /// Target size per segment; the splitter overshoots to the next paragraph
    /// break, and never cuts inside a fenced code block.
    private static let longTextSegmentTarget = 4000

    static func stripSystemReminders(_ text: String) -> String {
        guard text.contains("<system-reminder>") else { return text }
        let pattern = "<system-reminder>[\\s\\S]*?</system-reminder>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let stripped = regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: ""
        )
        return stripped
    }
}

// MARK: - AgentMessage Conversion

extension RawMessage {
    /// Convert to an AgentMessage for rebuilding agent history on session load.
    func toAgentMessage(mediaResolver: (MediaRef) -> URL) -> AgentMessage {
        let agentRole: AgentMessage.Role = role == .user ? .user : .assistant
        var agentParts: [AgentContentPart] = []

        for part in parts {
            switch part {
            case .text(let s):
                agentParts.append(.text(s))
            case .mediaRef(let ref):
                if let data = try? Data(contentsOf: mediaResolver(ref)) {
                    agentParts.append(.imageData(data: data, mimeType: ref.mimeType, linuxPath: ref.linuxPath))
                }
            case .toolUse(let tu):
                let input = parseJSONToDict(tu.input)
                agentParts.append(.toolUse(id: tu.toolUseId, name: tu.name, input: input))
            case .toolResult(let tr):
                var imgData: Data? = nil
                var imgMime: String? = nil
                if let ref = tr.mediaRef {
                    let fileURL = mediaResolver(ref)
                    if let data = try? Data(contentsOf: fileURL) {
                        imgData = data
                        // Sniff actual image format — stored mimeType may be wrong (e.g. png for jpeg data)
                        imgMime = Self.sniffImageMimeType(data) ?? ref.mimeType
                    }
                }
                agentParts.append(.toolResult(id: tr.toolUseId, name: "", content: tr.output, isError: !tr.success, imageData: imgData, imageMimeType: imgMime, imageLinuxPath: tr.mediaRef?.linuxPath))
            }
        }

        var msg = AgentMessage(role: agentRole, parts: agentParts)
        msg.reasoningContent = reasoningContent
        return msg
    }

    /// Detect actual image format from file magic bytes.
    private static func sniffImageMimeType(_ data: Data) -> String? {
        guard data.count >= 3 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if data.count >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "image/png"
        }
        if data.count >= 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 {
            return "image/gif"
        }
        if data.count >= 4 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            return "image/webp"
        }
        return nil
    }
}

// MARK: - JSON Helpers for UI Conversion

private func extractCommandFromJSON(_ json: String) -> String {
    extractStringParam("command", from: json)
}

private func extractStringParam(_ key: String, from json: String) -> String {
    guard let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = dict[key] as? String else {
        return ""
    }
    return value
}
