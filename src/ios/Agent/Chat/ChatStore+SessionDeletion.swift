//
//  ChatStore+SessionDeletion.swift
//  Minis - 聊天持久化（Agent/Chat）
//
//  会话记忆开关、删除会话（本地 / 云端）。
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

/// [T-memory-enabled-new-session-bug DIAG] dedicated category so the
/// memory-toggle trace is grep-able (`[MemDiag]`) without ChatStore noise.
private let memDiagLogger = AppLogger(category: "MemDiag")
private let iCloudLogger = AppLogger(category: "iCloud")

extension ChatStore {

    func getMemoryEnabled(sessionId: String) -> Bool {
        // [T-memory-global-toggle-settings-ui-ios] If the session row
        // already exists, return its stored per-session value. If no
        // row exists (genuinely new session — loadSession ran before
        // the session was persisted), fall back to the global default
        // from UserDefaults("memory.global.enabled"), defaulting to
        // true so users upgrading without the key set see no change.
        // Already-existing sessions keep their stored value when the
        // global toggle changes — only NEW sessions inherit it.
        let sql = "SELECT memory_enabled FROM sessions WHERE id = ?"
        var stmt: OpaquePointer?
        var rowFound = false
        var enabled = true
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                enabled = sqlite3_column_int(stmt, 0) != 0
                rowFound = true
            }
        }
        sqlite3_finalize(stmt)
        // [T-memory-enabled-new-session-bug DIAG]
        let rawObj = UserDefaults.standard.object(forKey: "memory.global.enabled")
        if rowFound {
            memDiagLogger.info("[MemDiag] getMemoryEnabled sid=\(sessionId.prefix(8)) rowFound=true storedRow=\(enabled) (returning storedRow) globalRaw=\(String(describing: rawObj))")
            return enabled
        }
        // No row — apply global default. UserDefaults.bool returns false
        // for unset keys, so probe presence via object(forKey:) first
        // and treat absent as true (matches @AppStorage default).
        if let stored = UserDefaults.standard.object(forKey: "memory.global.enabled") as? Bool {
            memDiagLogger.info("[MemDiag] getMemoryEnabled sid=\(sessionId.prefix(8)) rowFound=false → global=\(stored)")
            return stored
        }
        memDiagLogger.info("[MemDiag] getMemoryEnabled sid=\(sessionId.prefix(8)) rowFound=false global unset → true")
        return true
    }

    func setMemoryEnabled(sessionId: String, enabled: Bool) {
        let sql = "UPDATE sessions SET memory_enabled = ? WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func deleteSession(_ id: String) {
        invalidateSessionListCache()
        // Queue cloud deletions BEFORE removing local rows so the SELECTs
        // below can still enumerate child ids. Peers receive op=delete
        // for the session + each child and apply them as hard deletes
        // (see TombstoneManager.applyRemoteSessionDeletion).
        markSessionForCloudDeletion(id)

        deleteSessionLocalRowsOnly(id)

        // [T-icloud-deleted-session-resurrection] Record a recent-delete
        // tombstone so an inbound merge (e.g. fetchRecentV2 pulling the still-
        // present cloud record before our delete tombstone lands) refuses to
        // re-insert this session / its messages / its files. Pruned by the
        // 30-day TTL on launch (ids are UUIDs, so it never blocks a real
        // future session).
        recordDeletedSessionTombstone(id)
    }

    /// Hard-delete a session and its children locally without queuing any
    /// cloud delete rows. Used by the inbound side: when a peer device
    /// pushes a SessionV2 op=delete, we apply it locally and STOP — the
    /// cloud already has the deletion, re-queueing it would just create a
    /// noisy round-trip and risk a delete-loop with peers that haven't
    /// yet drained the same tombstone.
    func deleteSessionLocalOnly(_ id: String) {
        deleteSessionLocalRowsOnly(id)
    }

    /// True if a session row exists locally. Lightweight existence check
    /// for inbound delete handlers — they need to know whether to log a
    /// real deletion or a no-op.
    func sessionExists(id: String) -> Bool {
        let sql = "SELECT 1 FROM sessions WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func deleteSessionLocalRowsOnly(_ id: String) {
        // [T-ios-listsessions-cache] Invalidate here (the low-level row delete)
        // so ALL callers are covered — deleteSession AND deleteSessionLocalOnly.
        invalidateSessionListCache()
        deleteMessages(sessionId: id)
        deleteCompactMarkers(sessionId: id)
        deleteSessionMedia(id)

        let sql = "DELETE FROM sessions WHERE id = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // Clean up per-session etag cache
        if #available(iOS 17.0, *) {
            Task { @MainActor in CloudSyncEngine.shared.removeSessionCache(id) }
        }
        // [T-ios-session-paused-badge] Drop any badge state for a deleted session
        // so a stale "paused" badge can't linger in the persisted store.
        Task { @MainActor in SessionBadgeStore.shared.clearAll(for: id) }
        // [T-ios-delete-session-live-activity] All delete funnels (swipe /
        // long-press / batch / RPC / inbound iCloud delete) converge here, so
        // this is the single place that guarantees a deleted conversation never
        // stays visible in the Dynamic Island / Lock Screen. Order matters:
        // setInactive first so the tracker (and any snapshot rebuild) no longer
        // contains the session, then let the Live Activity manager end or trim
        // the on-screen activity.
        Task { @MainActor in
            SessionActivityTracker.shared.setInactive(id, source: "sessionDeleted")
            // Every deletion route converges here, including remote tombstones
            // and debug RPC. Removing is a no-op when no ViewModel is cached;
            // when present, cancel() also stops that session's web searches.
            ViewModelCache.shared.remove(sessionId: id)
            AgentLiveActivityManager.shared.handleSessionDeleted(id)
        }
    }

    /// Mark a session and all its child records (messages, compact markers) as
    /// pending iCloud deletion. Called from deleteSession before the local rows
    /// disappear so we can still enumerate the ids.
    private func markSessionForCloudDeletion(_ sessionId: String) {
        guard !syncZoneName.isEmpty else { return }
        // Session itself
        markDirty(recordType: "Session", recordId: sessionId, operation: "delete")
        // Messages
        let msgSql = "SELECT id FROM messages WHERE session_id = ?"
        var msgStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, msgSql, -1, &msgStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(msgStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(msgStmt) == SQLITE_ROW {
                let msgId = String(cString: sqlite3_column_text(msgStmt, 0))
                markDirty(recordType: "Message", recordId: msgId, operation: "delete")
            }
        }
        sqlite3_finalize(msgStmt)
        // Compact markers
        let cmSql = "SELECT id FROM compact_markers WHERE session_id = ?"
        var cmStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, cmSql, -1, &cmStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(cmStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(cmStmt) == SQLITE_ROW {
                let cmId = String(cString: sqlite3_column_text(cmStmt, 0))
                markDirty(recordType: "CompactMarker", recordId: cmId, operation: "delete")
            }
        }
        sqlite3_finalize(cmStmt)
        // SessionFile records — walk the workspace and queue a delete for
        // every file that lives on iCloud. MUST run before
        // deleteSessionMedia removes the local files. recordIds are
        // "<sessionId>:<rel>" matching appendMediaFile +
        // scanAndMarkSessionFilesForResurrect.
        let sessionDir = minisBaseURL.appendingPathComponent(sessionId, isDirectory: true)
        var fileDeleteCount = 0
        if let enumerator = FileManager.default.enumerator(
            at: sessionDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                      isFile else { continue }
                let rel = url.path.replacingOccurrences(of: sessionDir.path + "/", with: "")
                markDirty(recordType: "SessionFile", recordId: "\(sessionId):\(rel)", operation: "delete")
                fileDeleteCount += 1
            }
        }
        iCloudLogger.info("[iCloud] deleteSession \(sessionId.prefix(8)) → cloud delete queued: \(fileDeleteCount) SessionFile records (in addition to Session/Message/CompactMarker tombstones)")
    }

    /// Public entry: queue a SessionFile cloud delete for one file under
    /// a session's workspace. Used by FileBrowserView.deleteItem when the
    /// user removes a file inside `Library/MinisChat/minis/<sid>/...`.
    /// `relPath` must be "<subdir>/<rest>" matching the recordId scheme.
    func markSessionFileForCloudDeletion(sessionId: String, relPath: String) {
        guard !syncZoneName.isEmpty, !sessionId.isEmpty, !relPath.isEmpty else { return }
        markDirty(recordType: "SessionFile",
                  recordId: "\(sessionId):\(relPath)",
                  operation: "delete")
    }
}
