//
//  ChatStore+SessionList.swift
//  Minis - 聊天持久化（Agent/Chat）
//
//  listSessions、安全的列读取、预览文本提取。
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let iCloudLogger = AppLogger(category: "iCloud")

extension ChatStore {

    // MARK: - Safe column readers

    // [T-ios-listsessions-cstring-trap] `String(cString:)` traps the process on a
    // NULL pointer, and `sqlite3_column_text` legitimately returns NULL for a
    // SQL NULL. The `sessions` schema declares `id TEXT PRIMARY KEY` — and in
    // SQLite a non-INTEGER PRIMARY KEY does NOT imply NOT NULL (a long-standing
    // documented quirk), so a single row with a NULL id is enough to abort the
    // app. That is the 09:13:09 / 09:14:15 crash loop: `refreshSessionList` ran
    // on every launch, hit the same dirty row, and SIGABRT'd before the UI came
    // up, so the user could never reach a screen to fix it.
    //
    // `String(decoding:as:)` is used rather than `String(cString:)` because it
    // also cannot trap on malformed UTF-8 — it substitutes U+FFFD. A corrupted
    // byte sequence in a TEXT column therefore degrades to a visibly-mangled
    // title instead of taking the process down.

    /// Non-optional TEXT column → String. NULL / invalid UTF-8 degrade to a
    /// (possibly empty) String instead of trapping.
    static func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, col) else { return "" }
        let len = Int(sqlite3_column_bytes(stmt, col))
        guard len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    /// Nullable TEXT column → String?. Distinguishes SQL NULL (nil) from an
    /// empty string, matching the previous `.map { String(cString: $0) }` shape.
    static func colTextOpt(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, col) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, col))
        guard len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    func listSessions() -> [ChatSession] {
        // ─── crash triage (sqlite3MutexMisuseAssert in column_text) ───
        // Capture the calling context whenever this enters so we can match
        // mid-flight invocations (App Intents EntityQuery, iCloud sync,
        // SwiftUI body) against the actor's serial expectation. A
        // mutex-misuse trap in sqlite3_column_text usually means the stmt
        // is being stepped on a different thread than it was prepared on,
        // OR the db handle is being touched while another op is mid-step.
        // Both should be impossible inside a single actor method, so any
        // weirdness in this log narrows down the breach.
        #if DEBUG
        let qLabel = String(cString: __dispatch_queue_get_label(nil))
        let tDesc = Thread.current.description
        let isMain = Thread.isMainThread
        iCloudLogger.info("[ChatStore.listSessions] ENTER queue='\(qLabel)' isMain=\(isMain) thread=\(tDesc.prefix(80))")
        defer {
            iCloudLogger.info("[ChatStore.listSessions] EXIT queue='\(qLabel)'")
        }
        #endif
        // [T-ios-listsessions-cache] Return the cached list verbatim when no
        // list-affecting mutation has fired since it was built — same array,
        // same preview Strings, zero new allocations. This is the fix for the
        // hundreds-of-MB StringStorage growth from redundant listSessions()
        // calls (proven via malloc_history).
        if !sessionListCacheDirty, let cached = sessionListCache {
            return cached
        }
        // Session-list preview policy:
        //   1. Latest assistant text part that came AFTER the latest user
        //      text message. This way an in-flight user prompt (or the
        //      streaming phase, where no assistant text has landed yet)
        //      shows the user's own prompt instead of the previous turn's
        //      assistant reply; once the current turn's assistant text
        //      falls out of streaming and hits the DB it takes over.
        //      Mid-turn text responses in multi-tool agent loops also land
        //      here, so the row updates per turn.
        //   2. Falls back to the latest user text message.
        //
        // tool_result rows share role='user' but their parts_json has no
        // `.text` part, so the LIKE filter excludes them from the user-text
        // subquery — the cutoff "later than latest user text" therefore
        // correctly ignores tool_result sort_order values.
        //
        // LIKE pattern note: we match only `"type":"text"` and NOT
        // `"type":"text","value":"…"`. Swift's JSONEncoder serializes
        // KeyedEncodingContainer entries in an unspecified (effectively
        // hash-bucket) order, so the actual JSON often comes out as
        // `{"value":"…","type":"text"}` — the keys are NOT guaranteed to be
        // in declaration order. A `"type":"text","value":"%` pattern would
        // silently miss most rows (which is how this regressed: only some
        // legacy rows happened to have type-first ordering and showed a
        // preview, while newer rows fell back to "No messages yet").
        // Assistant-side preview row: prefer the most recent assistant message
        // that has SOMETHING displayable — either a text part OR a tool_use part.
        // Without the `toolUse` clause, sessions whose last assistant turn is
        // mid-tool-call (no text yet) fall through to the user-text fallback,
        // which makes the row look stale; for brand-new sessions where the user
        // never typed text (e.g. forked / cloud-imported) it shows "No messages
        // yet" even while a tool is actively running. The extractor below knows
        // how to summarize a tool_use when no text part exists.
        // [T-ios-listsessions-part-flags] The filter is now the integer
        // `part_flags` bitmask instead of `parts_json LIKE '%…%'` scans:
        //     assistant preview row = latest with (text OR toolUse) → flags & 3
        //     user preview row      = latest with text              → flags & 1
        // This exactly reproduces the old LIKE conditions (backfilled +
        // maintained on every write), and crucially still excludes
        // tool_result-only user rows (they carry neither bit) — the invariant
        // the "later than latest user text" cutoff relied on.
        //
        // The 4-correlated-subquery SHAPE is kept deliberately: measured on the
        // real 100k-message / 1772-session DB, swapping LIKE→mask took it from
        // ~523ms to ~30-58ms (9×), each subquery a fast indexed
        // `SEARCH … USING idx_msg_sess_role_sort (session_id=? AND role=?)`.
        // A window-function CTE (方案1) was tried and REJECTED: it materializes
        // every assistant/user row across the whole table (MATERIALIZE asst),
        // clocking ~1100ms — 20× slower than the indexed subqueries here.
        let asstMask = Self.partFlagHasText | Self.partFlagHasToolUse   // 3
        let userMask = Self.partFlagHasText                            // 1
        let sql = """
            SELECT s.id, s.title, s.model_id, s.created_at, s.updated_at, s.category,
                   (SELECT m.parts_json FROM messages m
                     WHERE m.session_id = s.id
                       AND m.role = 'assistant'
                       AND (m.part_flags & \(asstMask)) != 0
                     ORDER BY m.sort_order DESC LIMIT 1),
                   (SELECT m.parts_json FROM messages m
                     WHERE m.session_id = s.id
                       AND m.role = 'user'
                       AND (m.part_flags & \(userMask)) != 0
                     ORDER BY m.sort_order DESC LIMIT 1),
                   s.source, s.last_synced_at,
                   s.remote_origin_device_id, s.pinned_at,
                   -- sort_order of the picked assistant/user rows, so the Swift
                   -- layer can prefer whichever is genuinely newer.
                   (SELECT m.sort_order FROM messages m
                     WHERE m.session_id = s.id
                       AND m.role = 'assistant'
                       AND (m.part_flags & \(asstMask)) != 0
                     ORDER BY m.sort_order DESC LIMIT 1),
                   (SELECT m.sort_order FROM messages m
                     WHERE m.session_id = s.id
                       AND m.role = 'user'
                       AND (m.part_flags & \(userMask)) != 0
                     ORDER BY m.sort_order DESC LIMIT 1),
                   -- Appended LAST on purpose: the decode below reads columns
                   -- by index, so a new column goes at the end to leave every
                   -- existing index untouched.
                   s.folder_id
            FROM sessions s ORDER BY s.updated_at DESC
            """
            // Note: `remote_tombstoned_at` column still exists on the
            // table for legacy rows but is no longer consulted. Peer-side
            // SessionV2 deletes are now applied as hard deletes (the row
            // and all its children leave SQLite outright) — see
            // ChatStore.deleteSessionLocalOnly + TombstoneManager.
        var stmt: OpaquePointer?
        var sessions: [ChatSession] = []
        // Count of unusable rows dropped this pass (NULL/empty primary key).
        // Logged once after the loop rather than per row so a systematically
        // corrupt table can't itself become a logging flood.
        var skippedRows = 0

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                // A row whose primary key is NULL/empty can't be opened, deleted
                // or synced by id — it is unusable rather than merely odd. Skip
                // it (loudly) instead of surfacing a session that breaks every
                // later lookup. This is the guard that breaks the crash loop.
                let id = Self.colText(stmt, 0)
                guard !id.isEmpty else {
                    skippedRows += 1
                    continue
                }
                let title = Self.colTextOpt(stmt, 1)
                let modelId = Self.colText(stmt, 2)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let category = Self.colTextOpt(stmt, 5)
                // Latest assistant text (preferred) → latest user text (fallback).
                let assistantRaw = Self.colTextOpt(stmt, 6)
                let userRaw = Self.colTextOpt(stmt, 7)
                let assistantText = assistantRaw.flatMap { extractTextFromPartsJSON($0) }
                let userText = userRaw.flatMap { extractTextFromPartsJSON($0) }
                // sort_order of each picked row (columns 12/13). Prefer whichever
                // is genuinely newer: assistant wins when its row is at least as
                // recent (covers mid-tool-call previews); the user message wins
                // only when the user just sent something the assistant hasn't
                // answered yet (assistant row is from an earlier turn). This
                // replaces the dropped SQL pivot clause and is robust to
                // sort_order re-ranking from iCloud merges.
                let asstSortOrder: Int? = sqlite3_column_type(stmt, 12) != SQLITE_NULL
                    ? Int(sqlite3_column_int64(stmt, 12)) : nil
                let userSortOrder: Int? = sqlite3_column_type(stmt, 13) != SQLITE_NULL
                    ? Int(sqlite3_column_int64(stmt, 13)) : nil
                let lastMessage: String? = {
                    switch (assistantText, userText) {
                    case let (a?, u?):
                        // Both present — newer sort_order wins; tie → assistant.
                        if let ao = asstSortOrder, let uo = userSortOrder, uo > ao { return u }
                        return a
                    case let (a?, nil): return a
                    case let (nil, u?): return u
                    default: return nil
                    }
                }()
                // [LastMsgDiag removed — T-ios-session-list-equatable-jank]
                // This per-session diagnostic logged one (or two) lines for
                // EVERY session on EVERY listSessions() call — ~2900 lines for a
                // single session-list rebuild on this user's device, ~73% of the
                // whole log. The NSLog volume + daily-file writes were themselves
                // a measurable Debug-build drag on the very session-switch path
                // being profiled, and drowned out every other signal. Dropped;
                // the last-message extractor logic above is unchanged.
                let source = Self.colTextOpt(stmt, 8)
                let lastSyncedAt: Date? = sqlite3_column_type(stmt, 9) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)) : nil
                let remoteDeviceId = Self.colTextOpt(stmt, 10)
                let pinnedAt: Date? = sqlite3_column_type(stmt, 11) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11)) : nil
                let folderId = Self.colTextOpt(stmt, 14)

                sessions.append(ChatSession(
                    id: id, title: title, category: category, modelId: modelId,
                    createdAt: createdAt, updatedAt: updatedAt, lastMessage: lastMessage,
                    source: source, lastSyncedAt: lastSyncedAt,
                    remoteDeviceId: remoteDeviceId, pinnedAt: pinnedAt,
                    folderId: folderId
                ))
            }
        }
        sqlite3_finalize(stmt)

        if skippedRows > 0 {
            iCloudLogger.error("[ChatStore.listSessions] skipped \(skippedRows) unusable session row(s) with NULL/empty id — see T-ios-listsessions-cstring-trap")
        }

        // [T-ios-listsessions-cache] Store the freshly-built list; subsequent
        // calls return this same array until a mutation invalidates it.
        sessionListCache = sessions
        sessionListCacheDirty = false
        return sessions
    }

    /// Query sync_devices table and check UserDefaults to find which remote devices have sync enabled.
    private func enabledRemoteDeviceIdsFromDefaults() -> Set<String> {
        let selfDeviceId = syncZoneName.replacingOccurrences(of: "device-", with: "")
        var ids = Set<String>()
        let sql = "SELECT device_id FROM sync_devices WHERE device_id != ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (selfDeviceId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let deviceId = String(cString: sqlite3_column_text(stmt, 0))
                if UserDefaults.standard.bool(forKey: "cloudSync.device.\(deviceId).enabled") {
                    ids.insert(deviceId)
                }
            }
        }
        sqlite3_finalize(stmt)
        return ids
    }


    /// Ordered, pre-compiled markdown-stripping regexes for session previews.
    ///
    /// Previously these ran as a chain of `String.replacingOccurrences(of:…,
    /// options: .regularExpression)` calls. Each such call re-compiles the
    /// pattern *and* bridges `String → NSString` afresh; when `listSessions()`
    /// runs on a background cooperative queue over hundreds of messages whose
    /// text contains non-BMP characters (emoji like ⚡❌✅), Foundation could
    /// corrupt the temporary-NSString freelist and crash inside
    /// `NSString substringWithRange` / `_xzm_xzone_malloc`.
    ///
    /// Extract plain text preview from a parts_json string.
    /// [T-sessions-cli-truncate] Full-text extraction for minis-sessions-cli
    /// `messages` (loadMessagePage). Unlike extractTextFromPartsJSON (the
    /// 100-char single-part plain-text PREVIEW helper for the session list),
    /// this joins EVERY text part, keeps markdown intact, and applies no
    /// length cap — the caller enforces the documented 1000 / 50000 (--full)
    /// ceiling and sets the "truncated" flag. System-reminder and
    /// attachment-marker noise is still stripped; media-only and mid-tool
    /// messages keep the same placeholder fallbacks as the preview path.
    func extractFullTextFromPartsJSON(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parts = try? JSONDecoder().decode([ContentPart].self, from: data) else { return nil }
        var texts: [String] = []
        var hasMedia = false
        var toolUses: [ToolUse] = []
        var toolResults: [ToolResult] = []
        for part in parts {
            switch part {
            case .mediaRef:
                hasMedia = true
            case .toolUse(let tu):
                toolUses.append(tu)
            case .toolResult(let tr):
                toolResults.append(tr)
            case .text(var t) where !t.isEmpty:
                t = RawMessage.stripSystemReminders(t)
                if let start = t.range(of: "<user-attached-files>") {
                    let end = t.range(of: "</user-attached-files>")
                    let endBound = end?.upperBound ?? t.endIndex
                    t = String(t[t.startIndex..<start.lowerBound] + t[endBound...])
                }
                t = RawMessage.stripAttachmentMarkers(t)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                texts.append(t)
            default:
                continue
            }
        }
        if !texts.isEmpty { return texts.joined(separator: "\n\n") }
        if hasMedia { return "[Image]" }
        if !toolUses.isEmpty {
            return toolUses.map { summarizeToolUse($0) }.joined(separator: ", ")
        }
        if !toolResults.isEmpty {
            return toolResults.map { tr in
                let preview = tr.output.prefix(200)
                return "[Tool result: \(preview)]"
            }.joined(separator: "\n")
        }
        return nil
    }

    func extractTextFromPartsJSON(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parts = try? JSONDecoder().decode([ContentPart].self, from: data) else { return nil }
        var hasMedia = false
        var lastToolUse: ToolUse?
        var lastTextPreview: String?
        for part in parts {
            switch part {
            case .mediaRef:
                hasMedia = true
            case .toolUse(let tu):
                lastToolUse = tu
                continue
            case .text(var t) where !t.isEmpty:
                t = RawMessage.stripSystemReminders(t)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                if let start = t.range(of: "<user-attached-files>") {
                    let end = t.range(of: "</user-attached-files>")
                    let endBound = end?.upperBound ?? t.endIndex
                    t = String(t[t.startIndex..<start.lowerBound] + t[endBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                t = RawMessage.stripAttachmentMarkers(t)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                let clean = MarkdownStripper.plainText(t)
                    .trimmingCharacters(in: .whitespaces)
                guard !clean.isEmpty else { continue }
                lastTextPreview = String(clean.prefix(100))
            default:
                continue
            }
        }
        // When tool_use parts follow text, prefer the tool summary — it
        // reflects the most recent activity (the text is the preamble the
        // model emitted before invoking tools).
        if let tu = lastToolUse { return summarizeToolUse(tu) }
        if let text = lastTextPreview { return text }
        if hasMedia { return "[Image]" }
        return nil
    }

    /// Build a short preview string for a tool_use block. Used by the session
    /// list when an assistant turn is mid-tool-call and has no text part yet.
    /// Strategy: prefer `input.tool_title` if the model included one, otherwise
    /// pick the most meaningful argument per known tool family, else fall back
    /// to the bare tool name. Output is capped at 100 chars to match the text
    /// preview ceiling.
    private func summarizeToolUse(_ tu: ToolUse) -> String {
        let input: [String: Any] = {
            guard let d = tu.input.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { return [:] }
            return obj
        }()

        func str(_ key: String) -> String? {
            guard let v = input[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func cap(_ s: String, _ n: Int = 100) -> String {
            return s.count > n ? String(s.prefix(n)) + "…" : s
        }

        if let title = str("tool_title") {
            return cap(title)
        }

        switch tu.name {
        case "shell_execute":
            if let cmd = str("command") { return cap("$ " + cmd) }
        case "file_read":
            if let p = str("path") { return cap("Reading " + p) }
        case "file_write":
            if let p = str("path") { return cap("Writing " + p) }
        case "file_edit":
            if let p = str("path") { return cap("Editing " + p) }
        case "read_image":
            if let p = str("path") { return cap("Reading image " + p) }
        case "browser_use":
            let action = str("action") ?? "browse"
            if let url = str("url") { return cap("\(action) \(url)") }
            return cap("browser_use \(action)")
        case "memory_write":
            if let content = str("content") { return cap("memory_write: " + content) }
        case "memory_get":
            if let kw = input["keywords"] as? [Any] {
                let joined = kw.compactMap { $0 as? String }.joined(separator: ", ")
                if !joined.isEmpty { return cap("memory_get: " + joined) }
            }
            if let kw = str("keywords") { return cap("memory_get: " + kw) }
        default:
            break
        }

        return cap("🔧 " + tu.name)
    }
}
