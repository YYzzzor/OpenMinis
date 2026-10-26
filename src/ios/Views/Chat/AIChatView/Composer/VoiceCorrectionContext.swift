//
//  VoiceCorrectionContext.swift
//  Minis - 聊天页（AIChatView）
//
//  从消息构造语音纠错用的会话上下文。
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

/// [voice-correction §6] Build the conversation context for a correction: the last user
/// message and the agent reply that followed it.
///
/// Reads the in-memory `messages` the chat is already rendering — §12.1 explicitly forbids
/// a DB query here, since this runs on the correction path. Both halves are truncated by
/// `ConversationContextTruncator` (500-char soft cap, extended to the next sentence
/// terminator so a quoted fragment never ends mid-sentence).
///
/// This is what lets correction work on a FRESH INSTALL. With both learned tables empty and
/// no context, the prompt has no evidence at all and the model correctly refuses to change
/// anything — which is exactly why the suggestion icon never appeared on a new device.
func voiceCorrectionContext(from messages: [ChatMessage]) -> ConversationContext {
    // Budgeted builder (2026-07-16): sentence-split + segment + rarity-rank the
    // recent turns, expanding the message count under a 5k-char budget, instead
    // of the original "last user + reply, first 500 chars each". §12.1 still
    // holds — this reads only the in-memory messages the chat is rendering.
    // Only real conversation turns feed the context. compactDivider and
    // systemInfo rows would otherwise be classified as "assistant" and leak
    // UI copy into the rare-terms digest.
    let source = messages
        .filter { $0.role == .user || $0.role == .assistant }
        .map { msg -> CorrectionSourceMessage in
            // Assistant turns keep their prose in `blocks` (text blocks), not
            // in `content` — reading only `content` silently dropped every AI
            // reply from the correction context. `content` can also hold a
            // stale FRAGMENT alongside full blocks (observed: a 34-char title
            // while the reply lived in blocks), so for assistant turns the
            // text blocks are the source of truth and `content` is only the
            // fallback. Tool/thinking/info blocks stay out — their payloads
            // are commands and traces, not conversational vocabulary.
            var text = msg.content
            if msg.role == .assistant, !msg.blocks.isEmpty {
                let blockText = msg.blocks
                    .filter { $0.kind == .text }
                    .map(\.content)
                    .joined(separator: "\n")
                if !blockText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = blockText
                }
            }
            return CorrectionSourceMessage(role: msg.role == .user ? .user : .assistant,
                                           text: TypedVocabularyBuilder.stripAttachmentMarkup(text))
        }
    return CorrectionContextBuilder.build(messages: source)
}
