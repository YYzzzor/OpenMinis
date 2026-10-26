//
//  ChatStoreModels.swift
//  Minis - 聊天持久化（Agent/Chat）
//
//  ChatStore 的持久化数据模型：ChatSession、ChatFolder、RawMessage、ContentPart、CompactMarker 等。
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

// MARK: - Sync Data Types

struct SyncDevice: Identifiable {
    let id: String       // deviceId
    var deviceName: String
    var zoneName: String
    var lastSeen: Date
    var osVersion: String
    /// Content types this device is uploading (e.g. ["Sessions", "Skills", "Providers"])
    var uploadTypes: [String]
}

struct RemoteMemory: Identifiable {
    let id: String
    let deviceId: String
    var fileName: String
    var content: String
    var updatedAt: Date
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case error(String)
    case disabled
}

// MARK: - Data Model

/// A chat session (conversation thread).
struct ChatSession: Identifiable, Codable, Hashable {
    let id: String
    var title: String?
    var category: String?
    let modelId: String
    let createdAt: Date
    var updatedAt: Date
    var lastMessage: String?
    var source: String?       // e.g. "shortcut" for Shortcuts-triggered sessions
    var lastSyncedAt: Date?   // non-nil if successfully synced to iCloud
    var remoteDeviceId: String?   // non-nil if this session came from another device via iCloud
    var remoteDeviceName: String? // human-readable name of the remote device
    var pinnedAt: Date?       // non-nil if session is pinned; timestamp of when it was pinned
    var folderId: String?     // non-nil if filed into a folder; NULL = ungrouped

    /// Whether this session is from a remote device (read-only).
    var isRemote: Bool { remoteDeviceId != nil }

    /// Whether this session is pinned to the top of the list.
    var isPinned: Bool { pinnedAt != nil }

    /// Whether this session belongs to a folder.
    var isFiled: Bool { folderId != nil }

    // MARK: - Equatable / Hashable (cheap, content-via-proxy)
    //
    // [T-ios-session-list-equatable-jank] The compiler-synthesized
    // `==`/`hash` compared EVERY stored field — including the long
    // `lastMessage` / `title` strings. SwiftUI's sidebar `ForEach(groupedSessions)`
    // makes AttributeGraph deep-compare the whole `[ChatSession]` array on every
    // transaction flush (session switch, tap, foreground, iCloud inbound). In
    // DEBUG that synthesized `String.==` runs the Unicode NFC normalization
    // slow path (no inlining / ARC elision), and across a long session list it
    // pinned the main thread for 1–2s+ (HangDetector: ChatSession
    // __derived_struct_equals → _stringCompareSlow → _NFCNormalizer). Release
    // optimizes it away, which is why Release didn't stall.
    //
    // Replace with an explicit cheap comparison: identity + the short
    // change-driving fields, using `updatedAt` as the proxy for the heavy
    // `lastMessage` (and any other body content) — every content mutation bumps
    // `updatedAt`, so we never need to NFC-compare the long string to detect a
    // change. `title`/`category`/`source` ARE compared (they can change without
    // a content write, e.g. rename / categorize) but they're short. Net: the
    // sidebar diff no longer touches the long strings.
    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
        lhs.id == rhs.id
            && lhs.updatedAt == rhs.updatedAt
            && lhs.pinnedAt == rhs.pinnedAt
            // `folderId` MUST be compared: moving a session between folders
            // changes neither `updatedAt` nor any other compared field, so
            // without this the sidebar would keep rendering the row in its old
            // section until some unrelated mutation bumped the diff.
            && lhs.folderId == rhs.folderId
            && lhs.title == rhs.title
            && lhs.category == rhs.category
            && lhs.source == rhs.source
            && lhs.lastSyncedAt == rhs.lastSyncedAt
            && lhs.remoteDeviceId == rhs.remoteDeviceId
            && lhs.remoteDeviceName == rhs.remoteDeviceName
        // Intentionally NOT comparing `lastMessage` (long string; `updatedAt`
        // is its change proxy) or the immutable `modelId` / `createdAt`.
    }

    func hash(into hasher: inout Hasher) {
        // Mirror ==: cheap, identity + updatedAt. Avoids hashing long strings.
        hasher.combine(id)
        hasher.combine(updatedAt)
    }
}

/// A user-created folder that groups sessions on the home list.
///
/// Named "Folder" rather than "Group" on purpose: the codebase already has
/// three other "group"s — `ModelGroup` (the LLM provider fallback group behind
/// the home FAB's "New Chat with Group"), the `__grp__` draft-session id
/// encoding (which embeds a ModelGroup id), and SwiftUI's `Group {}`.
///
/// Identity is a locally generated UUID, and `name` deliberately carries no
/// uniqueness constraint:
///
/// - **Why not key on the name.** Renaming would stop being a single-field
///   edit and become an identity change (delete old key, create new key,
///   migrate every member). That multi-row operation tears across devices: if
///   device A renames while device B files sessions under the old name, B's
///   sessions end up referencing a key that no longer exists and silently fall
///   back to ungrouped. With a UUID, a rename is one LWW field on `FolderV2`
///   and members are untouched.
/// - **Why duplicate names are allowed.** Two devices each creating "Work"
///   offline produce two distinct UUIDs, and both are kept. Auto-merging is
///   irreversible and two same-named folders are not necessarily the same
///   thing; the user can always move sessions across and dissolve the leftover.
///   Consequence: any *name-based* lookup must tolerate multiple matches (see
///   `findFolderByName`).
struct ChatFolder: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var icon: String?         // SF Symbol name; nil = use the composed icon
    var color: String?        // theme color token
    var origin: String        // "manual" | "ai" — provenance only, no behavior
    var sortIndex: Int        // reserved for V2 drag-reorder
    var pinnedAt: Date?       // non-nil = folder pinned above unpinned folders
    /// One-sentence description (≤100 chars). Auto-grouping context; never
    /// rendered in the home list, but shown as the Move-to-Group picker row
    /// subtitle and surfaced for editing in the rename dialog.
    var desc: String?
    let createdAt: Date
    var updatedAt: Date

    var isPinned: Bool { pinnedAt != nil }

    init(
        id: String = UUID().uuidString,
        name: String,
        icon: String? = nil,
        color: String? = nil,
        origin: String = "manual",
        sortIndex: Int = 0,
        pinnedAt: Date? = nil,
        desc: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.origin = origin
        self.sortIndex = sortIndex
        self.pinnedAt = pinnedAt
        self.desc = desc
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Role for a raw message turn.
enum MessageRole: String, Codable {
    case user
    case assistant
}

/// Reference to a media file stored in Library/MinisChat/minis/<sessionId>/
struct MediaRef: Codable, Hashable {
    let id: String
    let relativePath: String
    let mimeType: String
    let originalFileName: String?
    /// iSH-visible linux path the file is mirrored to (e.g.
    /// `/var/minis/attachments/uploads/<name>`, `/var/minis/browser/<sid>/...`).
    /// Optional — older persisted rows decode with `nil` and fall back to
    /// spillover at request-budget elide time. New writes always populate
    /// this when the file is offloaded to iSH-visible storage.
    let linuxPath: String?

    init(id: String, relativePath: String, mimeType: String, originalFileName: String?, linuxPath: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.originalFileName = originalFileName
        self.linuxPath = linuxPath
    }
}

/// A tool call requested by the assistant.
struct ToolUse: Codable, Hashable {
    let toolUseId: String
    let name: String
    let input: String
    let description: String?
    let thoughtSignature: String?  // Gemini 3.x thought signature
}

/// A snapshot captured from a tool execution result.
struct ToolSnapshot: Codable, Hashable {
    enum SnapshotType: String, Codable, Hashable {
        case text
        case image
    }
    let type: SnapshotType
    let text: String?        // For .text snapshots (last N lines of output)
    let mediaRef: MediaRef?  // For .image snapshots (browser screenshot)
    let duration: TimeInterval?  // Execution duration in seconds
}

/// Result of executing a tool.
struct ToolResult: Codable, Hashable {
    let toolUseId: String
    let output: String
    let success: Bool
    let mediaRef: MediaRef?
    let snapshot: ToolSnapshot?
    /// Final page URL after browser tool execution (for display in tool detail sheet).
    /// Truncated to ≤512 characters if the original was longer.
    let pageURL: String?
    /// Terminal execution status: "success" | "failed" | "cancelled".
    /// Optional for backward compatibility with rows written before this field existed;
    /// when nil, callers fall back to `success` (which cannot distinguish failed from cancelled).
    let status: String?

    /// Truncate a URL to at most `maxLength` characters by eliding the middle.
    /// Returns the original if it's already short enough.
    static func truncateURL(_ url: String, maxLength: Int = 512) -> String {
        guard url.count > maxLength else { return url }
        let marker = "…[truncated]…"
        let keep = (maxLength - marker.count) / 2
        let head = String(url.prefix(keep))
        let tail = String(url.suffix(keep))
        return head + marker + tail
    }
}

/// A single content part within a message — the atomic unit.
enum ContentPart: Codable, Hashable {
    case text(String)
    case mediaRef(MediaRef)
    case toolUse(ToolUse)
    case toolResult(ToolResult)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum PartType: String, Codable {
        case text
        case mediaRef
        case toolUse
        case toolResult
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try container.encode(PartType.text, forKey: .type)
            try container.encode(s, forKey: .value)
        case .mediaRef(let ref):
            try container.encode(PartType.mediaRef, forKey: .type)
            try container.encode(ref, forKey: .value)
        case .toolUse(let tu):
            try container.encode(PartType.toolUse, forKey: .type)
            try container.encode(tu, forKey: .value)
        case .toolResult(let tr):
            try container.encode(PartType.toolResult, forKey: .type)
            try container.encode(tr, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let partType = try container.decode(PartType.self, forKey: .type)
        switch partType {
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        case .mediaRef:
            self = .mediaRef(try container.decode(MediaRef.self, forKey: .value))
        case .toolUse:
            self = .toolUse(try container.decode(ToolUse.self, forKey: .value))
        case .toolResult:
            self = .toolResult(try container.decode(ToolResult.self, forKey: .value))
        }
    }
}

/// A compact boundary marker in a session's message history.
/// Represents the point where older messages were summarized to save context.
///
/// Identity model (post Phase A):
///   - `firstKeptMessageId` is the authoritative active-region start.
///   - `lastCompactedMessageId` is the last message in the compacted range.
///   - Sort-order fields (`firstKeptSortOrder`, `uiBoundarySortOrder`) and
///     `boundaryMessageId` are retained for legacy markers and cross-device
///     sync compatibility with older builds, used only as fallbacks.
struct CompactMarker: Identifiable, Codable {
    let id: String
    let sessionId: String
    /// LLM-generated summary of the compacted messages.
    let summary: String
    /// LEGACY: sort_order of the first message AFTER the compacted range.
    /// Only used as fallback when firstKeptMessageId resolution fails.
    let firstKeptSortOrder: Int
    /// Number of raw messages that were compacted. UI display only.
    let compactedCount: Int
    let createdAt: Date
    /// LEGACY: sort_order of the UI boundary message.
    /// Only used as fallback for divider positioning on legacy markers.
    let uiBoundarySortOrder: Int?
    /// LEGACY: DB message ID of the boundary message (pre-Phase A name for firstKeptMessageId).
    /// Kept for cross-device sync compatibility with older builds.
    let boundaryMessageId: String?
    /// PRIMARY: DB message ID of the first kept (active-region) message.
    /// All restore / compact logic resolves boundaries through this id.
    /// Optional only for legacy markers written before Phase A.
    let firstKeptMessageId: String?
    /// PRIMARY: DB message ID of the last compacted message (right edge of the
    /// compacted range). Used by prune protection to avoid deleting marker anchors.
    /// Optional only for legacy markers written before Phase A.
    let lastCompactedMessageId: String?
    /// Marker schema version. 1 = legacy multi-field model (firstKept/boundary/
    /// sortOrder fallback chain). 2 = simplified id-only model: only
    /// `lastCompactedMessageId` is authoritative; everything before it (incl.)
    /// is the compacted range, everything after it is "live anchor + new msgs".
    /// `compactedCount` and `summary` are still meaningful for UI; all other
    /// columns are ignored for v2 markers.
    var version: Int = 1
}

/// Token usage stats stored with a message.
struct StoredTokenUsage: Codable, Hashable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var latestContextTokens: Int?
}

/// A single message in the conversation (one "turn").
struct RawMessage: Identifiable, Codable, Hashable {
    let id: String
    let sessionId: String
    let role: MessageRole
    let parts: [ContentPart]
    let createdAt: Date
    var tokenUsage: StoredTokenUsage?
    /// Reasoning content from thinking models (Kimi, DeepSeek, QwQ, etc.) — must be echoed back.
    var reasoningContent: String?
    /// Number of mid-stream auto-retries that occurred before this message completed successfully.
    /// 0 means no interruption. Persisted to DB for display after session reload.
    var streamInterruptCount: Int = 0
    /// Database sort_order value. Populated during loadMessages, used for compact boundary tracking.
    var sortOrder: Int = 0
    /// [T-error-persist-ios] Device-local error string for a failed assistant
    /// turn. Mirrors ChatMessage.error; persisted to the messages.error_info
    /// column so the error indicator survives reload. nil = no error.
    var errorInfo: String? = nil

    /// [T-token-attribution-snapshot] The model that ACTUALLY produced this
    /// message, snapshotted when it was written.
    ///
    /// Snapshot rather than a reference to resolve later: usage is a record of
    /// what happened, and it must not change when the configuration it once
    /// pointed at changes. `modelDisplayName` / `providerType` travel with the
    /// id so a deleted provider does not make history unreadable.
    ///
    /// nil on rows written before these columns existed — the signal the Usage
    /// page uses to mark a row estimated rather than measured.
    var modelId: String? = nil
    var modelDisplayName: String? = nil
    /// `ProviderType` **rawValue** (e.g. `openAI`), never a display name.
    var providerType: String? = nil
    /// Diagnostics / disambiguation only; the UI never resolves through it.
    var providerInstanceId: String? = nil

    /// True if this message contains only tool results (no user text).
    /// These are internal agent loop messages that shouldn't render as user bubbles.
    var isToolResultOnly: Bool {
        role == .user && !parts.isEmpty && parts.allSatisfy {
            if case .toolResult = $0 { return true }
            return false
        }
    }

    /// [T-bridge-message-ui-leak] The internal assistant "bridge" row inserted
    /// when a queued user message interrupts a tool loop (#579): it exists
    /// purely to keep agentHistory role-alternation intact
    /// (…user(tool_result) → assistant(bridge) → user(queued)…) and must
    /// never render in the chat UI. Detected by content match rather than a
    /// schema flag: we generate this text verbatim, a content match also hides
    /// rows persisted by OLDER builds (a new column could not), and no
    /// DB/iCloud-sync wiring is needed.
    static let internalBridgeText =
        "(Interrupted mid-task by a new user message. Decide based on the new message and overall context whether the prior task should continue — do not forget or abandon it unless the user explicitly says to stop, or the new message makes clear it is no longer needed.)"

    /// Every bridge text this app has ever generated. A row persisted by an
    /// OLDER build carries the PREVIOUS wording; matching the current constant
    /// alone would fail and leak that row into the UI (the exact regression seen
    /// after the 2026-07-23 wording change, d2e111e9). Match against the full
    /// set so old and new persisted bridges are both recognized. Prefix-match
    /// (not equality) tolerates trailing-whitespace / normalization drift from
    /// DB round-trips.
    static let internalBridgeTexts: [String] = [
        internalBridgeText,
        // Pre-d2e111e9 wording.
        "(Interrupted mid-task to handle your new message. Will return to the prior task after.)",
    ]

    /// True when `text` is any known internal-bridge string. Shared by
    /// RawMessage and ChatMessage so every layer recognizes the same rows.
    static func isInternalBridgeText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return internalBridgeTexts.contains { trimmed == $0 }
    }

    var isInternalBridge: Bool {
        guard role == .assistant, parts.count == 1,
              case .text(let s) = parts[0] else { return false }
        return Self.isInternalBridgeText(s)
    }
}
