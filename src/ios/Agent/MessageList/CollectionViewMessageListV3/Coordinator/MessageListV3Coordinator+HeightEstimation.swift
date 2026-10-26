//
//  MessageListV3Coordinator+HeightEstimation.swift
//  Minis - V3 聊天消息列表（Agent/MessageList/CollectionViewMessageListV3）
//
//  缓存键，以及未测量项的高度估算。
//
//  文件地图与拆分规则：CollectionViewMessageListV3.swift（本目录）。
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Height Estimation

        /// [T-ios-scroll-decel-height-drift] The owning message id for a list
        /// item (used to detect the actively streaming message so its cells are
        /// excluded from the height memo).
        static func messageId(of item: MessageListItem) -> UUID? {
            switch item {
            case .wholeMessage(let id): return id
            case .assistantHeader(let id): return id
            case .assistantFooter(let id): return id
            case .assistantBlock(let mid, _): return mid
            }
        }

        /// [T-ios-earlier-stream-seed-freeze] Ids of every assistant message
        /// whose content can still GROW right now — not just the newest one.
        ///
        /// This is the same rule the layout's `streamingCellRanges` uses
        /// (612dddf7, "[T-stream-hover-earlier-streaming]"): with queued-turn
        /// interrupts, an EARLIER assistant message can still be receiving
        /// content through a running/streaming tool block while a newer turn
        /// streams text. Extracted into one helper because the two places that
        /// need it had drifted apart — the seed/memo exclusion in
        /// `configureCell` still tested only `messages.last`, so a growing
        /// earlier message was treated as settled history and got frozen at a
        /// stale height (see the call site for the resulting overlap).
        static func liveAssistantMessageIds(messages: [ChatMessage], isProcessing: Bool) -> Set<UUID> {
            guard isProcessing else { return [] }
            var ids: Set<UUID> = []
            if let last = messages.last, last.role == .assistant {
                ids.insert(last.id)
            }
            for msg in messages where msg.role == .assistant && msg.id != messages.last?.id {
                let hasLiveTool = msg.blocks.contains { blk in
                    switch blk.toolStatus {
                    case .running, .streaming: return true
                    default: return false
                    }
                }
                if hasLiveTool { ids.insert(msg.id) }
            }
            return ids
        }

        /// [T-ios-scroll-decel-height-drift] Stable per-content key for the
        /// measured-height memo, keyed by item identity AND a cheap content
        /// fingerprint (content length / attachment count). The fingerprint makes
        /// the key CHANGE when the content changes height without changing
        /// identity — streaming append, async image/attachment load, tool output
        /// growth — so a stale (shorter, mid-stream) height can't be seeded onto
        /// a now-taller cell. Combined with the width-gated lookup (rotation) and
        /// clearHeightCache (session switch / font-size change), this closes the
        /// memo's staleness paths. Font size is NOT in the key because a font
        /// change routes through clearHeightCache (wipes the whole memo).
        #if DEBUG
        /// [T-ios-scroll-metrics-ring] Stable content-hash identity for a cell.
        /// Unlike contentKey (built on runtime UUIDs, regenerated when history
        /// paging reloads message objects), this survives object regeneration:
        /// same rendered content → same tag. Used ONLY by the scroll-metrics
        /// ring so one cell's height trajectory can be followed across
        /// seed/measure/inv/flush events and across reload generations.
        static func stableCellTag(for item: MessageListItem, messages: [ChatMessage], messageIndex: [UUID: Int]) -> String {
            func digest(_ s: String) -> String {
                var h: UInt32 = 5381
                for b in s.prefix(96).utf8 { h = (h &* 33) &+ UInt32(b) }
                return String(h, radix: 36)
            }
            func msg(_ id: UUID) -> ChatMessage? {
                guard let i = messageIndex[id], i < messages.count else { return nil }
                return messages[i]
            }
            switch item {
            case .wholeMessage(let id):
                let c = msg(id)?.content ?? ""
                return "w#\(digest(c))#\(c.count)"
            case .assistantHeader(let id):
                let c = msg(id)?.blocks.first?.content ?? ""
                return "h#\(digest(c))"
            case .assistantFooter(let id):
                let c = msg(id)?.blocks.first?.content ?? ""
                return "f#\(digest(c))"
            case .assistantBlock(let mid, let bid):
                guard let b = msg(mid)?.blocks.first(where: { $0.id == bid }) else { return "b#?" }
                let c = b.content
                return "b#\(digest(c))#\(c.count)#\(b.kind)"
            }
        }
        #endif

        static func contentKey(for item: MessageListItem, messages: [ChatMessage], messageIndex: [UUID: Int]) -> String {
            func msg(_ id: UUID) -> ChatMessage? {
                guard let i = messageIndex[id], i < messages.count else { return nil }
                return messages[i]
            }
            switch item {
            case .wholeMessage(let id):
                let n = msg(id)?.content.count ?? 0
                let a = msg(id)?.attachments.count ?? 0
                return "w:\(id.uuidString):\(n):\(a)"
            case .assistantHeader(let id):
                return "h:\(id.uuidString)"
            case .assistantFooter(let id):
                return "f:\(id.uuidString)"
            case .assistantBlock(let mid, let bid):
                let block = msg(mid)?.blocks.first(where: { $0.id == bid })
                let n = block?.content.count ?? 0
                return "b:\(mid.uuidString):\(bid.uuidString):\(n)"
            }
        }

        static func estimateItemHeight(_ item: MessageListItem, messages: [ChatMessage], width: CGFloat) -> CGFloat {
            let scale = FontSettings.shared.scaledMessage(16)
            let lineHeight = scale * 1.4
            // [T-ios-user-attach-estimate-mismatch] The former `hPad` local died
            // with the `.user` branch's coarse tile arithmetic — the attachment
            // block now comes from UserAttachmentTileMetrics, which derives its
            // own available width. `estimateTextBlockHeight` keeps its own copy.

            switch item {
            case .wholeMessage(let msgId):
                guard let msg = messages.first(where: { $0.id == msgId }) else { return 44 }
                switch msg.role {
                case .compactDivider: return 44
                case .systemInfo: return 36
                case .user:
                    // [T-ios-user-msg-estimate-tail-jitter] Use the SAME accurate
                    // UILabel-based measurement as the precalc path, NOT the coarse
                    // char-count heuristic. The heuristic (cpl = tw/(scale*0.55))
                    // under-counts lines — a 3-line message estimated as 2 lines —
                    // so when this estimate is the height used during a fast scroll
                    // / offscreen pass (before precalc lands, or via the
                    // configureCell/prefetch estimate fallback), the
                    // UIHostingConfiguration lays the Text into a 2-line box and
                    // SwiftUI truncates it to "2 lines + …"; at settle the real
                    // measure returns 3 lines and the cell visibly expands, jolting
                    // the whole page. Routing the estimate through the accurate
                    // measurement makes the offscreen height already 3 lines, so the
                    // Text never truncates and there is nothing to expand.
                    var throwaway: [String: CGFloat] = [:]
                    if let h = Self.measureUserBubbleHeight(for: msg, cvWidth: width, cache: &throwaway) {
                        return h
                    }
                    // Fallback (empty/attachment-only): coarse heuristic.
                    //
                    // [T-ios-user-attach-estimate-mismatch] Two fixes here:
                    //  1. Same 70-vs-64 correction as measureUserBubbleHeight —
                    //     use the shared tile metrics rather than a local guess.
                    //  2. Count `inputAttachments` when `attachments` is empty,
                    //     matching measureUserBubbleHeight. A queued image-only
                    //     message (attachments not yet populated) previously
                    //     estimated 0 + 44 = 44pt against a real ~70pt — a 26pt
                    //     UNDER-estimate, the harmful direction and by far the
                    //     largest of the three errors in this path.
                    let attachCount = msg.attachments.isEmpty
                        ? msg.inputAttachments.count : msg.attachments.count
                    let imgH = UserAttachmentTileMetrics.blockHeight(
                        count: attachCount,
                        availableWidth: width - 32 /*cell*/ - 60 /*Spacer*/
                    )
                    return imgH + 44
                case .assistant: return 200
                }
            case .assistantHeader:
                return 28
            case .assistantBlock(let msgId, let blockId):
                guard let msg = messages.first(where: { $0.id == msgId }),
                      let block = msg.blocks.first(where: { $0.id == blockId }) else { return 44 }
                switch block.kind {
                case .text:
                    if let attrStr = block.cachedAttributedString {
                        let textWidth = max(width - 32, 100)
                        // [T-ios-longreply-boundingRect-watchdog] CTFramesetter instead
                        // of NSAttributedString.boundingRect. estimateItemHeight runs
                        // in prefetch/scroll-back for every not-yet-measured cell;
                        // boundingRect's TextKit1 layout is near-O(n²) in line count
                        // and could burn hundreds of ms per cell (watchdog risk on
                        // long history). CTFramesetter is 70–700× faster with the same
                        // height (±1pt). This is only a layout ESTIMATE, and the .text
                        // block's cachedAttributedString is attachment-free markdown
                        // text (attachments render as separate blocks), so it's safe.
                        let textH = SelectableMarkdownView.ctFramesetterHeight(for: attrStr, width: textWidth)
                        // +12 = text view insets (8) + SwiftUI wrapper vertical
                        // padding (4). This CT path is the coarse prefetch
                        // fallback; the seed loop's precalc uses the exact
                        // render-engine measure (measureAttributedStringHeight).
                        return textH + 12
                    }
                    return Self.estimateTextBlockHeight(block.content, width: width, scale: scale, lineHeight: lineHeight)
                case .thinking:
                    // Header (icon 14pt or label 13pt) + vPad 10·2 + capsule border ≈ 36pt,
                    // + 4pt block-wrapper vertical padding = 40 (same calibration as tool
                    // capsules, [T-ios-decel-inv-estimate-calibration]).
                    // When expanded, content area adds up to 300pt of inner text + 10pt bottom pad.
                    let headerH: CGFloat = 40
                    guard block.isThinkingExpanded, !block.content.isEmpty else {
                        return headerH
                    }
                    let innerWidth = max(width - 24, 100)         // 12pt horizontal pad each side
                    let innerLineHeight: CGFloat = 13 * 1.4 + 3   // .lineSpacing(3) on 13pt font
                    let lines = block.content.split(separator: "\n", omittingEmptySubsequences: false)
                    var textH: CGFloat = 0
                    let cpl = max(1, innerWidth / 7)              // ~7pt per CJK/wide glyph at 13pt
                    for line in lines {
                        let wrapped = max(1, ceil(CGFloat(line.count) / cpl))
                        textH += wrapped * innerLineHeight
                    }
                    let contentH = min(textH + 10, 300)            // ScrollView capped at 300pt
                    let total = headerH + contentH
                    return total
                // [T-ios-decel-inv-estimate-calibration] Tool capsules measure exactly
                // 36pt: ToolCapsuleView has NO vertical padding (unlike .text/.thinking,
                // which add .padding(.vertical, 2) → +4). The debug.scrollMetrics ring
                // proved the split: with 40 here, every real tool capsule corrected
                // 40→36 (-4) mid-decel; the +4 growths that motivated 40 were actually
                // collapsed THINKING blocks (handled above with headerH = 40).
                case .readImageTool: return 36
                case .info:
                    let lineCount = max(1, block.content.components(separatedBy: "\n").count)
                    return CGFloat(20 + lineCount * 16)
                default: return 36  // Tool capsules (execute, browser, etc.): no wrapper pad
                }
            case .assistantFooter:
                return 4
            }
        }

        static func estimateTextBlockHeight(_ content: String, width: CGFloat, scale: CGFloat, lineHeight: CGFloat) -> CGFloat {
            // [T-ios-empty-textblock-gap] An empty text block renders nothing
            // (EmptyView) — the one-line floor below is only for non-empty
            // streaming placeholders whose first delta is about to land.
            guard !content.isEmpty else { return 0 }
            let hPad: CGFloat = 80
            let tw = max(width - hPad, 100)
            let cpl = tw / (scale * 0.5)
            var total: CGFloat = 4

            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var i = 0
            while i < lines.count {
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Fenced code block
                if trimmed.hasPrefix("```") {
                    var codeLines = 0
                    i += 1
                    while i < lines.count {
                        let cl = lines[i].trimmingCharacters(in: .whitespaces)
                        if cl.hasPrefix("```") { i += 1; break }
                        codeLines += 1
                        i += 1
                    }
                    total += 32 + CGFloat(max(codeLines, 1)) * 18 + 24
                    continue
                }

                // Table
                if trimmed.hasPrefix("|") && trimmed.contains("|") {
                    var tableRows = 0
                    while i < lines.count {
                        let tl = lines[i].trimmingCharacters(in: .whitespaces)
                        if tl.hasPrefix("|") && tl.contains("|") {
                            if !tl.contains("---") { tableRows += 1 }
                            i += 1
                        } else {
                            break
                        }
                    }
                    total += CGFloat(max(tableRows, 1)) * 36 + 16
                    continue
                }

                // Horizontal rule
                if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                    total += 16
                    i += 1
                    continue
                }

                // Image
                if trimmed.hasPrefix("![") && trimmed.contains("](") {
                    total += Self.estimateMarkdownImageHeight(line: trimmed, containerWidth: tw)
                    i += 1
                    continue
                }

                // Math block
                if trimmed == "$$" {
                    i += 1
                    while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "$$" {
                        i += 1
                    }
                    i += 1
                    total += 80
                    continue
                }

                // Regular text
                if trimmed.isEmpty {
                    total += lineHeight * 0.5
                } else {
                    let charCount = CGFloat(trimmed.count)
                    let wrappedLines = max(1, ceil(charCount / cpl))
                    total += wrappedLines * lineHeight
                }
                i += 1
            }

            // [T-ios-stream-bubble-spacing] +4 to match the measured-path baseline
            // (cachedAttributedString branch returns usedRect + 8; this heuristic
            // seeds total = 4, so it ran 4pt short). Centralizing the compensation
            // HERE — rather than at one applySnapshot call site — means EVERY
            // consumer (applySnapshot precalc, configureCell's estimate, and the
            // prefetch estimate) gets the padded height. The earlier per-call-site
            // +4 didn't stick because configureCell re-set the estimate from this
            // function WITHOUT the +4, overwriting it; a streaming cell then laid
            // out ~4pt short and SwiftUI clipped the bubble's .padding(.vertical, 2),
            // so the text looked glued to the bubble edges until a real measure ran.
            return max(total, lineHeight + 4) + 4
        }

        /// Estimate height for a Markdown image line by checking the image cache.
        /// Falls back to 200pt placeholder if the image hasn't been loaded yet.
        private static func estimateMarkdownImageHeight(line: String, containerWidth: CGFloat) -> CGFloat {
            let maxImageWidth: CGFloat = 400
            // Extract URL from ![alt](url)
            guard let openParen = line.range(of: "]("),
                  let closeParen = line.range(of: ")", range: openParen.upperBound..<line.endIndex) else {
                return 200
            }
            let src = String(line[openParen.upperBound..<closeParen.lowerBound])
            if let cached = NativeMediaImageCache.shared.image(for: src) {
                let imgWidth = min(min(containerWidth, cached.size.width), maxImageWidth)
                let aspect = cached.size.height / max(cached.size.width, 1)
                let maxH = UIScreen.main.bounds.height / 2
                return min(imgWidth * aspect, maxH) + 6
            }
            return 200
        }
}
