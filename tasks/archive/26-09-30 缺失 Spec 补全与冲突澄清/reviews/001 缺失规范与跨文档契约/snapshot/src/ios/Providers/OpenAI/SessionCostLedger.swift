import Foundation
import SQLite3

struct SessionCostSummary: Sendable, Equatable {
    let amountCNY: Decimal
    let requestCount: Int
    let unpricedCount: Int
    var estimatedAmountCNY: Decimal? { unpricedCount == 0 ? amountCNY : nil }
}

/// 仅由 ChatStore actor 调用。独立本地账本保留已消费请求，不随消息编辑/重试回滚。
/// 每个请求两次有界写入；会话总额读取为 O(1)，不随流式片段写盘。
enum SessionCostLedger {
    enum Failure: Error { case database, invalidRecord }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func install(_ db: OpaquePointer?) throws {
        try execute(db, """
            CREATE TABLE IF NOT EXISTS session_cost_totals (
                session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                amount_cny TEXT NOT NULL DEFAULT '0',
                request_count INTEGER NOT NULL DEFAULT 0,
                unpriced_count INTEGER NOT NULL DEFAULT 0
            )
            """)
        try execute(db, """
            CREATE TABLE IF NOT EXISTS session_cost_requests (
                request_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES session_cost_totals(session_id) ON DELETE CASCADE,
                record_json TEXT
            )
            """)
        try execute(db, "CREATE INDEX IF NOT EXISTS idx_session_cost_requests_session ON session_cost_requests(session_id)")
    }

    /// 只在新建会话时调用，绝不登记旧会话或从云端导入的旧记录。
    static func enroll(_ db: OpaquePointer?, sessionID: String) throws {
        try execute(db, "INSERT OR IGNORE INTO session_cost_totals(session_id) VALUES (?)", [sessionID])
    }

    static func summary(_ db: OpaquePointer?, sessionID: String) throws -> SessionCostSummary? {
        let stmt = try prepare(db, "SELECT amount_cny,request_count,unpriced_count FROM session_cost_totals WHERE session_id=?", [sessionID])
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(stmt, 0),
                  let amount = Decimal(string: String(cString: text), locale: Locale(identifier: "en_US_POSIX")),
                  !amount.isNaN, amount >= 0 else { throw Failure.invalidRecord }
            return SessionCostSummary(amountCNY: amount,
                requestCount: Int(sqlite3_column_int64(stmt, 1)),
                unpricedCount: Int(sqlite3_column_int64(stmt, 2)))
        default: throw Failure.database
        }
    }

    static func begin(_ db: OpaquePointer?, sessionID: String, requestID: String) throws -> Bool {
        guard try summary(db, sessionID: sessionID) != nil else { return false }
        try execute(db, "SAVEPOINT session_cost_begin")
        do {
            try execute(db, "INSERT OR IGNORE INTO session_cost_requests(request_id,session_id) VALUES (?,?)", [requestID, sessionID])
            let inserted = sqlite3_changes(db) == 1
            if inserted {
                try execute(db, "UPDATE session_cost_totals SET request_count=request_count+1, unpriced_count=unpriced_count+1 WHERE session_id=?", [sessionID])
            }
            try execute(db, "RELEASE session_cost_begin")
            return inserted
        } catch {
            try? execute(db, "ROLLBACK TO session_cost_begin")
            try? execute(db, "RELEASE session_cost_begin")
            throw error
        }
    }

    /// 未取得完整用量的请求保持未计价；后续不能把部分合计冒充整个会话的费用。
    static func finish(_ db: OpaquePointer?, sessionID: String, record: DeepSeekCostRecord) throws {
        guard record.amountCNY >= 0, !record.amountCNY.isNaN,
              let previous = try summary(db, sessionID: sessionID),
              let json = String(data: try JSONEncoder().encode(record), encoding: .utf8) else { throw Failure.invalidRecord }
        try execute(db, "SAVEPOINT session_cost_finish")
        do {
            try execute(db, "UPDATE session_cost_requests SET record_json=? WHERE request_id=? AND session_id=? AND record_json IS NULL", [json, record.requestID, sessionID])
            if sqlite3_changes(db) == 1 {
                let total = previous.amountCNY + record.amountCNY
                guard !total.isNaN, total >= 0, previous.unpricedCount > 0 else { throw Failure.invalidRecord }
                try execute(db, "UPDATE session_cost_totals SET amount_cny=?, unpriced_count=unpriced_count-1 WHERE session_id=?", [NSDecimalNumber(decimal: total).stringValue, sessionID])
            }
            try execute(db, "RELEASE session_cost_finish")
        } catch {
            try? execute(db, "ROLLBACK TO session_cost_finish")
            try? execute(db, "RELEASE session_cost_finish")
            throw error
        }
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw Failure.database }
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw Failure.database
            }
        }
        return stmt
    }

    private static func execute(_ db: OpaquePointer?, _ sql: String, _ values: [String] = []) throws {
        let stmt = try prepare(db, sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.database }
    }
}
