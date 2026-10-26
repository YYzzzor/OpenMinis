//
//  ChatStore+Maintenance.swift
//  Minis - 聊天持久化（Agent/Chat）
//
//  消息裁剪、会话修复。
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let logger = AppLogger(category: "ChatStore")

extension ChatStore {

    /// Maximum messages per session. Oldest messages beyond this limit are
    /// deleted after each appendMessages call.
    private static let pruneThreshold = 2048

    /// Delete the oldest messages when a session exceeds `pruneThreshold`.
    ///
    /// Safety rules:
    /// - Only runs when message count strictly exceeds the threshold.
    /// - Uses `DELETE ... WHERE id IN (SELECT id ... LIMIT N)` to delete an
    ///   exact number of rows, immune to duplicate sort_order values.
    /// - Never deletes more than `totalCount - pruneThreshold` rows.
    /// - Verifies the count-to-delete is positive and less than totalCount
    ///   (always keeps at least `pruneThreshold` messages).
    /// - Also cleans up stale compact markers.
    func pruneOldMessages(sessionId: String) {
        // 1. Count total messages
        var countStmt: OpaquePointer?
        let countSql = "SELECT COUNT(*) FROM messages WHERE session_id = ?"
        guard sqlite3_prepare_v2(db, countSql, -1, &countStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(countStmt, 1, (sessionId as NSString).utf8String, -1, nil)
        guard sqlite3_step(countStmt) == SQLITE_ROW else {
            sqlite3_finalize(countStmt)
            return
        }
        let totalCount = Int(sqlite3_column_int64(countStmt, 0))
        sqlite3_finalize(countStmt)

        // Phase A: DO NOT call deleteOldCompactMarkers here. Compact markers are
        // append-only archive and must survive appendMessages. Old markers are only
        // removed when the session itself is deleted (deleteSession path).

        guard totalCount > Self.pruneThreshold else { return }

        let deleteCount = totalCount - Self.pruneThreshold

        // 2. Safety: deleteCount must be positive and must keep at least pruneThreshold rows
        guard deleteCount > 0 && deleteCount < totalCount else {
            logger.warning("[Prune] Unexpected deleteCount=\(deleteCount) total=\(totalCount) — skipping")
            return
        }

        // 3. Delete exactly deleteCount oldest rows by id (immune to sort_order duplicates)
        let delSql = """
            DELETE FROM messages WHERE id IN (
                SELECT id FROM messages WHERE session_id = ?
                ORDER BY sort_order ASC, created_at ASC, id ASC
                LIMIT ?
            )
        """
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, delSql, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(delStmt, 2, Int64(deleteCount))
            sqlite3_step(delStmt)
        }
        sqlite3_finalize(delStmt)

        let deleted = Int(sqlite3_changes(db))
        logger.info("[Prune] session \(sessionId.prefix(8)): deleted \(deleted) oldest messages (was \(totalCount), threshold \(Self.pruneThreshold))")
    }

    /// Delete all compact markers except the latest one.
    private func deleteOldCompactMarkers(sessionId: String) {
        let sql = """
            DELETE FROM compact_markers WHERE session_id = ? AND id != (
                SELECT id FROM compact_markers WHERE session_id = ? ORDER BY created_at DESC LIMIT 1
            )
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (sessionId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Session Repair (Phase A)

    /// Return value for session repair operations.
    struct RepairReport {
        var sortOrderFixed: Int = 0
        var markersUpgraded: Int = 0
        var hadAnomaly: Bool { sortOrderFixed > 0 || markersUpgraded > 0 }
    }

    /// Cheap anomaly check: returns true if the session has duplicate sort_orders
    /// OR any compact marker lacks `first_kept_message_id`. Used to skip expensive
    /// repair when the session is already healthy.
    func sessionNeedsRepair(sessionId: String) -> Bool {
        // 1. sortOrder duplicates
        let dupSql = "SELECT COUNT(*), COUNT(DISTINCT sort_order) FROM messages WHERE session_id = ?"
        var dupStmt: OpaquePointer?
        var hasDup = false
        if sqlite3_prepare_v2(db, dupSql, -1, &dupStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(dupStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            if sqlite3_step(dupStmt) == SQLITE_ROW {
                let total = sqlite3_column_int64(dupStmt, 0)
                let unique = sqlite3_column_int64(dupStmt, 1)
                if total != unique { hasDup = true }
            }
        }
        sqlite3_finalize(dupStmt)
        if hasDup { return true }

        // 2. any marker without first_kept_message_id AND without last_compacted_message_id.
        // compactAll markers intentionally have first_kept_message_id = NULL (and a non-null
        // last_compacted_message_id) — they must NOT be treated as legacy/needing repair, or
        // step 3 below would overwrite them with a bogus message id from past-the-end sortOrder.
        let markerSql = "SELECT 1 FROM compact_markers WHERE session_id = ? AND first_kept_message_id IS NULL AND last_compacted_message_id IS NULL LIMIT 1"
        var mStmt: OpaquePointer?
        var hasLegacyMarker = false
        if sqlite3_prepare_v2(db, markerSql, -1, &mStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(mStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            hasLegacyMarker = sqlite3_step(mStmt) == SQLITE_ROW
        }
        sqlite3_finalize(mStmt)
        if hasLegacyMarker { return true }

        // 3. rank inversion: dense 0..n-1 expected by canonical (created_at, id) order.
        // Catches the case where a remote merge inserted with a hint integer that
        // didn't match local rank (legacy data from pre-fix builds), or where any
        // other pathway left holes/out-of-order rows.
        let invSql = """
            SELECT 1 FROM (
              SELECT sort_order,
                     ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) - 1 AS expected
              FROM messages WHERE session_id = ?
            ) WHERE sort_order != expected LIMIT 1
        """
        var invStmt: OpaquePointer?
        var hasInversion = false
        if sqlite3_prepare_v2(db, invSql, -1, &invStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(invStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            hasInversion = sqlite3_step(invStmt) == SQLITE_ROW
        }
        sqlite3_finalize(invStmt)
        return hasInversion
    }

    /// Perform a session repair: rewrite sort_orders to a stable dense sequence and
    /// upgrade legacy compact markers (nil first_kept_message_id) by looking up the
    /// corresponding row via legacy firstKeptSortOrder.
    ///
    /// Safe to call unconditionally — no-op if session is already healthy.
    /// Wraps everything in a single transaction.
    @discardableResult
    func repairSession(sessionId: String) -> RepairReport {
        invalidateSessionListCache()
        var report = RepairReport()

        exec("BEGIN TRANSACTION")

        // Step 1: reload messages by a stable composite key to drive sortOrder rewrite.
        // Order by (created_at, id) ignoring the current sort_order entirely — this gives
        // us a canonical sequence independent of any existing duplicates.
        let selectSql = "SELECT id, sort_order FROM messages WHERE session_id = ? ORDER BY created_at ASC, id ASC"
        var rows: [(id: String, oldSortOrder: Int)] = []
        var selStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSql, -1, &selStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(selStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(selStmt) == SQLITE_ROW {
                let idC = sqlite3_column_text(selStmt, 0).map { String(cString: $0) } ?? ""
                let so = Int(sqlite3_column_int64(selStmt, 1))
                rows.append((id: idC, oldSortOrder: so))
            }
        }
        sqlite3_finalize(selStmt)

        // Step 2: compute new sortOrders and update any that changed.
        // We assign 0..n-1 dense, using the canonical (created_at, id) order.
        let updateSql = "UPDATE messages SET sort_order = ? WHERE id = ?"
        var updStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSql, -1, &updStmt, nil) == SQLITE_OK {
            for (newSO, row) in rows.enumerated() where row.oldSortOrder != newSO {
                sqlite3_reset(updStmt)
                sqlite3_bind_int(updStmt, 1, Int32(newSO))
                sqlite3_bind_text(updStmt, 2, (row.id as NSString).utf8String, -1, nil)
                sqlite3_step(updStmt)
                report.sortOrderFixed += 1
            }
        }
        sqlite3_finalize(updStmt)

        // Step 3: upgrade legacy markers. Build a (oldSortOrder -> id) map first, then
        // find each nil-firstKeptMessageId marker and fill it in using firstKeptSortOrder.
        // NOTE: this lookup uses the NEW sortOrder (we just rewrote it), so we build
        // the map from the rewritten enumeration.
        var newSoToId: [Int: String] = [:]
        for (newSO, row) in rows.enumerated() { newSoToId[newSO] = row.id }
        // But legacy markers were written with OLD sortOrders. If rewrites happened,
        // the legacy firstKeptSortOrder may no longer point to anything sensible.
        // Strategy: try (a) newSO map, then (b) find old row whose OLD sort_order == legacy value.
        // Because step 2 just changed the sort_orders, approach (b) needs to query the
        // pre-update state — but we've already committed in memory. Instead, use the
        // original `rows` list: row index i now corresponds to new sort_order i. Find
        // any row where row.oldSortOrder == legacy value as a second-chance lookup.
        var oldSoToId: [Int: String] = [:]
        for row in rows { oldSoToId[row.oldSortOrder] = row.id }  // last write wins on dup

        // Only true legacy markers (no id-based fields at all) are upgraded.
        // compactAll markers (first_kept_message_id NULL but last_compacted_message_id set)
        // are intentional — leave them alone.
        let markerSelSql = "SELECT id, first_kept_sort_order FROM compact_markers WHERE session_id = ? AND first_kept_message_id IS NULL AND last_compacted_message_id IS NULL"
        var mSelStmt: OpaquePointer?
        var legacyMarkers: [(id: String, firstKeptSortOrder: Int)] = []
        if sqlite3_prepare_v2(db, markerSelSql, -1, &mSelStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(mSelStmt, 1, (sessionId as NSString).utf8String, -1, nil)
            while sqlite3_step(mSelStmt) == SQLITE_ROW {
                let mid = sqlite3_column_text(mSelStmt, 0).map { String(cString: $0) } ?? ""
                let fkso = Int(sqlite3_column_int64(mSelStmt, 1))
                legacyMarkers.append((id: mid, firstKeptSortOrder: fkso))
            }
        }
        sqlite3_finalize(mSelStmt)

        let mUpdSql = "UPDATE compact_markers SET first_kept_message_id = ? WHERE id = ?"
        var mUpdStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, mUpdSql, -1, &mUpdStmt, nil) == SQLITE_OK {
            for lm in legacyMarkers {
                // Try new map first (post-rewrite), then old map (pre-rewrite).
                let resolved = newSoToId[lm.firstKeptSortOrder] ?? oldSoToId[lm.firstKeptSortOrder]
                guard let fkmId = resolved else {
                    logger.warning("[Repair] marker id=\(lm.id.prefix(8)) firstKeptSortOrder=\(lm.firstKeptSortOrder) has no matching row — cannot upgrade")
                    continue
                }
                sqlite3_reset(mUpdStmt)
                sqlite3_bind_text(mUpdStmt, 1, (fkmId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(mUpdStmt, 2, (lm.id as NSString).utf8String, -1, nil)
                sqlite3_step(mUpdStmt)
                report.markersUpgraded += 1
                // Mark marker as dirty so the upgraded field propagates to iCloud.
                markDirty(recordType: "CompactMarker", recordId: lm.id)
            }
        }
        sqlite3_finalize(mUpdStmt)

        exec("COMMIT")

        if report.hadAnomaly {
            logger.warning("[Repair] session=\(sessionId.prefix(8)) sortOrderFixed=\(report.sortOrderFixed) markersUpgraded=\(report.markersUpgraded) totalRows=\(rows.count)")
        }
        return report
    }

    /// Cheap-check-then-repair. Safe to call on every session open; the check
    /// is a single SQL per session.
    @discardableResult
    func repairSessionIfNeeded(sessionId: String) -> RepairReport {
        guard sessionNeedsRepair(sessionId: sessionId) else { return RepairReport() }
        return repairSession(sessionId: sessionId)
    }

    /// Read a CompactMarker from a prepared statement at current row.
    /// Column order: id(0), session_id(1), summary(2), first_kept_sort_order(3),
    /// compacted_count(4), created_at(5), ui_boundary_sort_order(6),
    /// boundary_message_id(7), first_kept_message_id(8), last_compacted_message_id(9),
    /// version(10).
    func readCompactMarker(from stmt: OpaquePointer?) -> CompactMarker {
        let uiBoundary: Int? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
            ? Int(sqlite3_column_int64(stmt, 6))
            : nil
        let bmId: String? = sqlite3_column_type(stmt, 7) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 7))
            : nil
        let fkmId: String? = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 8))
            : nil
        let lcmId: String? = sqlite3_column_type(stmt, 9) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 9))
            : nil
        // version may be absent on rows written before the column was added —
        // ALTER TABLE ... DEFAULT 1 covers the SQL side, but defensive fallback
        // here keeps tests and tooling happy.
        let version: Int = sqlite3_column_type(stmt, 10) != SQLITE_NULL
            ? Int(sqlite3_column_int64(stmt, 10))
            : 1
        return CompactMarker(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            sessionId: String(cString: sqlite3_column_text(stmt, 1)),
            summary: String(cString: sqlite3_column_text(stmt, 2)),
            firstKeptSortOrder: Int(sqlite3_column_int64(stmt, 3)),
            compactedCount: Int(sqlite3_column_int64(stmt, 4)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            uiBoundarySortOrder: uiBoundary,
            boundaryMessageId: bmId,
            firstKeptMessageId: fkmId,
            lastCompactedMessageId: lcmId,
            version: version
        )
    }
}
