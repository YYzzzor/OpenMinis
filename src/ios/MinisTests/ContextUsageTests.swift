import XCTest

final class ContextUsageTests: XCTestCase {
    private let identity = ContextUsageIdentity(
        entryID: "entry-a",
        modelID: "model-a",
        providerID: "provider-a",
        contextWindow: 1_000,
        configRevision: 1
    )

    func testSnapshotUsesLatestInputContextCount() {
        var state = ContextUsageState()
        let revision = state.beginRequest()

        XCTAssertTrue(state.record(
            usedTokens: 500,
            identity: identity,
            requestRevision: revision
        ))

        let snapshot = state.snapshot(matching: identity)
        XCTAssertEqual(snapshot?.usedTokens, 500)
        XCTAssertEqual(snapshot?.contextWindow, 1_000)
        XCTAssertEqual(snapshot?.percentage, 50)
        XCTAssertEqual(snapshot?.fraction, 0.5)
    }

    func testZeroOrInvalidUsageRemainsUnknown() {
        var state = ContextUsageState()
        let revision = state.beginRequest()

        XCTAssertFalse(state.record(
            usedTokens: 0,
            identity: identity,
            requestRevision: revision
        ))
        XCTAssertNil(state.snapshot(matching: identity))
        XCTAssertFalse(state.record(
            usedTokens: -1,
            identity: identity,
            requestRevision: revision
        ))

        let invalidWindow = ContextUsageIdentity(
            entryID: identity.entryID,
            modelID: identity.modelID,
            providerID: identity.providerID,
            contextWindow: 0,
            configRevision: identity.configRevision
        )
        XCTAssertFalse(state.record(
            usedTokens: 10,
            identity: invalidWindow,
            requestRevision: revision
        ))
    }

    func testOverWindowUsageKeepsPercentageAndClampsRingFraction() {
        var state = ContextUsageState()
        let revision = state.beginRequest()
        let identity = ContextUsageIdentity(
            entryID: "entry-a",
            modelID: "model-a",
            providerID: "provider-a",
            contextWindow: 1_000,
            configRevision: self.identity.configRevision
        )

        XCTAssertTrue(state.record(
            usedTokens: 1_250,
            identity: identity,
            requestRevision: revision
        ))

        let snapshot = state.snapshot(matching: identity)
        XCTAssertEqual(snapshot?.percentage, 125)
        XCTAssertEqual(snapshot?.fraction, 1)
    }

    func testIntMaxUsageSaturatesPercentageSafely() {
        var state = ContextUsageState()
        let revision = state.beginRequest()
        let identity = ContextUsageIdentity(
            entryID: "entry-a",
            modelID: "model-a",
            providerID: "provider-a",
            contextWindow: 1,
            configRevision: self.identity.configRevision
        )

        XCTAssertTrue(state.record(
            usedTokens: Int.max,
            identity: identity,
            requestRevision: revision
        ))

        let snapshot = state.snapshot(matching: identity)
        XCTAssertEqual(snapshot?.usedTokens, Int.max)
        XCTAssertEqual(snapshot?.percentage, 1_000)
        XCTAssertEqual(snapshot?.fraction, 1)
    }

    func testSnapshotOnlyMatchesItsModelIdentity() {
        var state = ContextUsageState()
        let revision = state.beginRequest()
        XCTAssertTrue(state.record(
            usedTokens: 100,
            identity: identity,
            requestRevision: revision
        ))

        let changedModel = ContextUsageIdentity(
            entryID: identity.entryID,
            modelID: "model-b",
            providerID: identity.providerID,
            contextWindow: identity.contextWindow,
            configRevision: identity.configRevision
        )
        XCTAssertNil(state.snapshot(matching: changedModel))
    }

    func testSnapshotRequiresSameEntryProviderAndWindow() {
        var state = ContextUsageState()
        let revision = state.beginRequest()
        XCTAssertTrue(state.record(
            usedTokens: 100,
            identity: identity,
            requestRevision: revision
        ))

        let changedIdentities = [
            ContextUsageIdentity(
                entryID: "entry-b",
                modelID: identity.modelID,
                providerID: identity.providerID,
                contextWindow: identity.contextWindow,
                configRevision: identity.configRevision
            ),
            ContextUsageIdentity(
                entryID: identity.entryID,
                modelID: identity.modelID,
                providerID: "provider-b",
                contextWindow: identity.contextWindow,
                configRevision: identity.configRevision
            ),
            ContextUsageIdentity(
                entryID: identity.entryID,
                modelID: identity.modelID,
                providerID: identity.providerID,
                contextWindow: 2_000,
                configRevision: identity.configRevision
            )
        ]

        for changedIdentity in changedIdentities {
            XCTAssertNil(state.snapshot(matching: changedIdentity))
        }
    }

    func testSwitchingAwayAndBackDoesNotReviveOldSnapshot() {
        var state = ContextUsageState()
        let requestRevision = state.beginRequest()
        XCTAssertTrue(state.record(
            usedTokens: 100,
            identity: identity,
            requestRevision: requestRevision
        ))

        let switchedToOtherModel = ContextUsageIdentity(
            entryID: "entry-b",
            modelID: "model-b",
            providerID: "provider-b",
            contextWindow: 2_000,
            configRevision: 2
        )
        let switchedBackToOriginalModel = ContextUsageIdentity(
            entryID: identity.entryID,
            modelID: identity.modelID,
            providerID: identity.providerID,
            contextWindow: identity.contextWindow,
            configRevision: 3
        )

        XCTAssertNil(state.snapshot(matching: switchedToOtherModel))
        XCTAssertNil(state.snapshot(matching: switchedBackToOriginalModel))
    }

    func testFallbackCanRebindMatchingRouteToItsNewConfigurationEpoch() {
        let fallbackIdentity = ContextUsageIdentity(
            entryID: identity.entryID,
            modelID: identity.modelID,
            providerID: identity.providerID,
            contextWindow: identity.contextWindow,
            configRevision: identity.configRevision + 1
        )
        XCTAssertTrue(identity.matchesRoute(fallbackIdentity))

        var state = ContextUsageState()
        let requestRevision = state.beginRequest()
        XCTAssertTrue(state.record(
            usedTokens: 640,
            identity: fallbackIdentity,
            requestRevision: requestRevision
        ))
        XCTAssertNil(state.snapshot(matching: identity))
        XCTAssertEqual(state.snapshot(matching: fallbackIdentity)?.usedTokens, 640)
    }

    func testContinuationRetainsLastUsageUntilNewValidUsageArrives() {
        var state = ContextUsageState()
        let first = state.beginRequest()
        XCTAssertTrue(state.record(usedTokens: 420, identity: identity, requestRevision: first))

        let next = state.beginRequest()
        XCTAssertEqual(state.snapshot(matching: identity)?.percentage, 42)
        // 缺少新统计时仍然显示“上次有效请求”；不能退回未知或丢掉该值。
        XCTAssertFalse(state.record(usedTokens: 0, identity: identity, requestRevision: next))
        XCTAssertEqual(state.snapshot(matching: identity)?.usedTokens, 420)
        // 较旧请求的迟到结果不能覆盖保留的显示。
        XCTAssertFalse(state.record(usedTokens: 990, identity: identity, requestRevision: first))
        XCTAssertEqual(state.snapshot(matching: identity)?.percentage, 42)
        XCTAssertTrue(state.record(usedTokens: 570, identity: identity, requestRevision: next))
        XCTAssertEqual(state.snapshot(matching: identity)?.percentage, 57)
    }

    func testContextInvalidationClearsRetainedUsageAndRejectsInFlightResult() {
        var state = ContextUsageState()
        let first = state.beginRequest()
        XCTAssertTrue(state.record(usedTokens: 420, identity: identity, requestRevision: first))
        let next = state.beginRequest()
        XCTAssertNotNil(state.snapshot(matching: identity))
        state.invalidate()
        XCTAssertNil(state.snapshot(matching: identity))
        XCTAssertFalse(state.record(usedTokens: 570, identity: identity, requestRevision: next))
        XCTAssertNil(state.snapshot(matching: identity))
        let latest = state.beginRequest()
        XCTAssertNil(state.snapshot(matching: identity))
        XCTAssertTrue(state.record(usedTokens: 210, identity: identity, requestRevision: latest))
        XCTAssertEqual(state.snapshot(matching: identity)?.percentage, 21)
    }

    func testOlderRequestCannotOverwriteNewerSnapshot() {
        var state = ContextUsageState()
        let olderRevision = state.beginRequest()
        let newerRevision = state.beginRequest()
        XCTAssertTrue(state.record(
            usedTokens: 300,
            identity: identity,
            requestRevision: newerRevision
        ))

        XCTAssertFalse(state.record(
            usedTokens: 700,
            identity: identity,
            requestRevision: olderRevision
        ))
        XCTAssertEqual(state.snapshot(matching: identity)?.usedTokens, 300)
    }

    func testInvalidatedRequestCannotPublishLateUsage() {
        var state = ContextUsageState()
        let requestRevision = state.beginRequest()
        state.invalidate()

        XCTAssertFalse(state.record(
            usedTokens: 700,
            identity: identity,
            requestRevision: requestRevision
        ))
        XCTAssertNil(state.snapshot(matching: identity))
    }

    func testRequestPublicationAcceptsCurrentRoute() {
        var state = ContextUsageState()
        let revision = state.beginRequest()
        XCTAssertTrue(publish(to: &state, current: identity, revision: revision))
        XCTAssertEqual(state.snapshot(matching: identity)?.percentage, 42)
    }

    func testRequestPublicationRejectsMissingOrChangedRoute() {
        let alternatives: [ContextUsageIdentity?] = [
            nil,
            ContextUsageIdentity(entryID: "entry-b", modelID: identity.modelID, providerID: identity.providerID, contextWindow: 1_000, configRevision: 1),
            ContextUsageIdentity(entryID: identity.entryID, modelID: identity.modelID, providerID: "provider-b", contextWindow: 1_000, configRevision: 1),
            ContextUsageIdentity(entryID: identity.entryID, modelID: identity.modelID, providerID: identity.providerID, contextWindow: 2_000, configRevision: 1)
        ]
        for current in alternatives {
            var state = ContextUsageState()
            let revision = state.beginRequest()
            XCTAssertFalse(publish(to: &state, current: current, revision: revision))
            XCTAssertNil(state.latestSnapshot)
        }
    }

    func testRequestPublicationRejectsConfigurationChangesDuringDispatchOrStream() {
        let changed = ContextUsageIdentity(entryID: identity.entryID, modelID: identity.modelID, providerID: identity.providerID, contextWindow: identity.contextWindow, configRevision: 2)
        for streamRevision: UInt in [1, 2] {
            var state = ContextUsageState()
            let revision = state.beginRequest()
            XCTAssertFalse(publish(to: &state, current: changed, streamRevision: streamRevision, revision: revision))
            XCTAssertNil(state.latestSnapshot)
        }
    }

    func testRequestPublicationAcceptsKnownFallbackWithUpdatedEpoch() {
        let updated = ContextUsageIdentity(entryID: identity.entryID, modelID: identity.modelID, providerID: identity.providerID, contextWindow: identity.contextWindow, configRevision: 2)
        var state = ContextUsageState()
        let revision = state.beginRequest()
        XCTAssertTrue(publish(to: &state, current: updated, initial: "different-entry", streamRevision: 2, revision: revision))
        XCTAssertEqual(state.snapshot(matching: updated)?.usedTokens, 420)
    }

    func testRequestPublicationRejectsUnknownRetryAndUncapturedFallback() {
        for streamID: String? in [nil, "uncaptured-entry"] {
            var state = ContextUsageState()
            let revision = state.beginRequest()
            XCTAssertFalse(state.recordRequest(usedTokens: 420, initialEntryID: identity.entryID, streamEntryID: streamID, streamConfigRevision: 1, capturedIdentities: [identity.entryID: identity], currentIdentity: identity, requestRevision: revision))
            XCTAssertNil(state.latestSnapshot)
        }
    }

    func testRequestPublicationRejectsLateResultAfterContextInvalidation() {
        var state = ContextUsageState()
        let revision = state.beginRequest()
        state.invalidate()
        XCTAssertFalse(publish(to: &state, current: identity, revision: revision))
        XCTAssertNil(state.latestSnapshot)
    }

    private func publish(
        to state: inout ContextUsageState,
        current: ContextUsageIdentity?,
        initial: String = "entry-a",
        streamRevision: UInt = 1,
        revision: UInt64
    ) -> Bool {
        state.recordRequest(
            usedTokens: 420,
            initialEntryID: initial,
            streamEntryID: identity.entryID,
            streamConfigRevision: streamRevision,
            capturedIdentities: [identity.entryID: identity],
            currentIdentity: current,
            requestRevision: revision
        )
    }

}


final class ContextUsagePersistenceTests: XCTestCase {
    private func makeRecord(_ sid: String, tokens: Int = 420, key: String = "config-a") -> PersistedContextUsage {
        PersistedContextUsage(id: UUID(), sessionID: sid, usedTokens: tokens,
            entryID: "entry-a", modelID: "model-a", providerID: "provider-a", contextWindow: 1000,
            configurationKey: key, history: ContextUsageHistoryAnchor(messageCount: 1, messageDigest: "history", compactDigest: "marker"))
    }

    @MainActor
    func testSeparateSessionsSurviveStoreRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        let store = ContextUsagePersistence(fileURL: url)
        let a = makeRecord("a", tokens: 420), b = makeRecord("b", tokens: 730)
        try store.save(a); try store.save(b)
        let reopened = ContextUsagePersistence(fileURL: url)
        XCTAssertEqual(reopened.record(for: "a"), a)
        XCTAssertEqual(reopened.record(for: "b"), b)
        XCTAssertNil(reopened.record(for: "unknown"))
    }

    @MainActor
    func testUnrelatedConfigurationIsPreservedAndSwitchBackCannotRevive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        let store = ContextUsagePersistence(fileURL: url)
        let a = makeRecord("a"), b = makeRecord("b")
        try store.save(a); try store.save(b)
        try store.reconcile { sid, _, _ in sid == "a" ? "config-a" : "config-b" }
        XCTAssertEqual(store.record(for: "a"), a)
        XCTAssertNil(store.record(for: "b"))
        try store.reconcile { _, _, _ in "config-a" }
        XCTAssertNil(ContextUsagePersistence(fileURL: url).record(for: "b"))
        try store.remove(sessionID: "a")
        XCTAssertNil(ContextUsagePersistence(fileURL: url).record(for: "a"))
    }

    func testRestoredRouteIgnoresProcessEpochButRejectsDifferentSourceOrWindow() {
        let record = makeRecord("a")
        let same = ContextUsageIdentity(entryID: "entry-a", modelID: "model-a", providerID: "provider-a", contextWindow: 1000, configRevision: 999)
        XCTAssertEqual(record.snapshot(matching: same)?.percentage, 42)
        let otherProvider = ContextUsageIdentity(entryID: "entry-a", modelID: "model-a", providerID: "provider-b", contextWindow: 1000, configRevision: 999)
        XCTAssertNil(record.snapshot(matching: otherProvider))
        let otherWindow = ContextUsageIdentity(entryID: "entry-a", modelID: "model-a", providerID: "provider-a", contextWindow: 2000, configRevision: 999)
        XCTAssertNil(record.snapshot(matching: otherWindow))
    }

    func testHistoryDigestDetectsEditsAndOrderingAndIsStable() throws {
        let history = [["a", "user", "hello"], ["b", "assistant", "reply"]]
        let original = try XCTUnwrap(ContextUsageHistoryAnchor.digest(history))
        XCTAssertEqual(ContextUsageHistoryAnchor.digest(history), original)
        XCTAssertNotEqual(ContextUsageHistoryAnchor.digest(Array(history.reversed())), original)
        XCTAssertNotEqual(ContextUsageHistoryAnchor.digest([["a", "user", "edited"], history[1]]), original)
        let appended = history + [["c", "user", "next message"]]
        XCTAssertEqual(ContextUsageHistoryAnchor.digest(Array(appended.prefix(history.count))), original)
    }

    @MainActor
    func testCorruptArchiveDoesNotInventUsage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not valid JSON".utf8).write(to: url)
        XCTAssertNil(ContextUsagePersistence(fileURL: url).record(for: "a"))
    }
}


extension ContextUsagePersistenceTests {
    @MainActor
    func testLateWriterCannotOverwriteOrReviveAnotherViewsState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContextUsagePersistence(fileURL: directory.appendingPathComponent("usage.json"))
        let old = store.beginOperation(sessionID: "a")
        let newer = store.beginOperation(sessionID: "a")
        let record = makeRecord("a", tokens: 730)
        XCTAssertTrue(try store.save(record, generation: newer))
        XCTAssertFalse(try store.save(makeRecord("a"), generation: old))
        XCTAssertEqual(store.record(for: "a"), record)
        try store.remove(sessionID: "a")
        XCTAssertFalse(try store.save(record, generation: newer))
        XCTAssertNil(store.record(for: "a"))
        // 另一会话开始请求不会令当前会话的接收版本失效。
        let next = store.beginOperation(sessionID: "a")
        store.beginOperation(sessionID: "b")
        XCTAssertTrue(try store.save(record, generation: next))
    }
}


extension ContextUsagePersistenceTests {
    @MainActor
    func testUnrelatedSessionConfigDoesNotRejectInFlightUsage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ContextUsagePersistence(fileURL: url)
        let epoch = store.configurationRevision(sessionID: "a", entryID: "entry-a", key: "a-config")
        _ = store.configurationRevision(sessionID: "b", entryID: "entry-b", key: "b-before")
        var state = ContextUsageState()
        let request = state.beginRequest()
        let initial = ContextUsageIdentity(entryID: "entry-a", modelID: "model-a", providerID: "provider-a", contextWindow: 1000, configRevision: epoch)
        try store.reconcile { sid, _, _ in sid == "a" ? "a-config" : "b-after" }
        let after = store.configurationRevision(sessionID: "a", entryID: "entry-a", key: "a-config")
        XCTAssertEqual(after, epoch)
        XCTAssertTrue(state.recordRequest(usedTokens: 570, initialEntryID: "entry-a", streamEntryID: "entry-a", streamConfigRevision: epoch, capturedIdentities: ["entry-a": initial], currentIdentity: initial, requestRevision: request))
        XCTAssertEqual(state.snapshot(matching: initial)?.percentage, 57)
        // 即使首个请求尚无保存记录，自己的配置往返也必须推进版本。
        try store.reconcile { _, _, _ in "a-changed" }
        try store.reconcile { _, _, _ in "a-config" }
        let changed = store.configurationRevision(sessionID: "a", entryID: "entry-a", key: "a-config")
        XCTAssertNotEqual(changed, epoch)
        let current = ContextUsageIdentity(entryID: "entry-a", modelID: "model-a", providerID: "provider-a", contextWindow: 1000, configRevision: changed)
        XCTAssertFalse(state.recordRequest(usedTokens: 999, initialEntryID: "entry-a", streamEntryID: "entry-a", streamConfigRevision: epoch, capturedIdentities: ["entry-a": initial], currentIdentity: current, requestRevision: request))
    }
}


extension ContextUsagePersistenceTests {
    @MainActor
    func testFallbackBindingChangeAllowedButProviderRoundTripRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ContextUsagePersistence(fileURL: url)
        let binding = store.configurationRevision(sessionID: "a", entryID: "fallback", key: "binding-a")
        let route = store.configurationRevision(sessionID: "a", entryID: "fallback", key: "endpoint-a", includesBinding: false)
        var state = ContextUsageState()
        let request = state.beginRequest()
        let captured = ContextUsageIdentity(entryID: "fallback", modelID: "model", providerID: "provider", contextWindow: 1000, configRevision: binding, routeConfigRevision: route)
        try store.reconcile { _, _, includesBinding in includesBinding ? "binding-b" : "endpoint-a" }
        let switched = store.configurationRevision(sessionID: "a", entryID: "fallback", key: "binding-b")
        let current = ContextUsageIdentity(entryID: "fallback", modelID: "model", providerID: "provider", contextWindow: 1000, configRevision: switched, routeConfigRevision: route)
        XCTAssertTrue(state.recordRequest(usedTokens: 420, initialEntryID: "primary", streamEntryID: "fallback", streamConfigRevision: switched, capturedIdentities: ["fallback": captured], currentIdentity: current, requestRevision: request))
        // 请求途中 endpoint A→B→A；即便最终字段相同，也不能把旧 provider 的结果当成新版本。
        try store.reconcile { _, _, includesBinding in includesBinding ? "binding-b" : "endpoint-b" }
        try store.reconcile { _, _, includesBinding in includesBinding ? "binding-b" : "endpoint-a" }
        let routeAfter = store.configurationRevision(sessionID: "a", entryID: "fallback", key: "endpoint-a", includesBinding: false)
        let changed = ContextUsageIdentity(entryID: "fallback", modelID: "model", providerID: "provider", contextWindow: 1000, configRevision: switched, routeConfigRevision: routeAfter)
        XCTAssertFalse(state.recordRequest(usedTokens: 999, initialEntryID: "primary", streamEntryID: "fallback", streamConfigRevision: switched, capturedIdentities: ["fallback": captured], currentIdentity: changed, requestRevision: request))
    }
}
