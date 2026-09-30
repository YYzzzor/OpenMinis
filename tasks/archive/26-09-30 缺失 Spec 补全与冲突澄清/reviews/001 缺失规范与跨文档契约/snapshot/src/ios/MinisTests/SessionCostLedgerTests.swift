import XCTest
import SQLite3
#if canImport(Minis)
@testable import Minis
#endif

final class SessionCostLedgerTests: XCTestCase {
    private func database() throws -> OpaquePointer {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA foreign_keys=ON; CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions VALUES ('old'),('new'),('other');", nil, nil, nil), SQLITE_OK)
        try SessionCostLedger.install(handle)
        return handle
    }

    private func record(_ id: String, _ amount: String) -> DeepSeekCostRecord {
        DeepSeekCostRecord(requestID: id, modelID: "deepseek-flash", amountCNY: Decimal(string: amount)!,
                           priceVersion: "2026-09-29", createdAt: Date(timeIntervalSince1970: 1))
    }

    func testLegacySessionsAreNeverEnrolledByReadingOrRequesting() throws {
        let db = try database(); defer { sqlite3_close(db) }
        XCTAssertNil(try SessionCostLedger.summary(db, sessionID: "old"))
        XCTAssertFalse(try SessionCostLedger.begin(db, sessionID: "old", requestID: "r"))
        XCTAssertNil(try SessionCostLedger.summary(db, sessionID: "old"))
    }

    func testToolLoopSumsEachRequestOnceAndUsesSavedAmounts() throws {
        let db = try database(); defer { sqlite3_close(db) }
        try SessionCostLedger.enroll(db, sessionID: "new")
        XCTAssertEqual(try SessionCostLedger.summary(db, sessionID: "new")?.estimatedAmountCNY, 0)
        XCTAssertTrue(try SessionCostLedger.begin(db, sessionID: "new", requestID: "a"))
        XCTAssertFalse(try SessionCostLedger.begin(db, sessionID: "new", requestID: "a"))
        XCTAssertNil(try SessionCostLedger.summary(db, sessionID: "new")?.estimatedAmountCNY)
        try SessionCostLedger.finish(db, sessionID: "new", record: record("a", "0.0752"))
        try SessionCostLedger.finish(db, sessionID: "new", record: record("a", "99"))
        XCTAssertTrue(try SessionCostLedger.begin(db, sessionID: "new", requestID: "b"))
        try SessionCostLedger.finish(db, sessionID: "new", record: record("b", "0.0376"))
        let saved = try XCTUnwrap(SessionCostLedger.summary(db, sessionID: "new"))
        XCTAssertEqual(saved.requestCount, 2)
        XCTAssertEqual(saved.unpricedCount, 0)
        XCTAssertEqual(saved.estimatedAmountCNY, Decimal(string: "0.1128"))
        try SessionCostLedger.install(db)
        XCTAssertEqual(try SessionCostLedger.summary(db, sessionID: "new"), saved)
    }

    func testInterruptedOrUnsupportedRequestDoesNotBecomeFree() throws {
        let db = try database(); defer { sqlite3_close(db) }
        try SessionCostLedger.enroll(db, sessionID: "new")
        _ = try SessionCostLedger.begin(db, sessionID: "new", requestID: "pending")
        _ = try SessionCostLedger.begin(db, sessionID: "new", requestID: "success")
        try SessionCostLedger.finish(db, sessionID: "new", record: record("success", "0.01"))
        let summary = try XCTUnwrap(SessionCostLedger.summary(db, sessionID: "new"))
        XCTAssertEqual(summary.amountCNY, Decimal(string: "0.01"))
        XCTAssertEqual(summary.unpricedCount, 1)
        XCTAssertNil(summary.estimatedAmountCNY)
    }

    func testRequestsCannotChargeAnotherSessionAndDeleteCascades() throws {
        let db = try database(); defer { sqlite3_close(db) }
        try SessionCostLedger.enroll(db, sessionID: "new")
        try SessionCostLedger.enroll(db, sessionID: "other")
        _ = try SessionCostLedger.begin(db, sessionID: "new", requestID: "a")
        try SessionCostLedger.finish(db, sessionID: "other", record: record("a", "1"))
        XCTAssertEqual(try SessionCostLedger.summary(db, sessionID: "other")?.estimatedAmountCNY, 0)
        XCTAssertNil(try SessionCostLedger.summary(db, sessionID: "new")?.estimatedAmountCNY)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM sessions WHERE id='new'", nil, nil, nil), SQLITE_OK)
        XCTAssertNil(try SessionCostLedger.summary(db, sessionID: "new"))
        XCTAssertTrue(try SessionCostLedger.begin(db, sessionID: "other", requestID: "a"))
    }

    func testTotalsSurviveClosingAndReopeningTheDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA foreign_keys=ON; CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions VALUES ('new');", nil, nil, nil), SQLITE_OK)
        try SessionCostLedger.install(db)
        try SessionCostLedger.enroll(db, sessionID: "new")
        _ = try SessionCostLedger.begin(db, sessionID: "new", requestID: "a")
        try SessionCostLedger.finish(db, sessionID: "new", record: record("a", "0.1234"))
        XCTAssertEqual(sqlite3_close(db), SQLITE_OK)
        db = nil
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let restored = try XCTUnwrap(SessionCostLedger.summary(db, sessionID: "new"))
        XCTAssertEqual(restored.estimatedAmountCNY, Decimal(string: "0.1234"))
        XCTAssertEqual(restored.requestCount, 1)
    }

    func testMalformedFinishLeavesPendingRequestIntact() throws {
        let db = try database(); defer { sqlite3_close(db) }
        try SessionCostLedger.enroll(db, sessionID: "new")
        _ = try SessionCostLedger.begin(db, sessionID: "new", requestID: "a")
        XCTAssertThrowsError(try SessionCostLedger.finish(db, sessionID: "new", record: record("a", "-1")))
        XCTAssertNil(try SessionCostLedger.summary(db, sessionID: "new")?.estimatedAmountCNY)
        try SessionCostLedger.finish(db, sessionID: "new", record: record("a", "1"))
        XCTAssertEqual(try SessionCostLedger.summary(db, sessionID: "new")?.estimatedAmountCNY, 1)
    }
}

final class DeepSeekRequestUsageTests: XCTestCase {
    private let base = "https://api.deepseek.com"
    private let started = Date(timeIntervalSince1970: 1)
    private let complete: [String: Any] = ["prompt_tokens":100_000, "prompt_cache_hit_tokens":80_000,
        "prompt_cache_miss_tokens":20_000, "completion_tokens":4_000]

    func testReportedInputIsSplitWithoutDoubleCounting() throws {
        let usage = try XCTUnwrap(DeepSeekRequestUsage.parse(complete, modelID: "deepseek-flash", baseURL: base, startedAt: started))
        XCTAssertEqual(usage.inputTokens, 20_000)
        XCTAssertEqual(usage.cacheReadTokens, 80_000)
        XCTAssertEqual(usage.outputTokens, 4_000)
    }

    func testMissingMalformedAndNonOfficialUsageStaysUnknown() {
        var missing = complete; missing.removeValue(forKey: "completion_tokens")
        var missingCache = complete; missingCache.removeValue(forKey: "prompt_cache_hit_tokens")
        var tooMany = complete; tooMany["prompt_cache_hit_tokens"] = 100_001
        var inconsistent = complete; inconsistent["prompt_cache_miss_tokens"] = 10
        var boolean = complete; boolean["completion_tokens"] = true
        for usage in [missing, missingCache, tooMany, inconsistent, boolean] {
            XCTAssertNil(DeepSeekRequestUsage.parse(usage, modelID: "deepseek-flash", baseURL: base, startedAt: started))
        }
        XCTAssertNil(DeepSeekRequestUsage.parse(complete, modelID: "deepseek-flash", baseURL: "https://proxy.example.com", startedAt: started))
    }

    func testResponsesUsesActualCachedAndOutputFields() throws {
        let data: [String: Any] = ["input_tokens":100, "input_tokens_details":["cached_tokens":70],
            "output_tokens":20, "output_tokens_details":["reasoning_tokens":15]]
        let usage = try XCTUnwrap(DeepSeekRequestUsage.parse(data, modelID: "deepseek-flash", baseURL: base, startedAt: started, responsesAPI:true))
        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.cacheReadTokens, 70)
        XCTAssertEqual(usage.outputTokens, 20)
        var missingCache = data; missingCache.removeValue(forKey: "input_tokens_details")
        XCTAssertNil(DeepSeekRequestUsage.parse(missingCache, modelID: "deepseek-flash", baseURL: base, startedAt: started, responsesAPI: true))
    }
}
