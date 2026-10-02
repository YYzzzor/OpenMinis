import Foundation
import XCTest
import WebKit
@testable import Minis

@MainActor
final class WebReadServiceTests: XCTestCase {
    func testModelResultJSONKeepsRequiredFieldsAndExplicitNulls() throws {
        let result = WebReadResult(
            url: "https://fixture.invalid/page",
            title: nil,
            retrievedAt: nil,
            readStatus: .failed,
            content: "",
            limitations: ["测试读取失败"],
            requestedURL: nil,
            sourceNote: nil,
            documentID: nil,
            continuation: nil,
            locateStatus: nil,
            resources: nil
        )

        let data = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["url", "title", "retrieved_at", "read_status", "content", "limitations"] {
            XCTAssertNotNil(object[key], "契约要求结果始终包含字段 \(key)")
        }
        XCTAssertTrue(object["title"] is NSNull, "没有可靠标题时必须编码为 JSON null")
        XCTAssertTrue(object["retrieved_at"] is NSNull, "没有响应时间时必须编码为 JSON null")
        XCTAssertEqual(object["read_status"] as? String, "failed")
        XCTAssertEqual(object["content"] as? String, "")
        XCTAssertEqual(object["limitations"] as? [String], ["测试读取失败"])
    }

    func testAgentToolDefinitionsSeparateAnonymousReadingFromBrowserInteraction() throws {
        let viewModel = AIChatViewModel()
        let tools = viewModel.makeAgentTools()
        let webRead = try XCTUnwrap(tools.first { $0.name == "web_read" })
        let browserUse = try XCTUnwrap(tools.first { $0.name == "browser_use" })

        XCTAssertEqual(Set(webRead.parameters.keys), Set([
            "tool_title", "url", "query_target", "render", "document_id", "offset", "limit"
        ]))
        XCTAssertEqual(webRead.required, ["tool_title"])
        XCTAssertEqual(webRead.parameters["url"]?.type.rawValue, AgentParamType.string.rawValue)
        XCTAssertEqual(webRead.parameters["query_target"]?.type.rawValue, AgentParamType.string.rawValue)
        XCTAssertEqual(webRead.parameters["render"]?.type.rawValue, AgentParamType.boolean.rawValue)
        XCTAssertEqual(webRead.parameters["document_id"]?.type.rawValue, AgentParamType.string.rawValue)
        XCTAssertEqual(webRead.parameters["offset"]?.type.rawValue, AgentParamType.integer.rawValue)
        XCTAssertEqual(webRead.parameters["limit"]?.type.rawValue, AgentParamType.integer.rawValue)
        XCTAssertTrue(webRead.description.contains("anonymously"))
        XCTAssertTrue(webRead.description.contains("does not use browser cookies"))
        XCTAssertTrue(browserUse.description.contains("For known HTTP(S) page text, use web_read first"))
        XCTAssertTrue(browserUse.description.contains("web_read is anonymous and cannot click, sign in, or use browser cookies"))
    }

    func testDocumentContinuationUsesUnicodeScalarOffsets() throws {
        let store = WebReadDocumentStore(configuration: Self.configuration())
        let scope = Self.scope()
        let content = "Aé e\u{301} 👩🏽‍💻 Z"
        let scalars = Array(content.unicodeScalars)
        let split = 7
        let document = store.save(
            content: content,
            scope: scope,
            url: "https://fixture.invalid/unicode",
            title: "Unicode",
            retrievedAt: "2026-10-02T00:00:00Z",
            limitations: [],
            requestedURL: nil,
            sourceNote: nil,
            resources: [],
            contentIsComplete: true
        )

        let first = try XCTUnwrap(store.read(id: document.id, scope: scope, offset: 0, limit: split))
        XCTAssertEqual(first.content, Self.string(from: scalars[0..<split]))
        XCTAssertEqual(
            Array(first.content.unicodeScalars).map(\.value),
            scalars[0..<split].map(\.value),
            "续读边界必须依据 Unicode scalar 精确切分"
        )
        XCTAssertEqual(first.start, 0)
        XCTAssertEqual(first.end, split)
        XCTAssertEqual(first.continuation.savedEnd, scalars.count)
        XCTAssertEqual(first.continuation.nextOffset, split)

        let second = try XCTUnwrap(store.read(id: document.id, scope: scope, offset: split, limit: 100))
        XCTAssertEqual(second.content, Self.string(from: scalars[split..<scalars.count]))
        XCTAssertEqual(
            Array(second.content.unicodeScalars).map(\.value),
            scalars[split..<scalars.count].map(\.value),
            "后续片段不得规范化或跳过组合字符与 emoji scalar"
        )
        XCTAssertEqual(second.start, split)
        XCTAssertEqual(second.end, scalars.count)
        XCTAssertNil(second.continuation.nextOffset)
        XCTAssertEqual(first.content + second.content, content)
    }

    func testFoundLocationAlwaysContainsWholeUnicodeTargetEvenWhenLimitIsSmaller() throws {
        let store = WebReadDocumentStore(configuration: Self.configuration(maximumResultBytes: 64))
        let scope = Self.scope()
        let target = "👩🏽‍💻"
        let content = "前言 Aé e\u{301} \(target) 尾声"
        let document = store.save(
            content: content,
            scope: scope,
            url: "https://fixture.invalid/unicode-target",
            title: nil,
            retrievedAt: nil,
            limitations: [],
            requestedURL: nil,
            sourceNote: nil,
            resources: [],
            contentIsComplete: true
        )

        let located = try XCTUnwrap(store.read(
            id: document.id,
            scope: scope,
            limit: 1,
            queryTarget: target
        ))
        XCTAssertEqual(located.locateStatus, .found)
        XCTAssertEqual(located.targetRangeLength, target.unicodeScalars.count)
        XCTAssertTrue(
            located.content.contains(target),
            "`found` may be reported only when the returned slice contains the full target"
        )
        XCTAssertEqual(located.content.unicodeScalars.count, located.end - located.start)
    }

    func testDocumentIDIsScopedToSessionRequestAndAnonymousIdentityRevision() throws {
        let store = WebReadDocumentStore(configuration: Self.configuration())
        let originalScope = Self.scope()
        let document = store.save(
            content: "SCOPE-MARKER-9A2C",
            scope: originalScope,
            url: "https://fixture.invalid/same-url",
            title: "Scoped",
            retrievedAt: "2026-10-02T00:00:00Z",
            limitations: [],
            requestedURL: nil,
            sourceNote: nil,
            resources: [],
            contentIsComplete: true
        )

        XCTAssertEqual(store.read(id: document.id, scope: originalScope)?.content, "SCOPE-MARKER-9A2C")
        XCTAssertNil(store.read(id: document.id, scope: Self.scope(sessionID: "other-session")))
        XCTAssertNil(store.read(id: document.id, scope: Self.scope(userRequestID: "next-request")))
        XCTAssertNil(store.read(id: document.id, scope: Self.scope(identityRevision: "anonymous-v2")))
    }

    func testMissDistinguishesCompleteSavedBodyFromKnownIncompleteBody() throws {
        let store = WebReadDocumentStore(configuration: Self.configuration())
        let scope = Self.scope()
        let complete = store.save(
            content: "Only the saved body",
            scope: scope,
            url: "https://fixture.invalid/complete",
            title: nil,
            retrievedAt: nil,
            limitations: [],
            requestedURL: nil,
            sourceNote: nil,
            resources: [],
            contentIsComplete: true
        )
        let incomplete = store.save(
            content: "Only the saved prefix",
            scope: scope,
            url: "https://fixture.invalid/partial",
            title: nil,
            retrievedAt: nil,
            limitations: ["正文尚未完整取得"],
            requestedURL: nil,
            sourceNote: nil,
            resources: [],
            contentIsComplete: false
        )

        XCTAssertEqual(
            store.read(id: complete.id, scope: scope, queryTarget: "NEVER-IN-SAVED-BODY")?.locateStatus,
            .notFoundInSavedContent
        )
        XCTAssertEqual(
            store.read(id: incomplete.id, scope: scope, queryTarget: "NEVER-IN-SAVED-BODY")?.locateStatus,
            .notCovered
        )
    }

    func testDocumentEvictedByByteBudgetCannotBeContinued() throws {
        let store = WebReadDocumentStore(configuration: Self.configuration(maximumCachedBytes: 4))
        let scope = Self.scope()
        let document = store.save(
            content: "more than four bytes",
            scope: scope,
            url: "https://fixture.invalid/evicted",
            title: nil,
            retrievedAt: nil,
            limitations: [],
            requestedURL: nil,
            sourceNote: nil,
            resources: [],
            contentIsComplete: false
        )

        XCTAssertFalse(store.contains(id: document.id, scope: scope))
        XCTAssertNil(store.read(id: document.id, scope: scope, offset: 0, limit: 1))
        XCTAssertEqual(store.totalCachedBytes, 0)
    }

    func testServiceFetchesOnceThenContinuesSavedDocumentWithoutRefetching() async throws {
        let responseBody = String(repeating: "S", count: 9_000)
        let transport = StubWebReadTransport(responses: [
            "/static": .init(body: responseBody)
        ])
        let config = Self.configuration(
            maximumResponseBytes: 20_000,
            maximumDocumentScalars: 10_000,
            maximumResultBytes: 12_000,
            maximumCachedBytes: 40_000
        )
        let renderer = StubWebReadRenderer()
        let service = makeService(transport: transport, renderer: renderer, configuration: config)
        let scope = Self.scope(sessionID: "service-session-\(UUID().uuidString)")
        let batchID = "service-batch-\(UUID().uuidString)"
        let initialDeadline = Date().addingTimeInterval(3)

        let initial = await service.read(
            request: WebReadRequest(url: "https://fixture.invalid/static"),
            scope: scope, callID: "initial-\(UUID().uuidString)", batchID: batchID,
            deadline: initialDeadline
        )
        let initialResult = try decode(initial)

        XCTAssertEqual(initialResult.readStatus, .partial)
        XCTAssertEqual(initialResult.content, String(repeating: "S", count: 8_000))
        let documentID = try XCTUnwrap(initialResult.documentID)
        let nextOffset = try XCTUnwrap(initialResult.continuation?.nextOffset)
        XCTAssertEqual(nextOffset, 8_000)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.deadline.timeIntervalSince(initialDeadline) ?? 0, 0, accuracy: 0.001)

        let continuation = await service.read(
            request: WebReadRequest(documentID: documentID, offset: nextOffset, limit: 1_000),
            scope: scope, callID: "continue-\(UUID().uuidString)", batchID: batchID,
            deadline: Date().addingTimeInterval(3)
        )
        let continuationResult = try decode(continuation)
        XCTAssertEqual(continuationResult.readStatus, .textReady)
        XCTAssertEqual(continuationResult.content, String(repeating: "S", count: 1_000))
        XCTAssertNil(continuationResult.continuation?.nextOffset)
        XCTAssertEqual(transport.requests.count, 1, "按 document_id 续读只能读取会话缓存，不得重复请求网络")
        XCTAssertEqual(renderer.renderCalls, 0)
    }

    func testServiceDeadlineReturnsJSONDiagnosticsAndAllowsFollowingRead() async throws {
        let transport = StubWebReadTransport(responses: [
            "/slow": .init(body: "SLOW-RESPONSE", delay: 0.18),
            "/after": .init(body: "AFTER-DEADLINE-READ")
        ])
        let config = Self.configuration(maximumResponseBytes: 2_000)
        let service = makeService(transport: transport, renderer: StubWebReadRenderer(), configuration: config)
        let scope = Self.scope(sessionID: "deadline-session-\(UUID().uuidString)")
        let batchID = "deadline-batch-\(UUID().uuidString)"

        let expired = await service.read(
            request: WebReadRequest(url: "https://fixture.invalid/slow"),
            scope: scope, callID: "deadline-\(UUID().uuidString)", batchID: batchID,
            deadline: Date().addingTimeInterval(0.04)
        )
        let expiredResult = try decode(expired)
        XCTAssertEqual(expiredResult.readStatus, .failed)
        XCTAssertEqual(expired.status, .failed)
        XCTAssertEqual(expiredResult.content, "")
        XCTAssertEqual(service.recentDiagnostics.last?.status, .failed)
        XCTAssertEqual(service.recentDiagnostics.last?.networkAttempts, 1)

        let following = await service.read(
            request: WebReadRequest(url: "https://fixture.invalid/after"),
            scope: scope, callID: "after-deadline-\(UUID().uuidString)", batchID: batchID,
            deadline: Date().addingTimeInterval(2)
        )
        XCTAssertEqual(try decode(following).content, "AFTER-DEADLINE-READ")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(service.recentDiagnostics.count, 2)
        XCTAssertEqual(service.recentDiagnostics.last?.status, .textReady)
    }

    func testServicePerCallCancellationDoesNotCancelBatchSibling() async throws {
        let transport = StubWebReadTransport(responses: [
            "/slow": .init(body: "SLOW-SIBLING", delay: 0.20),
            "/fast": .init(body: "FAST-SIBLING", delay: 0.04)
        ])
        let config = Self.configuration(maximumResponseBytes: 2_000, maximumConcurrentDownloads: 2)
        let service = makeService(transport: transport, renderer: StubWebReadRenderer(), configuration: config)
        let scope = Self.scope(sessionID: "sibling-session-\(UUID().uuidString)")
        let batchID = "sibling-batch-\(UUID().uuidString)"
        let slowCallID = "slow-call-\(UUID().uuidString)"
        let fastCallID = "fast-call-\(UUID().uuidString)"

        let slowTask = Task {
            await service.read(
                request: WebReadRequest(url: "https://fixture.invalid/slow"),
                scope: scope, callID: slowCallID, batchID: batchID,
                deadline: Date().addingTimeInterval(2)
            )
        }
        let fastTask = Task {
            await service.read(
                request: WebReadRequest(url: "https://fixture.invalid/fast"),
                scope: scope, callID: fastCallID, batchID: batchID,
                deadline: Date().addingTimeInterval(2)
            )
        }
        try await waitForRequestCount(2, transport: transport)
        service.cancel(callID: slowCallID, scope: scope, batchID: batchID)

        let cancelled = await slowTask.value
        let sibling = await fastTask.value
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(try decode(cancelled).readStatus, .cancelled)
        XCTAssertEqual(sibling.status, .textReady)
        XCTAssertEqual(try decode(sibling).content, "FAST-SIBLING")
        XCTAssertEqual(transport.cancelledCallIDs.count, 1, "单次取消只能通知对应的底层请求")
        let diagnostics = Dictionary(uniqueKeysWithValues: service.recentDiagnostics.map { ($0.callID, $0.status) })
        XCTAssertEqual(diagnostics[slowCallID], .cancelled)
        XCTAssertEqual(diagnostics[fastCallID], .textReady)
    }

    func testServiceResultClippingKeepsCompleteFoundTargetAndHonestRange() async throws {
        let target = "UNIQUE-TARGET-5A7C"
        let body = String(repeating: "A", count: 500) + target + String(repeating: "B", count: 2_000)
        let transport = StubWebReadTransport(responses: ["/target": .init(body: body)])
        let config = Self.configuration(
            maximumResponseBytes: 10_000,
            maximumDocumentScalars: 4_000,
            maximumResultBytes: 512,
            maximumCachedBytes: 10_000
        )
        let service = makeService(transport: transport, renderer: StubWebReadRenderer(), configuration: config)

        let outcome = await service.read(
            request: WebReadRequest(url: "https://fixture.invalid/target", queryTarget: target),
            scope: Self.scope(sessionID: "target-session-\(UUID().uuidString)"),
            callID: "target-call-\(UUID().uuidString)",
            batchID: "target-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decode(outcome)

        XCTAssertLessThanOrEqual(outcome.json.utf8.count, config.maximumResultBytes)
        XCTAssertEqual(result.locateStatus, .found)
        XCTAssertTrue(result.content.contains(target), "found 必须表示完整目标仍在最终裁剪后的片段中")
        XCTAssertEqual(result.continuation?.end, (result.continuation?.start ?? 0) + result.content.unicodeScalars.count)
    }

    func testServiceClassifiesRealFixtureResourcesAndAuthenticationResponses() async throws {
        let config = Self.configuration(
            maximumResponseBytes: 512_000,
            maximumDocumentScalars: 10_000,
            maximumResultBytes: 8_000,
            maximumCachedBytes: 40_000
        )
        let service = WebReadService(
            transport: URLSessionWebReadTransport(),
            renderer: WebReadRenderer(),
            documentStore: WebReadDocumentStore(configuration: config),
            configuration: config
        )
        let scope = Self.scope(sessionID: "fixture-service-session-\(UUID().uuidString)")
        let resourceCases: [(path: String, type: String)] = [
            ("pdf/text", "application/pdf"),
            ("pdf/corrupt", "application/pdf"),
            ("pdf/encrypted", "application/pdf"),
            ("pdf/wrong-mime", "application/pdf"),
            ("disconnect", "application/pdf"),
            ("images/direct.png", "image/png"),
            ("images/direct.jpg", "image/jpeg")
        ]

        for testCase in resourceCases {
            let url = try fixtureURL(testCase.path)
            let outcome = await service.read(
                request: WebReadRequest(url: url.absoluteString),
                scope: scope,
                callID: "fixture-resource-\(UUID().uuidString)",
                batchID: "fixture-resource-batch-\(UUID().uuidString)",
                deadline: Date().addingTimeInterval(6)
            )
            let result = try decode(outcome)
            let resource = try XCTUnwrap(result.resources?.first, "\(testCase.path) 应返回资源说明")

            XCTAssertEqual(result.readStatus, .resourceOnly, testCase.path)
            XCTAssertEqual(result.content, "", "资源元数据不得伪装为已读取正文：\(testCase.path)")
            XCTAssertEqual(resource.url, url.absoluteString)
            XCTAssertEqual(resource.type, testCase.type)
            XCTAssertEqual(resource.readStatus, "not_read")
        }

        for path in ["auth/private", "auth/basic", "auth/403"] {
            let url = try fixtureURL(path)
            let outcome = await service.read(
                request: WebReadRequest(url: url.absoluteString),
                scope: scope,
                callID: "fixture-auth-\(UUID().uuidString)",
                batchID: "fixture-auth-batch-\(UUID().uuidString)",
                deadline: Date().addingTimeInterval(6)
            )
            let result = try decode(outcome)

            XCTAssertEqual(result.readStatus, .restricted, path)
            XCTAssertEqual(outcome.status, .restricted, path)
            XCTAssertEqual(result.content, "", "受限响应不能带出响应正文：\(path)")
            XCTAssertFalse(result.limitations.isEmpty)
        }
    }

    func testServiceUsesDeclaredMarkdownAlternativeAndExplainsSourceScope() async throws {
        let config = Self.configuration(
            totalTimeout: 8,
            maximumResponseBytes: 256_000,
            maximumDocumentScalars: 20_000,
            maximumResultBytes: 8_000,
            maximumCachedBytes: 64_000
        )
        let renderer = StubWebReadRenderer()
        let service = WebReadService(
            transport: URLSessionWebReadTransport(),
            renderer: renderer,
            documentStore: WebReadDocumentStore(configuration: config),
            configuration: config
        )
        let requestedURL = try fixtureURL("alternate/html")
        let alternateURL = try fixtureURL("long/public.md")
        let scope = Self.scope(sessionID: "alternate-session-\(UUID().uuidString)")
        let outcome = await service.read(
            request: WebReadRequest(
                url: requestedURL.absoluteString,
                queryTarget: "MARKDOWN-EXCERPT-END-4C2D"
            ),
            scope: scope,
            callID: "alternate-call-\(UUID().uuidString)",
            batchID: "alternate-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(8)
        )
        let result = try decode(outcome)

        XCTAssertEqual(result.readStatus, .textReady)
        XCTAssertEqual(result.url, alternateURL.absoluteString)
        XCTAssertEqual(result.requestedURL, requestedURL.absoluteString)
        XCTAssertTrue(result.content.contains("MARKDOWN-EXCERPT-END-4C2D"))
        XCTAssertFalse(result.content.contains("PRIMARY-HTML-MARKER-31AF"))
        XCTAssertTrue(result.sourceNote?.contains("公开备用正文") == true)
        XCTAssertTrue(result.sourceNote?.contains("范围以该备用来源为准") == true)
        XCTAssertEqual(service.recentDiagnostics.last?.networkAttempts, 2)
        XCTAssertFalse(service.recentDiagnostics.last?.rendererUsed ?? true)
        XCTAssertEqual(renderer.renderCalls, 0)
    }

    func testServiceRendersDelayedDynamicTargetAfterStaticMiss() async throws {
        let config = Self.configuration(
            totalTimeout: 8,
            maximumResponseBytes: 256_000,
            maximumDocumentScalars: 20_000,
            maximumResultBytes: 8_000,
            maximumCachedBytes: 64_000
        )
        let service = WebReadService(
            transport: URLSessionWebReadTransport(),
            renderer: WebReadRenderer(),
            documentStore: WebReadDocumentStore(configuration: config),
            configuration: config
        )
        let target = "TARGETED-CONTINUATION-8E3"
        let outcome = await service.read(
            request: WebReadRequest(url: try fixtureURL("partial").absoluteString, queryTarget: target),
            scope: Self.scope(sessionID: "dynamic-service-\(UUID().uuidString)"),
            callID: "dynamic-service-call-\(UUID().uuidString)",
            batchID: "dynamic-service-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(8)
        )
        let result = try decode(outcome)

        XCTAssertEqual(result.readStatus, .textReady)
        XCTAssertTrue(result.content.contains("EARLY-PARTIAL-BODY-19E3"))
        XCTAssertTrue(result.content.contains(target))
        XCTAssertEqual(result.locateStatus, .found)
        XCTAssertTrue(result.sourceNote?.contains("独立匿名 WebKit 渲染") == true)
        XCTAssertTrue(service.recentDiagnostics.last?.rendererUsed == true)
    }

    func testServiceDoesNotCallLoadingPlaceholderCompleteWithoutTarget() async throws {
        let config = Self.configuration(
            totalTimeout: 8,
            maximumResponseBytes: 256_000,
            maximumDocumentScalars: 20_000,
            maximumResultBytes: 8_000,
            maximumCachedBytes: 64_000
        )
        let service = WebReadService(
            transport: URLSessionWebReadTransport(),
            renderer: WebReadRenderer(),
            documentStore: WebReadDocumentStore(configuration: config),
            configuration: config
        )
        let outcome = await service.read(
            request: WebReadRequest(url: try fixtureURL("partial").absoluteString),
            scope: Self.scope(sessionID: "loading-state-\(UUID().uuidString)"),
            callID: "loading-state-call-\(UUID().uuidString)",
            batchID: "loading-state-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(8)
        )
        let result = try decode(outcome)

        let renderedCompleteBody = result.readStatus == .textReady
            && result.content.contains("TARGETED-CONTINUATION-8E3")
        let honestPartialBody = result.readStatus == .partial
            && result.content.contains("EARLY-PARTIAL-BODY-19E3")
            && result.limitations.contains {
                $0.localizedCaseInsensitiveContains("加载")
                    || $0.localizedCaseInsensitiveContains("不完整")
            }
        XCTAssertTrue(
            renderedCompleteBody || honestPartialBody,
            "独立 Loading 占位符不能以无缺口的 text_ready 返回；应取得动态正文或说明结果仍不完整。"
        )
    }

    func testServiceDoesNotRenderAnArticleThatDiscussesLoading() async throws {
        let html = "<main><h1>Notes on interface state</h1><p>The <b>Loading</b> state is documented here as one part of the article, not as a page placeholder.</p></main>"
        let transport = StubWebReadTransport(responses: [
            "/loading-article": .init(body: html, mimeType: "text/html; charset=utf-8")
        ])
        let renderer = StubWebReadRenderer()
        let config = Self.configuration(maximumResponseBytes: 4_000, maximumDocumentScalars: 2_000)
        let service = makeService(transport: transport, renderer: renderer, configuration: config)

        let outcome = await service.read(
            request: WebReadRequest(url: "https://fixture.invalid/loading-article"),
            scope: Self.scope(sessionID: "loading-article-\(UUID().uuidString)"),
            callID: "loading-article-call-\(UUID().uuidString)",
            batchID: "loading-article-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decode(outcome)

        XCTAssertEqual(result.readStatus, .textReady)
        XCTAssertFalse(result.limitations.contains { $0.localizedCaseInsensitiveContains("加载") })
        XCTAssertEqual(renderer.renderCalls, 0)
    }

    func testServiceKeepsTextBodyPartialWhileAnEmptyProgressIndicatorRemains() async throws {
        let config = Self.configuration(
            totalTimeout: 8,
            maximumResponseBytes: 256_000,
            maximumDocumentScalars: 20_000,
            maximumResultBytes: 8_000,
            maximumCachedBytes: 64_000
        )
        let service = WebReadService(
            transport: URLSessionWebReadTransport(),
            renderer: WebReadRenderer(),
            documentStore: WebReadDocumentStore(configuration: config),
            configuration: config
        )
        let url = try fixtureURL("busy-empty")
        let outcome = await service.read(
            request: WebReadRequest(url: url.absoluteString),
            scope: Self.scope(sessionID: "busy-empty-\(UUID().uuidString)"),
            callID: "busy-empty-call-\(UUID().uuidString)",
            batchID: "busy-empty-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(8)
        )
        let result = try decode(outcome)

        XCTAssertEqual(result.readStatus, .partial)
        XCTAssertTrue(result.content.contains("BUSY-BODY-READABLE-4A21"))
        XCTAssertTrue(result.limitations.contains { $0.localizedCaseInsensitiveContains("加载状态") })
        XCTAssertTrue(service.recentDiagnostics.last?.rendererUsed == true)
    }

    func testServiceTreatsRendererReportedBusyIndicatorAsPartial() async throws {
        let url = URL(string: "https://fixture.invalid/renderer-busy")!
        let html = "<main><h1>Stable body heading</h1><p>Readable content remains visible while a separate busy indicator is reported by WebKit.</p></main>"
        let transport = StubWebReadTransport(responses: [
            "/renderer-busy": .init(body: html, mimeType: "text/html; charset=utf-8")
        ])
        let renderedPage = WebReadRenderedPage(
            title: nil, finalURL: url, html: html, retrievedAt: Date(),
            htmlWasTruncated: false, targetFound: nil, targetWaitExpired: false,
            hasLoadingIndicator: true
        )
        let renderer = StubWebReadRenderer(renderedPage: renderedPage)
        let config = Self.configuration(maximumResponseBytes: 4_000, maximumDocumentScalars: 2_000)
        let service = makeService(transport: transport, renderer: renderer, configuration: config)

        let outcome = await service.read(
            request: WebReadRequest(url: url.absoluteString, renderRequested: true),
            scope: Self.scope(sessionID: "renderer-busy-\(UUID().uuidString)"),
            callID: "renderer-busy-call-\(UUID().uuidString)",
            batchID: "renderer-busy-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decode(outcome)

        XCTAssertEqual(result.readStatus, .partial)
        XCTAssertTrue(result.content.contains("Readable content remains visible"))
        XCTAssertTrue(result.limitations.contains { $0.localizedCaseInsensitiveContains("匿名渲染等待结束") })
        XCTAssertEqual(renderer.renderCalls, 1)
    }

    func testServiceReportsFinalRedirectDocumentWithoutStaleContent() async throws {
        let config = Self.configuration(
            totalTimeout: 8,
            maximumResponseBytes: 256_000,
            maximumDocumentScalars: 20_000,
            maximumResultBytes: 8_000,
            maximumCachedBytes: 64_000
        )
        let renderer = StubWebReadRenderer()
        let service = WebReadService(
            transport: URLSessionWebReadTransport(),
            renderer: renderer,
            documentStore: WebReadDocumentStore(configuration: config),
            configuration: config
        )
        let oldURL = try fixtureURL("revision/old")
        let newURL = try fixtureURL("revision/new")
        let outcome = await service.read(
            request: WebReadRequest(url: oldURL.absoluteString),
            scope: Self.scope(sessionID: "redirect-session-\(UUID().uuidString)"),
            callID: "redirect-call-\(UUID().uuidString)",
            batchID: "redirect-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(8)
        )
        let result = try decode(outcome)

        XCTAssertEqual(result.readStatus, .textReady)
        XCTAssertEqual(result.url, newURL.absoluteString)
        XCTAssertEqual(result.requestedURL, oldURL.absoluteString)
        XCTAssertEqual(result.title, "New document")
        XCTAssertTrue(result.content.contains("NEW-DOCUMENT-ONLY"))
        XCTAssertTrue(result.content.contains("FINAL-DOM-MARKER-7C42"))
        XCTAssertFalse(result.content.contains("OLD-DOCUMENT"))
        XCTAssertEqual(renderer.renderCalls, 0)
    }

    func testServiceResolvesRelativeImageAndDoesNotTreatAltAsImageContent() async throws {
        let config = Self.configuration(
            totalTimeout: 8,
            maximumResponseBytes: 256_000,
            maximumDocumentScalars: 20_000,
            maximumResultBytes: 8_000,
            maximumCachedBytes: 64_000
        )
        let renderer = StubWebReadRenderer()
        let service = WebReadService(
            transport: URLSessionWebReadTransport(),
            renderer: renderer,
            documentStore: WebReadDocumentStore(configuration: config),
            configuration: config
        )

        let relativePageURL = try fixtureURL("images/relative/page.html")
        let relativeImageURL = try fixtureURL("images/assets/price-table.png")
        let relativeOutcome = await service.read(
            request: WebReadRequest(url: relativePageURL.absoluteString),
            scope: Self.scope(sessionID: "relative-image-\(UUID().uuidString)"),
            callID: "relative-image-call-\(UUID().uuidString)",
            batchID: "relative-image-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(8)
        )
        let relativeResult = try decode(relativeOutcome)
        let relativeResource = try XCTUnwrap(relativeResult.resources?.first)
        XCTAssertEqual(
            relativeResource.url,
            relativeImageURL.absoluteString
        )
        XCTAssertEqual(relativeResource.type, "image/png")
        XCTAssertEqual(relativeResource.readStatus, "not_read")
        XCTAssertTrue(relativeResult.content.contains("IMG-RELATIVE-13B8"))

        let misleadingURL = try fixtureURL("images/misleading-alt.html")
        let misleadingOutcome = await service.read(
            request: WebReadRequest(url: misleadingURL.absoluteString),
            scope: Self.scope(sessionID: "misleading-alt-\(UUID().uuidString)"),
            callID: "misleading-alt-call-\(UUID().uuidString)",
            batchID: "misleading-alt-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(8)
        )
        let misleadingResult = try decode(misleadingOutcome)
        let misleadingResource = try XCTUnwrap(misleadingResult.resources?.first)
        let misleadingImageURL = try fixtureURL("images/assets/misleading-alt.png")
        XCTAssertEqual(misleadingResource.url, misleadingImageURL.absoluteString)
        XCTAssertEqual(misleadingResource.readStatus, "not_read")
        XCTAssertTrue(misleadingResult.content.contains("Image-only values"))
        XCTAssertFalse(misleadingResult.content.contains("Monthly report"), "alt 文本不能伪装成已读取的图像内容")
        XCTAssertEqual(renderer.renderCalls, 0)
    }

    func testServiceTreatsHTTP200LoginFormsAndLoginRedirectAsRestricted() async throws {
        let config = Self.configuration(maximumResponseBytes: 256_000)
        let renderer = StubWebReadRenderer()
        let service = WebReadService(
            transport: URLSessionWebReadTransport(),
            renderer: renderer,
            documentStore: WebReadDocumentStore(configuration: config),
            configuration: config
        )
        let cases: [(requestedPath: String, finalPath: String)] = [
            ("auth/form", "auth/form"),
            ("auth/redirect", "auth/form")
        ]

        for testCase in cases {
            let requestedURL = try fixtureURL(testCase.requestedPath)
            let expectedFinalURL = try fixtureURL(testCase.finalPath)
            let outcome = await service.read(
                request: WebReadRequest(url: requestedURL.absoluteString),
                scope: Self.scope(sessionID: "login-form-\(UUID().uuidString)"),
                callID: "login-form-call-\(UUID().uuidString)",
                batchID: "login-form-batch-\(UUID().uuidString)",
                deadline: Date().addingTimeInterval(8)
            )
            let result = try decode(outcome)

            XCTAssertEqual(result.readStatus, .restricted, testCase.requestedPath)
            XCTAssertEqual(outcome.status, .restricted, testCase.requestedPath)
            XCTAssertEqual(result.url, expectedFinalURL.absoluteString, testCase.requestedPath)
            XCTAssertEqual(result.content, "", testCase.requestedPath)
            XCTAssertFalse(result.limitations.isEmpty, testCase.requestedPath)
        }
        XCTAssertEqual(renderer.renderCalls, 0)
    }

    func testAnonymousHTTPAndWebKitReadsPreserveExistingBrowserTabState() async throws {
        let pool = BrowserTabPool()
        pool.setUserAgentProfile(.desktopSafari, persist: false)
        let createdTab = pool.newTab()
        let tabID = try XCTUnwrap(createdTab.tabId)
        guard let manager = pool.tabs.first(where: { $0.id == tabID })?.manager else {
            return XCTFail("真实 BrowserTabPool 未保留新建标签")
        }
        defer { _ = pool.closeTab(id: tabID) }
        manager.setViewport(
            width: 1024,
            height: 768,
            profile: .desktopSafari,
            customUA: pool.resolvedUserAgentString()
        )

        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1",
            .path: "/",
            .name: "fixture_auth",
            .value: "TEST-COOKIE-7F91",
            .version: 0
        ]))
        let privatePageURL = try fixtureURL("auth/browser-state")
        let store = WKWebsiteDataStore.default().httpCookieStore

        try await withSyntheticCookie(cookie, in: store) {
            manager.loadURL(privatePageURL.absoluteString)
            try await waitForBrowserDocument(manager, at: privatePageURL)
            let loginMarker = try await manager.webView.evaluateJavaScript("document.querySelector('#private-marker')?.textContent") as? String
            XCTAssertEqual(loginMarker, "PRIVATE-MARKER-A7C4")

            let inputValue = "SYNTHETIC-USER-INPUT-71B9"
            let setupResult = try await manager.webView.evaluateJavaScript("""
                (() => {
                    const input = document.querySelector('#note');
                    input.value = '\(inputValue)';
                    input.dispatchEvent(new Event('input', { bubbles: true }));
                    document.querySelector('#apply').click();
                    window.scrollTo(0, 1400);
                    return true;
                })()
                """) as? Bool
            XCTAssertEqual(setupResult, true)
            try await Task.sleep(nanoseconds: 80_000_000)

            let initialState = try await browserStateSnapshot(manager.webView)
            XCTAssertTrue(initialState.contains(privatePageURL.absoluteString))
            XCTAssertTrue(initialState.contains(inputValue))
            XCTAssertTrue(initialState.contains("已应用：\(inputValue)"))
            XCTAssertTrue(initialState.contains("1400"), "测试页应保留可观察的非零滚动位置")
            XCTAssertTrue(initialState.contains("Macintosh"), "标签应保留桌面 Safari UA")
            XCTAssertEqual(manager.currentViewport.width, 1024)
            XCTAssertEqual(manager.currentViewport.height, 768)

            let config = Self.configuration(
                totalTimeout: 8,
                maximumResponseBytes: 256_000,
                maximumDocumentScalars: 20_000,
                maximumResultBytes: 8_000,
                maximumCachedBytes: 64_000,
                maximumConcurrentDownloads: 3,
                renderTargetWaitTimeout: 4
            )
            let service = WebReadService(
                transport: URLSessionWebReadTransport(),
                renderer: WebReadRenderer(),
                documentStore: WebReadDocumentStore(configuration: config),
                configuration: config
            )
            let sessionID = "browser-state-\(UUID().uuidString)"
            let slowURL = try fixtureURL("slow-main")
            let partialURL = try fixtureURL("partial")
            let httpTask = Task {
                await service.read(
                    request: WebReadRequest(url: slowURL.absoluteString),
                    scope: Self.scope(sessionID: sessionID, userRequestID: "slow-http"),
                    callID: "browser-state-http-\(UUID().uuidString)",
                    batchID: "browser-state-http-batch-\(UUID().uuidString)",
                    deadline: Date().addingTimeInterval(8)
                )
            }
            let dynamicTask = Task {
                await service.read(
                    request: WebReadRequest(
                        url: partialURL.absoluteString,
                        queryTarget: "TARGETED-CONTINUATION-8E3"
                    ),
                    scope: Self.scope(sessionID: sessionID, userRequestID: "dynamic-render"),
                    callID: "browser-state-render-\(UUID().uuidString)",
                    batchID: "browser-state-render-batch-\(UUID().uuidString)",
                    deadline: Date().addingTimeInterval(8)
                )
            }

            try await waitForAnonymousRenderer(timeout: 5)
            let duringState = try await browserStateSnapshot(manager.webView)
            XCTAssertEqual(duringState, initialState, "匿名 HTTP/WebKit 读取进行时不得改变既有浏览器标签状态")
            XCTAssertTrue(pool.tabs.first(where: { $0.id == tabID })?.manager === manager)

            let httpOutcome = await httpTask.value
            let dynamicOutcome = await dynamicTask.value
            let httpResult = try decode(httpOutcome)
            let dynamicResult = try decode(dynamicOutcome)
            XCTAssertEqual(httpResult.readStatus, .textReady)
            XCTAssertTrue(httpResult.content.contains("SLOW-MAIN-MARKER-3D26"))
            XCTAssertEqual(dynamicResult.readStatus, .textReady)
            XCTAssertTrue(dynamicResult.content.contains("TARGETED-CONTINUATION-8E3"))

            let finalState = try await browserStateSnapshot(manager.webView)
            XCTAssertEqual(finalState, initialState, "匿名 HTTP/WK 读取结束后不得改变 URL、DOM、输入、滚动、UA 或 viewport")
            XCTAssertEqual(manager.currentURL, privatePageURL.absoluteString)
            XCTAssertEqual(manager.currentViewport.width, 1024)
            XCTAssertEqual(manager.currentViewport.height, 768)
            XCTAssertEqual(pool.tabs.count, 1)

            let probeStarted = try await manager.webView.evaluateJavaScript("""
                (() => {
                    window.__webReadAuthProbe = 'pending';
                    fetch('/auth/private', { cache: 'no-store', credentials: 'include' })
                        .then(response => response.text())
                        .then(text => { window.__webReadAuthProbe = text; })
                        .catch(() => { window.__webReadAuthProbe = 'probe-failed'; });
                    return true;
                })()
                """) as? Bool
            XCTAssertEqual(probeStarted, true)
            var privateProbe = "pending"
            for _ in 0..<50 {
                privateProbe = try await manager.webView.evaluateJavaScript("window.__webReadAuthProbe") as? String ?? ""
                if privateProbe != "pending" { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(privateProbe, "PRIVATE-MARKER-A7C4", "原浏览器必须继续携带合成登录 Cookie")
            XCTAssertEqual(BrowserTabPoolRegistry.shared.anonymousWebReadRendererCount, 0)
        }
    }

    func testWebReadServiceDoesNotClearSyntheticTakeoverStateOnAnyOutcome() async throws {
        let transport = StubWebReadTransport(responses: [
            "/success": .init(body: "TAKEOVER-SUCCESS-3C81"),
            "/cancel": .init(body: "TAKEOVER-CANCEL-4D92", delay: 0.20),
            "/timeout": .init(body: "TAKEOVER-TIMEOUT-5EA3", delay: 0.20)
        ])
        let config = Self.configuration(maximumResponseBytes: 2_000)
        let service = makeService(transport: transport, renderer: StubWebReadRenderer(), configuration: config)
        let viewModel = AIChatViewModel()
        viewModel.browserTakeoverActive = true
        defer { viewModel.browserTakeoverActive = false }
        let scope = Self.scope(sessionID: "synthetic-takeover-\(UUID().uuidString)")
        let batchID = "synthetic-takeover-batch-\(UUID().uuidString)"

        let success = await service.read(
            request: WebReadRequest(url: "https://fixture.invalid/success"),
            scope: scope,
            callID: "takeover-success-\(UUID().uuidString)",
            batchID: batchID,
            deadline: Date().addingTimeInterval(2)
        )
        XCTAssertEqual(success.status, .textReady)
        XCTAssertTrue(viewModel.browserTakeoverActive)

        let cancelCallID = "takeover-cancel-\(UUID().uuidString)"
        let cancellationTask = Task {
            await service.read(
                request: WebReadRequest(url: "https://fixture.invalid/cancel"),
                scope: scope,
                callID: cancelCallID,
                batchID: batchID,
                deadline: Date().addingTimeInterval(2)
            )
        }
        try await waitForRequestCount(2, transport: transport)
        service.cancel(callID: cancelCallID, scope: scope, batchID: batchID)
        let cancellation = await cancellationTask.value
        XCTAssertEqual(cancellation.status, .cancelled)
        XCTAssertTrue(viewModel.browserTakeoverActive)

        let timeout = await service.read(
            request: WebReadRequest(url: "https://fixture.invalid/timeout"),
            scope: scope,
            callID: "takeover-timeout-\(UUID().uuidString)",
            batchID: batchID,
            deadline: Date().addingTimeInterval(0.04)
        )
        XCTAssertEqual(timeout.status, .failed)
        XCTAssertTrue(viewModel.browserTakeoverActive)
    }

    func testServiceDeadlineAfterPartialHTTPBodyPreservesContentWithoutNewContinuation() async throws {
        let transport = StubWebReadTransport(responses: [
            "/partial-before-render": .init(
                body: "HTTP-PARTIAL-BODY-3A4C",
                bodyWasTruncated: true
            )
        ])
        let config = Self.configuration(
            maximumResponseBytes: 2_000,
            maximumDocumentScalars: 1_000,
            maximumResultBytes: 1_000
        )
        let renderer = DeadlineWebReadRenderer()
        let service = makeService(transport: transport, renderer: renderer, configuration: config)
        let deadline = Date().addingTimeInterval(0.35)

        let outcome = await service.read(
            request: WebReadRequest(
                url: "https://fixture.invalid/partial-before-render",
                queryTarget: "TARGET-ONLY-IN-RENDERED-PAGE"
            ),
            scope: Self.scope(sessionID: "partial-render-deadline-\(UUID().uuidString)"),
            callID: "partial-render-timeout-\(UUID().uuidString)",
            batchID: "partial-render-timeout-batch-\(UUID().uuidString)",
            deadline: deadline
        )
        let result = try decode(outcome)

        XCTAssertEqual(renderer.renderCalls, 1, "静态正文未包含目标时应进入后续渲染")
        XCTAssertEqual(result.readStatus, .partial)
        XCTAssertEqual(result.content, "HTTP-PARTIAL-BODY-3A4C", "渲染超时应保留截止前已取得的 HTTP 正文")
        XCTAssertTrue(result.limitations.contains { $0.contains("截止时间") || $0.contains("超时") })
        XCTAssertNil(result.documentID, "超时回退不得创建新的可续读文档编号")
        XCTAssertNil(result.continuation, "未完整保存的超时正文不得承诺续读偏移")
    }

    func testAgentToolDispatchReturnsWebReadOutcomeAsJSON() async throws {
        let response = "AGENT-DISPATCH-MARKER-9D21"
        let transport = StubWebReadTransport(responses: ["/agent": .init(body: response)])
        let config = Self.configuration(maximumResponseBytes: 2_000)
        let service = makeService(transport: transport, renderer: StubWebReadRenderer(), configuration: config)
        let viewModel = AIChatViewModel()
        let syntheticSessionID = "web-read-agent-test-\(UUID().uuidString)"
        viewModel.sessionId = syntheticSessionID
        defer { viewModel.sessionId = nil }

        let toolUseID = "web-read-agent-call-\(UUID().uuidString)"
        viewModel.messages = [ChatMessage(
            role: .assistant,
            content: "",
            blocks: [AssistantBlock(
                kind: .browserTool(action: "web_read"), content: "", toolUseId: toolUseID
            )]
        )]
        viewModel.webReadService = service
        let toolUse = AIChatViewModel.StreamResult.ToolEntry(
            id: toolUseID,
            name: "web_read",
            args: ["tool_title": "Read public fixture", "url": "https://fixture.invalid/agent"],
            blockIdx: 0,
            metadata: nil,
            inputChunkRing: []
        )
        let scope = Self.scope(sessionID: syntheticSessionID, userRequestID: "agent-request-\(UUID().uuidString)")

        let outcome = await viewModel.executeSingleToolUse(
            tu: toolUse,
            msgIdx: 0,
            tools: viewModel.makeAgentTools(),
            batchBudget: AIChatViewModel.BatchImageBudget(initial: 0),
            webReadBatchID: "agent-batch-\(UUID().uuidString)",
            webReadScope: scope,
            webReadDeadline: Date().addingTimeInterval(2)
        )

        guard case let .toolResult(id, name, content, isError, _, _, _, _) = outcome.resultPart else {
            return XCTFail("web_read 派发必须生成标准 tool_result")
        }
        XCTAssertEqual(id, toolUseID)
        XCTAssertEqual(name, "web_read")
        XCTAssertFalse(isError)
        let resultObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(resultObject["read_status"] as? String, "text_ready")
        XCTAssertEqual(resultObject["content"] as? String, response)
        XCTAssertEqual(viewModel.messages[0].blocks[0].content, content)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRendererWaitsForVisibleDynamicTargetInsteadOfScriptText() async throws {
        let pageURL = try fixtureURL("partial")
        let renderer = WebReadRenderer()
        let callID = "web-read-render-\(UUID().uuidString)"
        let target = "TARGETED-CONTINUATION-8E3"
        let startedAt = Date()
        let page = try await renderWithin(
            4,
            renderer: renderer,
            url: pageURL,
            callID: callID,
            deadline: Date().addingTimeInterval(4),
            queryTarget: target,
            waitForTarget: true
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertTrue(page.html.contains("EARLY-PARTIAL-BODY-19E3"))
        XCTAssertTrue(page.html.contains(target), "渲染结果必须包含脚本稍后写入页面的目标")
        XCTAssertEqual(page.targetFound, true)
        XCTAssertEqual(page.targetWaitExpired, false)
        XCTAssertGreaterThanOrEqual(
            elapsed,
            0.7,
            "目标字符串在 script 字面量中出现时，不能据此提前结束读取"
        )
        XCTAssertLessThan(elapsed, 4)
    }

    func testRendererTargetWaitNearDeadlineFinishesAndReleasesItsSlot() async throws {
        let pageURL = try fixtureURL("partial")
        let quickPageURL = try fixtureURL("static")
        let renderer = WebReadRenderer()
        let callID = "web-read-render-deadline-\(UUID().uuidString)"
        let startedAt = Date()
        let partial = try await renderWithin(
            3,
            renderer: renderer,
            url: pageURL,
            callID: callID,
            deadline: Date().addingTimeInterval(1.2),
            queryTarget: "TARGET-THAT-NEVER-APPEARS-73D1",
            waitForTarget: true
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertTrue(partial.html.contains("EARLY-PARTIAL-BODY-19E3"))
        XCTAssertEqual(partial.targetFound, false)
        XCTAssertEqual(partial.targetWaitExpired, true)
        XCTAssertLessThan(elapsed, 2.8, "目标等待必须受总截止时间限制")

        let followingCall = try await renderWithin(
            4,
            renderer: renderer,
            url: quickPageURL,
            callID: "web-read-render-after-deadline-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(4),
            queryTarget: nil,
            waitForTarget: false
        )
        XCTAssertTrue(followingCall.html.contains("STATIC-READY-MARKER-4E71"))
    }

    func testRendererReportsHTTP403AsRestricted() async throws {
        let renderer = WebReadRenderer()
        do {
            _ = try await renderWithin(
                4,
                renderer: renderer,
                url: try fixtureURL("auth/403"),
                callID: "web-read-render-403-\(UUID().uuidString)",
                deadline: Date().addingTimeInterval(4),
                queryTarget: nil,
                waitForTarget: false
            )
            XCTFail("HTTP 403 必须标记为匿名访问受限")
        } catch WebReadFailure.restricted {
        } catch {
            XCTFail("HTTP 403 返回了错误分类：\(error)")
        }
    }

    func testRendererDoesNotReadSyntheticCookieFromDefaultWebsiteDataStore() async throws {
        let pageURL = try fixtureURL("auth/private")
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        let syntheticCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1",
            .path: "/",
            .name: "fixture_auth",
            .value: "TEST-COOKIE-7F91",
            .version: 0
        ]))
        await withTemporaryCookie(syntheticCookie, in: cookieStore) {
            let renderer = WebReadRenderer()
            do {
                _ = try await renderWithin(
                    4,
                    renderer: renderer,
                    url: pageURL,
                    callID: "web-read-render-cookie-isolation-\(UUID().uuidString)",
                    deadline: Date().addingTimeInterval(4),
                    queryTarget: nil,
                    waitForTarget: false
                )
                XCTFail("独立 WebKit 读取不得使用 default data store 中的合成登录 Cookie")
            } catch WebReadFailure.restricted {
            } catch {
                XCTFail("带有 default store Cookie 时 /auth/private 应保持受限，实际错误：\(error)")
            }

            let cookiesAfterRead = await cookies(in: cookieStore)
            XCTAssertTrue(
                cookiesAfterRead.contains {
                    $0.name == syntheticCookie.name
                        && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "127.0.0.1"
                        && $0.path == syntheticCookie.path
                        && $0.value == syntheticCookie.value
                },
                "匿名读取结束后，default store 中原有的回环合成 Cookie 仍应存在"
            )
        }
    }

    func testRendererRejectsDeclaredOversizedMainDocument() async throws {
        let renderer = WebReadRenderer(maximumMainResponseBytes: 64)
        do {
            _ = try await renderWithin(
                4,
                renderer: renderer,
                url: try fixtureURL("static"),
                callID: "web-read-render-size-\(UUID().uuidString)",
                deadline: Date().addingTimeInterval(4),
                queryTarget: nil,
                waitForTarget: false
            )
            XCTFail("超出配置上限的已声明主文档不得进入 DOM 读取")
        } catch WebReadFailure.responseTooLarge {
        } catch {
            XCTFail("超限主文档返回了错误分类：\(error)")
        }
    }

    func testHTMLExtractorRemovesExecutableChromeAndPreservesCodeAndTableStructure() throws {
        let html = """
        <!doctype html>
        <html><head><title>Price reference</title>
        <style>STYLE-NOISE-78D1</style>
        <script>const hidden = "SCRIPT-NOISE-28A6";</script>
        </head><body>
        <nav>NAV-NOISE-C9B4</nav>
        <main><h1>Plans</h1>
        <p>API identifier: <code>web<span>_read</span>Result</code>.</p>
        <table><tr><th>Plan</th><th>Price</th></tr>
        <tr><td>Basic</td><td>39</td></tr><tr><td>Pro</td><td>99</td></tr></table>
        </main><footer>FOOTER-NOISE-316B</footer>
        </body></html>
        """

        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/prices")!,
            maximumScalars: 10_000
        )

        XCTAssertTrue(extraction.markdown.contains("`web_readResult`"))
        XCTAssertTrue(extraction.markdown.contains("| Plan"))
        XCTAssertTrue(extraction.markdown.contains("| Basic"))
        XCTAssertTrue(extraction.markdown.contains("39"))
        XCTAssertTrue(extraction.markdown.contains("| Pro"))
        XCTAssertTrue(extraction.markdown.contains("99"))
        XCTAssertTrue(extraction.hasMainContent)
        for noise in ["STYLE-NOISE-78D1", "SCRIPT-NOISE-28A6", "NAV-NOISE-C9B4", "FOOTER-NOISE-316B"] {
            XCTAssertFalse(extraction.markdown.contains(noise), "正文不能包含非内容区域：\(noise)")
        }
    }

    func testHTMLExtractorReportsScalarLimitAndKeepsUnicodeBoundary() throws {
        let body = "Aé e\u{301} 👩🏽‍💻 价格表尾标"
        let html = "<main><p>\(body)</p></main>"
        let limit = 9
        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/unicode")!,
            maximumScalars: limit
        )

        XCTAssertTrue(extraction.wasTruncated, "裁剪正文必须显式报告截断")
        XCTAssertLessThanOrEqual(extraction.markdown.unicodeScalars.count, limit)
        XCTAssertTrue(extraction.markdown.hasPrefix("Aé e\u{301}"))
    }

    func testHTMLExtractorBoundsNestedListAndOversizedLinkAmplification() throws {
        let oversizedURL = "https://fixture.invalid/" + String(repeating: "(", count: 20_000)
        let nestedLists = String(repeating: "<ul>", count: 30)
            + "<li>NESTED-LIST-MARKER</li>"
            + String(repeating: "</ul>", count: 30)
        let html = "<main><a href=\"\(oversizedURL)\">LINK-TEXT</a>\(nestedLists)<p>\(String(repeating: "x", count: 300))</p></main>"
        let scalarLimit = 64

        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/bounded")!,
            maximumScalars: scalarLimit
        )

        XCTAssertTrue(extraction.wasTruncated, "超过输出预算时必须显式标注截断")
        XCTAssertLessThanOrEqual(extraction.markdown.unicodeScalars.count, scalarLimit)
        XCTAssertFalse(extraction.markdown.contains(String(repeating: "(", count: 128)))
        XCTAssertTrue(extraction.markdown.contains("LINK-TEXT"))
    }

    func testJSONLDDescriptionAndHeadlineDoNotReplaceVisibleArticleBody() throws {
        let html = """
        <!doctype html><html><head><title>Visible title</title>
        <script type="application/ld+json">
        {"@type":"NewsArticle","headline":"JSONLD-HEADLINE-NOT-BODY-4D27 with enough extra words to exceed the fallback threshold","description":"JSONLD-DESCRIPTION-NOT-BODY-0A51 with enough extra words to exceed the fallback threshold"}
        </script></head><body><main><p>VISIBLE-BODY-MARKER-6E30</p></main></body></html>
        """

        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/article")!,
            maximumScalars: 10_000
        )

        XCTAssertEqual(extraction.title, "Visible title")
        XCTAssertTrue(extraction.markdown.contains("VISIBLE-BODY-MARKER-6E30"))
        XCTAssertFalse(extraction.usedStructuredArticleBody)
        XCTAssertFalse(extraction.markdown.contains("JSONLD-HEADLINE-NOT-BODY-4D27"))
        XCTAssertFalse(extraction.markdown.contains("JSONLD-DESCRIPTION-NOT-BODY-0A51"))
    }

    func testJSONLDArticleBodyIsExplicitlyMarkedAsStructuredBody() throws {
        let html = #"<html><head><script type="application/ld+json">{"@type":"NewsArticle","headline":"Structured title","articleBody":"Short article body."}</script></head><body><nav>MENU-NOISE</nav></body></html>"#

        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/structured")!,
            maximumScalars: 10_000
        )

        XCTAssertTrue(extraction.usedStructuredArticleBody)
        XCTAssertEqual(extraction.markdown, "Short article body.")
        XCTAssertFalse(extraction.markdown.contains("Structured title"))
    }

    func testHTMLExtractorSkipsBooleanAndNestedHiddenElementsWithoutLeakingText() throws {
        let html = """
        <main>
          <p hidden>BOOLEAN-HIDDEN-1F0A</p>
          <section hidden>
            <section>NESTED-HIDDEN-2A1B</section>
            <p>STILL-HIDDEN-3B2C</p>
          </section>
          <div aria-hidden="true">
            <div>NESTED-ARIA-HIDDEN-4C3D</div>
            <p>STILL-ARIA-HIDDEN-5D4E</p>
          </div>
          <img-card hidden><p>CUSTOM-HIDDEN-6E5F</p></img-card>
          <p>VISIBLE-AFTER-HIDDEN-6E5F</p>
        </main>
        """

        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/hidden")!,
            maximumScalars: 10_000
        )

        XCTAssertTrue(extraction.markdown.contains("VISIBLE-AFTER-HIDDEN-6E5F"))
        for marker in [
            "BOOLEAN-HIDDEN-1F0A", "NESTED-HIDDEN-2A1B", "STILL-HIDDEN-3B2C",
            "NESTED-ARIA-HIDDEN-4C3D", "STILL-ARIA-HIDDEN-5D4E", "CUSTOM-HIDDEN-6E5F"
        ] {
            XCTAssertFalse(extraction.markdown.contains(marker), "隐藏区域不得泄漏文本：\(marker)")
        }
    }

    func testHTMLExtractorKeepsParagraphsInsideTableCellsOnOneRow() throws {
        let html = "<main><table><tr><td><p>TABLE-CELL-LEFT-7A60</p><p><code>cross<span>_cell</span></code></p>continued<br>same-row</td><td><p>TABLE-CELL-RIGHT-8B71</p></td></tr><tr><td><div>TABLE-DIV-LEFT-9C82</div></td><td>TABLE-DIV-RIGHT-0D93</td></tr></table></main>"

        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/table")!,
            maximumScalars: 10_000
        )
        let row = try XCTUnwrap(extraction.markdown.split(separator: "\n").first {
            $0.contains("TABLE-CELL-LEFT-7A60")
        })

        XCTAssertTrue(row.contains("| TABLE-CELL-LEFT-7A60"))
        XCTAssertTrue(row.contains("`cross_cell`"))
        XCTAssertTrue(row.contains("continued same-row"))
        XCTAssertTrue(row.contains("| TABLE-CELL-RIGHT-8B71"))
        XCTAssertFalse(row.isEmpty)
        let divRow = try XCTUnwrap(extraction.markdown.split(separator: "\n").first {
            $0.contains("TABLE-DIV-LEFT-9C82")
        })
        XCTAssertTrue(divRow.contains("| TABLE-DIV-LEFT-9C82"))
        XCTAssertTrue(divRow.contains("| TABLE-DIV-RIGHT-0D93"))
    }

    func testHTMLExtractorPreservesRowspanAndColspanTableRelationships() throws {
        let html = """
        <main><table>
          <tr><th rowspan="2">Product group</th><th colspan="2">Monthly price</th><th>Annual price</th></tr>
          <tr><th>Basic</th><th>Pro</th><th>All plans</th></tr>
          <tr><td rowspan="2">Consumer</td><td>39</td><td>99</td><td>399</td></tr>
          <tr><td>49</td><td>119</td><td>499</td></tr>
        </table></main>
        """

        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/merged-table")!,
            maximumScalars: 10_000
        )
        let rows = extraction.markdown.split(separator: "\n").map(String.init).filter { $0.hasPrefix("|") }

        XCTAssertEqual(rows, [
            "| Product group | Monthly price | Monthly price | Annual price |",
            "| Product group | Basic | Pro | All plans |",
            "| Consumer | 39 | 99 | 399 |",
            "| Consumer | 49 | 119 | 499 |"
        ], "Markdown 表格必须展开合并单元格，保留每个值对应的逻辑行列")
    }

    func testHTMLExtractorDecodesEntityReferencesOnlyOnce() throws {
        let extraction = try WebReadHTMLExtractor.extract(
            html: "<main><p>ENTITY-ONCE-9C82 &amp;lt; END</p></main>",
            baseURL: URL(string: "https://fixture.invalid/entities")!,
            maximumScalars: 10_000
        )

        XCTAssertTrue(extraction.markdown.contains("ENTITY-ONCE-9C82 &lt; END"))
        XCTAssertFalse(extraction.markdown.contains("ENTITY-ONCE-9C82 < END"))
    }

    func testPlainMarkdownPreservesNestedListAndIndentedCodeWhitespace() throws {
        let markdown = """
        # Formatting

        - parent
          - child

            let result = 1
            print(result)
        """
        let extraction = try WebReadHTMLExtractor.text(
            bytes: Data(markdown.utf8),
            mimeType: "text/markdown",
            baseURL: URL(string: "https://fixture.invalid/markdown")!,
            maximumScalars: 10_000
        )

        XCTAssertEqual(extraction.markdown, markdown)
        XCTAssertTrue(extraction.markdown.contains("  - child"))
        XCTAssertTrue(extraction.markdown.contains("    let result = 1"))
    }

    func testURLSessionTransportDoesNotSendSyntheticSharedCookie() async throws {
        let privateURL = try fixtureURL("auth/private")
        let cookieStorage = HTTPCookieStorage.shared
        let previousCookie = cookieStorage.cookies(for: privateURL)?.first {
            $0.name == "fixture_auth"
        }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: privateURL.host ?? "127.0.0.1",
            .path: "/",
            .name: "fixture_auth",
            .value: "TEST-COOKIE-7F91"
        ]))
        cookieStorage.setCookie(cookie)
        defer {
            cookieStorage.deleteCookie(cookie)
            if let previousCookie { cookieStorage.setCookie(previousCookie) }
        }

        let response = try await URLSessionWebReadTransport().fetch(WebReadFetchRequest(
            url: privateURL,
            callID: "web-read-anonymous-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(4),
            maximumBytes: 1_024,
            maximumRedirects: 4
        ))

        XCTAssertEqual(response.statusCode, 401, "匿名读取不能继承应用共享 Cookie 存储")
        XCTAssertTrue(response.bytes.isEmpty, "受限响应不能伪装成可读正文")
    }

    func testURLSessionTransportStopsAtConfiguredResponseByteLimit() async throws {
        var components = try XCTUnwrap(URLComponents(
            url: fixtureURL("large"),
            resolvingAgainstBaseURL: false
        ))
        components.queryItems = [URLQueryItem(name: "bytes", value: "4096")]
        let largeURL = try XCTUnwrap(components.url)
        let limit = 256
        let response = try await URLSessionWebReadTransport().fetch(WebReadFetchRequest(
            url: largeURL,
            callID: "web-read-byte-limit-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(4),
            maximumBytes: limit,
            maximumRedirects: 4
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.bytes.count, limit)
        XCTAssertTrue(response.bodyWasTruncated)
    }

    func testForceOffloadPreservesWebReadJSONAndReloadMatchesEmptyNameByToolUseID() throws {
        let viewModel = AIChatViewModel()
        let sessionID = "web-read-test-\(UUID().uuidString)"
        viewModel.sessionId = sessionID
        let sessionDirectory = AIChatViewModel.minisPersistentBase
            .appendingPathComponent(sessionID, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let callID = "toolu_web_read_\(UUID().uuidString)"
        let markdown = String(repeating: "| Basic | 39 |\n| Pro | 99 |\n\n", count: 80)
        let modelJSON = try JSONEncoder().encode(WebReadResult(
            url: "https://fixture.invalid/pricing",
            title: "Fixture prices",
            retrievedAt: "2026-10-02T00:00:00Z",
            readStatus: .textReady,
            content: markdown,
            limitations: [],
            requestedURL: "https://fixture.invalid/source-page",
            sourceNote: "使用页面声明的公开备用正文。",
            documentID: "wr_test_saved_body",
            continuation: WebReadContinuation(start: 0, end: 8_000, savedEnd: 10_000, nextOffset: 8_000),
            locateStatus: nil,
            resources: [WebReadResource(
                url: "https://fixture.invalid/chart.png",
                type: "image/png",
                readStatus: "not_read",
                context: "价格图；图片内容未读取。"
            )]
        ))
        let modelOutput = try XCTUnwrap(String(data: modelJSON, encoding: .utf8))
        XCTAssertGreaterThan(modelOutput.count, 500)

        let toolInputData = try JSONSerialization.data(withJSONObject: ["url": "https://fixture.invalid/pricing"])
        let toolInput = try XCTUnwrap(String(data: toolInputData, encoding: .utf8))
        let rawToolUse = ToolUse(
            toolUseId: callID,
            name: "web_read",
            input: toolInput,
            description: nil,
            thoughtSignature: nil
        )
        let rawToolResult = ToolResult(
            toolUseId: callID,
            output: modelOutput,
            success: true,
            mediaRef: nil,
            snapshot: nil,
            pageURL: nil,
            status: "success"
        )
        let restoredUse = RawMessage(
            id: UUID().uuidString,
            sessionId: sessionID,
            role: .assistant,
            parts: [.toolUse(rawToolUse)],
            createdAt: Date()
        ).toAgentMessage(mediaResolver: { _ in URL(fileURLWithPath: "/tmp/web-read-test-no-media") })
        let restoredResult = RawMessage(
            id: UUID().uuidString,
            sessionId: sessionID,
            role: .user,
            parts: [.toolResult(rawToolResult)],
            createdAt: Date()
        ).toAgentMessage(mediaResolver: { _ in URL(fileURLWithPath: "/tmp/web-read-test-no-media") })
        guard case .toolResult(_, let restoredName, let restoredContent, _, _, _, _, _) = restoredResult.parts[0] else {
            return XCTFail("从持久化记录重载的网页结果应保留工具结果")
        }
        XCTAssertEqual(restoredName, "")
        XCTAssertEqual(restoredContent, modelOutput)
        viewModel.agentHistory = [
            restoredUse,
            restoredResult,
            AgentMessage(role: .assistant, parts: [.text("受保护的近期上下文 1")]),
            AgentMessage(role: .user, parts: [.text("受保护的近期上下文 2")]),
            AgentMessage(role: .assistant, parts: [.text("受保护的近期上下文 3")]),
            AgentMessage(role: .user, parts: [.text("受保护的近期上下文 4")])
        ]

        viewModel.offloadContextIfNeeded(
            model: LLMModel(id: "web-read-test", displayName: "web-read-test", provider: "test"),
            lastContextTokens: 10_000,
            force: true
        )

        guard case .toolResult(let offloadedID, let offloadedName, let offloadedJSON, let isError, _, _, _, _) =
                viewModel.agentHistory[1].parts[0] else {
            return XCTFail("强制转存必须保留原工具结果")
        }
        XCTAssertEqual(offloadedID, callID)
        XCTAssertEqual(offloadedName, "web_read")
        XCTAssertFalse(isError)
        let offloadedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(offloadedJSON.utf8)) as? [String: Any]
        )
        for key in ["url", "title", "retrieved_at", "read_status", "content", "limitations", "requested_url", "source_note", "resources", "offloaded_result_file"] {
            XCTAssertNotNil(offloadedObject[key], "转存结果仍须满足 JSON 字段契约：\(key)")
        }
        XCTAssertEqual(offloadedObject["read_status"] as? String, "partial")
        XCTAssertEqual(offloadedObject["content"] as? String, "")
        XCTAssertEqual(offloadedObject["title"] as? String, "Fixture prices")
        XCTAssertEqual(offloadedObject["retrieved_at"] as? String, "2026-10-02T00:00:00Z")
        XCTAssertEqual(offloadedObject["requested_url"] as? String, "https://fixture.invalid/source-page")
        XCTAssertEqual(offloadedObject["source_note"] as? String, "使用页面声明的公开备用正文。")
        XCTAssertNil(offloadedObject["document_id"])
        XCTAssertNil(offloadedObject["continuation"])
        XCTAssertNil(offloadedObject["locate_status"])
        XCTAssertEqual((offloadedObject["resources"] as? [[String: Any]])?.first?["url"] as? String, "https://fixture.invalid/chart.png")

        let expectedFile = AIChatViewModel.minisOffloadsPersistentDir(for: sessionID)
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("web_read_\(callID.suffix(12)).txt")
        XCTAssertEqual(offloadedObject["offloaded_result_file"] as? String,
                       "/var/minis/offloads/tools/web_read_\(callID.suffix(12)).txt")
        let storedOutput = try String(contentsOf: expectedFile, encoding: .utf8)
        let storedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(storedOutput.utf8)) as? [String: Any]
        )
        XCTAssertEqual(storedObject["url"] as? String, "https://fixture.invalid/pricing")
        XCTAssertEqual(storedObject["content"] as? String, markdown)
        XCTAssertEqual(storedObject["document_id"] as? String, "wr_test_saved_body")
        XCTAssertNotNil(storedObject["continuation"])

        viewModel.offloadContextIfNeeded(
            model: LLMModel(id: "web-read-test", displayName: "web-read-test", provider: "test"),
            lastContextTokens: 10_000,
            force: true
        )
        guard case .toolResult(_, _, let afterRepeatJSON, _, _, _, _, _) = viewModel.agentHistory[1].parts[0] else {
            return XCTFail("重复强制转存必须保留网页 JSON 结果")
        }
        XCTAssertEqual(afterRepeatJSON, offloadedJSON)
        XCTAssertEqual(try String(contentsOf: expectedFile, encoding: .utf8), modelOutput)

        let reloadedResult = ToolResult(
            toolUseId: offloadedID,
            output: offloadedJSON,
            success: true,
            mediaRef: nil,
            snapshot: nil,
            pageURL: nil,
            status: "success"
        )
        let reloadedChatMessage = RawMessage(
            id: UUID().uuidString,
            sessionId: sessionID,
            role: .assistant,
            parts: [.toolUse(rawToolUse), .toolResult(reloadedResult)],
            createdAt: Date()
        ).toChatMessage(
            mediaResolver: { _ in URL(fileURLWithPath: "/tmp/web-read-test-no-media") }
        )
        let matchedBlock = try XCTUnwrap(reloadedChatMessage.blocks.first)
        XCTAssertEqual(matchedBlock.toolUseId, callID)
        XCTAssertEqual(matchedBlock.content, offloadedJSON)
        XCTAssertEqual(matchedBlock.toolStatus, .success)
    }

    func testForceOffloadLeavesBodylessResourceOnlyJSONUnchanged() throws {
        let viewModel = AIChatViewModel()
        let sessionID = "web-read-resource-test-\(UUID().uuidString)"
        viewModel.sessionId = sessionID
        let sessionDirectory = AIChatViewModel.minisPersistentBase
            .appendingPathComponent(sessionID, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let callID = "toolu_resource_\(UUID().uuidString)"
        let modelJSON = try JSONEncoder().encode(WebReadResult(
            url: "https://fixture.invalid/chart.png",
            title: "Resource-only metadata",
            retrievedAt: "2026-10-02T00:00:00Z",
            readStatus: .resourceOnly,
            content: "",
            limitations: [String(repeating: "No body available. ", count: 48)],
            requestedURL: nil,
            sourceNote: nil,
            documentID: nil,
            continuation: nil,
            locateStatus: nil,
            resources: [WebReadResource(
                url: "https://fixture.invalid/chart.png",
                type: "image/png",
                readStatus: "not_read",
                context: String(repeating: "Image contents were not read. ", count: 24)
            )]
        ))
        let original = try XCTUnwrap(String(data: modelJSON, encoding: .utf8))
        XCTAssertGreaterThan(original.count, 500)

        viewModel.agentHistory = [
            AgentMessage(role: .assistant, parts: [
                .toolUse(id: callID, name: "web_read", input: ["url": "https://fixture.invalid/chart.png"])
            ]),
            AgentMessage(role: .user, parts: [
                .toolResult(id: callID, name: "", content: original, isError: false)
            ]),
            AgentMessage(role: .assistant, parts: [.text("近期上下文 1")]),
            AgentMessage(role: .user, parts: [.text("近期上下文 2")]),
            AgentMessage(role: .assistant, parts: [.text("近期上下文 3")]),
            AgentMessage(role: .user, parts: [.text("近期上下文 4")])
        ]

        viewModel.offloadContextIfNeeded(
            model: LLMModel(id: "web-read-test", displayName: "web-read-test", provider: "test"),
            lastContextTokens: 10_000,
            force: true
        )

        guard case .toolResult(_, _, let unchanged, _, _, _, _, _) = viewModel.agentHistory[1].parts[0] else {
            return XCTFail("resource_only 结果必须保留工具结果结构")
        }
        XCTAssertEqual(unchanged, original)
        let toolsDirectory = AIChatViewModel.minisOffloadsPersistentDir(for: sessionID)
            .appendingPathComponent("tools", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: toolsDirectory.path))
    }

    private static func configuration(
        totalTimeout: TimeInterval = 2,
        maximumResponseBytes: Int = 2_000,
        maximumDocumentScalars: Int = 1_000,
        maximumResultBytes: Int = 1_000,
        maximumCachedBytes: Int = 10_000,
        maximumCachedDocuments: Int = 8,
        documentLifetime: TimeInterval = 600,
        maximumConcurrentDownloads: Int = 2,
        renderTargetWaitTimeout: TimeInterval = 1
    ) -> WebReadConfiguration {
        WebReadConfiguration(
            totalTimeout: totalTimeout,
            maximumResponseBytes: maximumResponseBytes,
            maximumDocumentScalars: maximumDocumentScalars,
            maximumResultBytes: maximumResultBytes,
            maximumNetworkRequests: 4,
            maximumRedirects: 4,
            maximumConcurrentDownloads: maximumConcurrentDownloads,
            maximumConcurrentRenderers: 1,
            maximumCachedBytes: maximumCachedBytes,
            maximumCachedDocuments: maximumCachedDocuments,
            documentLifetime: documentLifetime,
            resourceWaitTimeout: 1,
            renderTargetWaitTimeout: renderTargetWaitTimeout
        )
    }

    private static func scope(
        sessionID: String = "test-session",
        userRequestID: String = "test-request",
        identityRevision: String = WebReadScope.anonymousIdentity
    ) -> WebReadScope {
        WebReadScope(
            sessionID: sessionID,
            userRequestID: userRequestID,
            identityRevision: identityRevision
        )
    }

    private static func string(from scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    private func makeService(
        transport: StubWebReadTransport,
        renderer: any WebReadRendering,
        configuration: WebReadConfiguration
    ) -> WebReadService {
        WebReadService(
            transport: transport,
            renderer: renderer,
            documentStore: WebReadDocumentStore(configuration: configuration),
            configuration: configuration
        )
    }

    private func decode(_ outcome: WebReadOutcome) throws -> WebReadResult {
        try JSONDecoder().decode(WebReadResult.self, from: XCTUnwrap(outcome.json.data(using: .utf8)))
    }

    private func waitForRequestCount(_ expected: Int, transport: StubWebReadTransport) async throws {
        for _ in 0..<100 {
            if transport.requests.count >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "WebReadServiceTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "受控 transport 未在 1 秒内收到预期请求"
        ])
    }

    func testHTMLExtractorKeepsIndependentTableCaptionsAndMergedCells() throws {
        let html = """
        <table><caption>Monthly price (USD per seat; range 1–10 seats)</caption>
          <tr><th rowspan="2">Plan family</th><th colspan="2">Price</th></tr>
          <tr><th>Basic</th><th>Pro</th></tr>
        </table>
        <table><tr><td rowspan="2">Region B</td><td>North</td></tr><tr><td>South</td></tr></table>
        """

        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/two-tables")!,
            maximumScalars: 10_000
        )
        let rows = extraction.markdown.split(separator: "\n").map(String.init).filter { $0.hasPrefix("|") }

        XCTAssertTrue(extraction.markdown.contains("Monthly price (USD per seat; range 1–10 seats)"))
        XCTAssertEqual(rows, [
            "| Plan family | Price | Price |",
            "| Plan family | Basic | Pro |",
            "| Region B | North |",
            "| Region B | South |"
        ])
    }

    func testHTMLExtractorBoundsMalformedHugeTableSpansAndReportsTruncation() throws {
        let html = "<table><tr><td>FIRST-CELL</td><td rowspan=\"999999\" colspan=\"999999\">WIDE-CELL</td><td>AFTER-WIDE-CELL</td></tr><tr><td>TAIL-CELL</td>"

        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/large-span")!,
            maximumScalars: 10_000
        )
        let rows = extraction.markdown.split(separator: "\n").map(String.init).filter { $0.hasPrefix("|") }

        XCTAssertTrue(extraction.wasTruncated)
        XCTAssertEqual(rows.count, 2)
        XCTAssertLessThanOrEqual(rows.map { $0.filter { $0 == "|" }.count }.max() ?? 0, 65)
        XCTAssertTrue(rows[0].contains("FIRST-CELL"))
        XCTAssertTrue(rows[0].contains("WIDE-CELL"))
        XCTAssertFalse(rows[0].contains("AFTER-WIDE-CELL"), "超大合并格之后无法容纳的单元格必须由截断状态明确说明")
    }

    func testHTMLExtractorDoesNotTreatArticleLoadingTextOrHeaderPlaceholderAsMainLoading() throws {
        let html = "<header><p>Loading</p></header><main><h1>Interface state notes</h1><p>The <b>Loading</b> state is documented here as part of the complete main article body.</p></main>"
        let extraction = try WebReadHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://fixture.invalid/loading-discussion")!,
            maximumScalars: 10_000
        )

        XCTAssertTrue(extraction.markdown.contains("The **Loading** state"))
        XCTAssertFalse(extraction.hasLoadingMarker, "非正文区域的占位符不应让所选 main 正文变成 partial")

        let shortMain = try WebReadHTMLExtractor.extract(
            html: "<main><p>EARLY</p><div>Loading...</div></main>",
            baseURL: URL(string: "https://fixture.invalid/short-main-loading")!,
            maximumScalars: 10_000
        )
        XCTAssertTrue(shortMain.hasLoadingMarker, "回退到整页正文时仍须合并 main 区域的加载状态")
    }

    private func fixtureURL(_ path: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let rawBaseURL = environment["TEST_RUNNER_WEB_READ_FIXTURE_BASE_URL"]
            ?? environment["WEB_READ_FIXTURE_BASE_URL"]
        guard let rawBaseURL,
              let baseURL = URL(string: rawBaseURL),
              baseURL.scheme == "http",
              let host = baseURL.host,
              host == "127.0.0.1" || host == "localhost" else {
            throw XCTSkip("请启动 loopback fixture_server.py，并通过 XCTest 环境设置 TEST_RUNNER_WEB_READ_FIXTURE_BASE_URL")
        }
        return baseURL.appendingPathComponent(path)
    }

    private func renderWithin(
        _ timeout: TimeInterval,
        renderer: WebReadRenderer,
        url: URL,
        callID: String,
        deadline: Date,
        queryTarget: String?,
        waitForTarget: Bool
    ) async throws -> WebReadRenderedPage {
        try await withThrowingTaskGroup(of: WebReadRenderedPage.self) { group in
            group.addTask {
                try await renderer.render(
                    url: url,
                    callID: callID,
                    deadline: deadline,
                    queryTarget: queryTarget,
                    waitForTarget: waitForTarget
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebReadTestTimeout.elapsed
            }
            defer { group.cancelAll() }
            guard let page = try await group.next() else {
                throw WebReadTestTimeout.elapsed
            }
            return page
        }
    }

    private func waitForBrowserDocument(_ manager: BrowserUseManager, at url: URL) async throws {
        for _ in 0..<120 {
            if manager.webView.url?.absoluteString == url.absoluteString, !manager.isLoading {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "WebReadServiceTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "真实浏览器标签未在六秒内完成 fixture 导航"
        ])
    }

    private func browserStateSnapshot(_ webView: WKWebView) async throws -> String {
        let value = try await webView.evaluateJavaScript("""
            (() => JSON.stringify({
                url: location.href,
                privateMarker: document.querySelector('#private-marker')?.textContent ?? '',
                input: document.querySelector('#note')?.value ?? '',
                output: document.querySelector('#output')?.textContent ?? '',
                scrollY: Math.round(window.scrollY),
                userAgent: navigator.userAgent,
                viewport: [window.innerWidth, window.innerHeight]
            }))()
            """)
        return try XCTUnwrap(value as? String, "浏览器状态快照必须是 JSON 字符串")
    }

    private func waitForAnonymousRenderer(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if BrowserTabPoolRegistry.shared.anonymousWebReadRendererCount > 0 {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "WebReadServiceTests", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "匿名 WebKit renderer 未在限定时间内进入活动状态"
        ])
    }

    private func cookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) { continuation.resume() }
        }
    }

    private func deleteCookie(_ cookie: HTTPCookie, from store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.delete(cookie) { continuation.resume() }
        }
    }

    private func withSyntheticCookie<T>(
        _ cookie: HTTPCookie,
        in store: WKHTTPCookieStore,
        operation: () async throws -> T
    ) async rethrows -> T {
        await setCookie(cookie, in: store)
        do {
            let value = try await operation()
            await deleteCookie(cookie, from: store)
            return value
        } catch {
            await deleteCookie(cookie, from: store)
            throw error
        }
    }

    private func withTemporaryCookie(
        _ cookie: HTTPCookie,
        in store: WKHTTPCookieStore,
        operation: () async -> Void
    ) async {
        let normalizedDomain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let previousCookie = await cookies(in: store).first {
            $0.name == cookie.name
                && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == normalizedDomain
                && $0.path == cookie.path
        }
        await setCookie(cookie, in: store)
        await operation()
        if let previousCookie {
            await setCookie(previousCookie, in: store)
        } else {
            await deleteCookie(cookie, from: store)
        }
    }
}

private enum WebReadTestTimeout: Error {
    case elapsed
}

private final class StubWebReadTransport: WebReadTransport, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let mimeType: String?
        let bytes: Data
        let delay: TimeInterval
        let bodyWasTruncated: Bool

        init(
            body: String,
            statusCode: Int = 200,
            mimeType: String? = "text/plain; charset=utf-8",
            delay: TimeInterval = 0,
            bodyWasTruncated: Bool = false
        ) {
            self.statusCode = statusCode
            self.mimeType = mimeType
            self.bytes = Data(body.utf8)
            self.delay = delay
            self.bodyWasTruncated = bodyWasTruncated
        }
    }

    private let lock = NSLock()
    private let responses: [String: Response]
    private var capturedRequests: [WebReadFetchRequest] = []
    private var cancelledIDs: Set<String> = []

    init(responses: [String: Response]) {
        self.responses = responses
    }

    var requests: [WebReadFetchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    var cancelledCallIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return cancelledIDs
    }

    func fetch(_ request: WebReadFetchRequest) async throws -> WebReadFetchedResponse {
        guard let response = recordAndFindResponse(for: request) else {
            throw WebReadFailure.transport("测试没有为 \(request.url.path) 配置响应")
        }
        if response.delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(response.delay * 1_000_000_000))
        }
        if wasCancelled(request.callID) {
            throw WebReadFailure.cancelled
        }
        return WebReadFetchedResponse(
            requestedURL: request.url,
            finalURL: request.url,
            statusCode: response.statusCode,
            mimeType: response.mimeType,
            suggestedFilename: nil,
            headers: [:],
            bytes: response.bytes,
            retrievedAt: Date(timeIntervalSince1970: 1_798_893_600),
            redirectCount: 0,
            bodyWasTruncated: response.bodyWasTruncated,
            stoppedForUnsupportedContent: false
        )
    }

    func cancel(callID: String) {
        lock.lock()
        cancelledIDs.insert(callID)
        lock.unlock()
    }

    private func recordAndFindResponse(for request: WebReadFetchRequest) -> Response? {
        lock.lock()
        defer { lock.unlock() }
        capturedRequests.append(request)
        return responses[request.url.path]
    }

    private func wasCancelled(_ callID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledIDs.contains(callID)
    }
}

@MainActor
private final class StubWebReadRenderer: WebReadRendering {
    private(set) var renderCalls = 0
    private let renderedPage: WebReadRenderedPage?

    init(renderedPage: WebReadRenderedPage? = nil) {
        self.renderedPage = renderedPage
    }

    func render(
        url: URL,
        callID: String,
        deadline: Date,
        queryTarget: String?,
        waitForTarget: Bool
    ) async throws -> WebReadRenderedPage {
        renderCalls += 1
        if let renderedPage { return renderedPage }
        throw WebReadFailure.transport("此用例不应启动 WebKit 渲染")
    }

    func cancel(callID: String) {}
}

@MainActor
private final class DeadlineWebReadRenderer: WebReadRendering {
    private(set) var renderCalls = 0

    func render(
        url: URL,
        callID: String,
        deadline: Date,
        queryTarget: String?,
        waitForTarget: Bool
    ) async throws -> WebReadRenderedPage {
        renderCalls += 1
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        throw WebReadFailure.deadlineExceeded
    }

    func cancel(callID: String) {}
}
