import XCTest
#if canImport(Minis)
@testable import Minis
#endif

private actor SuspendedBalance {
    private var pending: CheckedContinuation<DeepSeekBalance, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func fetch() async -> DeepSeekBalance {
        await withCheckedContinuation { continuation in
            pending = continuation
            waiting?.resume()
            waiting = nil
        }
    }
    func started() async {
        if pending != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finish() {
        pending?.resume(returning: DeepSeekBalance(amountCNY: 10))
        pending = nil
    }
}

final class DeepSeekBalanceModelTests: XCTestCase {
    private let first = DeepSeekAccountIdentity(providerID: "first", configRevision: 1, authRevision: 1)
    private let second = DeepSeekAccountIdentity(providerID: "second", configRevision: 1, authRevision: 1)

    @MainActor
    func testLateResponseCannotOverwriteSwitchedAccount() async {
        let gate = SuspendedBalance()
        let model = DeepSeekBalanceModel { key in
            if key == "old" { return await gate.fetch() }
            return DeepSeekBalance(amountCNY: 22)
        }
        let old = Task { await model.refresh(identity: first) { "old" } }
        await gate.started()
        await model.refresh(identity: second) { "new" }
        await gate.finish()
        await old.value
        XCTAssertEqual(model.amountCNY, 22)
        XCTAssertTrue(model.isCurrent(second))
        XCTAssertFalse(model.isCurrent(first))
    }

    @MainActor
    func testDismissalCancellationDoesNotPublishLateBalance() async {
        let gate = SuspendedBalance()
        let model = DeepSeekBalanceModel { _ in await gate.fetch() }
        let task = Task { await model.refresh(identity: first) { "dummy" } }
        await gate.started()
        task.cancel()
        await gate.finish()
        await task.value
        XCTAssertNil(model.amountCNY)
        XCTAssertFalse(model.hasFailed)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testCacheFailureAndUnsupportedAccountStates() async {
        enum Failure: Error { case expected }
        var calls = 0
        let model = DeepSeekBalanceModel { _ in
            calls += 1
            if calls > 1 { throw Failure.expected }
            return DeepSeekBalance(amountCNY: 0)
        }
        await model.refresh(identity: first) { "dummy" }
        await model.refresh(identity: first) { "dummy" }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.amountCNY, 0)
        await model.refresh(identity: first, force: true) { "dummy" }
        XCTAssertNil(model.amountCNY)
        XCTAssertTrue(model.hasFailed)
        await model.refresh(identity: nil) { XCTFail("Unsupported provider must not load credentials"); return nil }
        XCTAssertNil(model.amountCNY)
        XCTAssertFalse(model.hasFailed)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testCredentialRevisionInvalidatesCachedBalance() async {
        var calls = 0
        let model = DeepSeekBalanceModel { _ in calls += 1; return DeepSeekBalance(amountCNY: Decimal(calls)) }
        await model.refresh(identity: first) { "dummy" }
        let rotated = DeepSeekAccountIdentity(providerID: "first", configRevision: 1, authRevision: 2)
        await model.refresh(identity: rotated) { "rotated" }
        XCTAssertEqual(model.amountCNY, 2)
        XCTAssertEqual(calls, 2)
    }

    func testBalanceRequestUsesOnlyTheOfficialEndpoint() {
        let request = DeepSeekBalanceClient.makeRequest(apiKey: "unit-test-placeholder")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-placeholder")
        XCTAssertEqual(request.timeoutInterval, 12)
    }
}
