import Foundation
import XCTest
import WebKit
import Network
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
        let webSearch = try XCTUnwrap(tools.first { $0.name == "web_search" })
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
        XCTAssertEqual(Set(webSearch.parameters.keys), Set(["tool_title", "query", "document_id", "offset", "limit", "result_index"]))
        XCTAssertEqual(webSearch.required, ["tool_title", "query"])
        XCTAssertTrue(webSearch.description.contains("DuckDuckGo Lite anonymously"))
        XCTAssertTrue(webSearch.description.contains("web_read on selected source URLs"))
        XCTAssertNil(OffloadPermissionManager.extractOffloadCommand(from: "web_search sample query"),
            "直接匿名搜索保留普通工具权限路径，不映射为个人数据原生 offload")
        XCTAssertTrue(browserUse.description.contains("For known HTTP(S) page text, use web_read first"))
        XCTAssertTrue(browserUse.description.contains("web_search first"))
        XCTAssertTrue(browserUse.description.contains("Google/Bing fallback"))
        XCTAssertTrue(browserUse.description.contains("web_read is anonymous"))
        XCTAssertTrue(webSearch.description.contains("does not use browser cookies"))
    }

    func testDebugRegistryAdvertisesConstrainedWebSearchRPC() throws {
        #if DEBUG
        let method = try XCTUnwrap(DebugMethodRegistry.methods.first { $0.name == "debug.webSearch" })
        XCTAssertEqual(Set(method.params.map(\.name)), Set(["query", "experiment_call", "experiment_scope"]))
        XCTAssertEqual(method.params.first(where: { $0.name == "query" })?.required, true)
        XCTAssertFalse(method.params.contains { $0.name == "url" || $0.name == "headers" })
        XCTAssertTrue(method.returns.contains("tool_json"))
        #endif
    }

    func testDuckDuckGoRealLiteFixturesKeepEveryTitleSnippetAndFullSourceURL() throws {
        let fixtures: [(String, Int)] = [("duckduckgo-lite", 9), ("duckduckgo-lite-jev", 10)]
        for (name, expectedCount) in fixtures {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "html"))
            let html = try String(contentsOf: url, encoding: .utf8)
            let parsed = WebSearchHTMLExtractor.extract(
                html: html,
                baseURL: URL(string: "https://lite.duckduckgo.com/lite/")!,
                maximumResults: 512
            )

            XCTAssertEqual(parsed.results.count, expectedCount, name)
            XCTAssertTrue(parsed.hasResultStructure, name)
            XCTAssertFalse(parsed.explicitlyNoResults, name)
            XCTAssertFalse(parsed.verificationRequired, name)
            XCTAssertFalse(parsed.resultsTruncated, name)
            for result in parsed.results {
                XCTAssertFalse(result.title.isEmpty, "\(name) title must be kept")
                XCTAssertFalse((result.snippet ?? "").isEmpty, "\(name) summary must be kept for \(result.url)")
                XCTAssertNotNil(URL(string: result.url)?.host, "\(name) must keep a full source URL")
            }
            if name == "duckduckgo-lite" {
                XCTAssertTrue(parsed.results.contains { $0.url == "https://blog.cloudflare.com/clef-decision-models/" })
                XCTAssertTrue(parsed.results.contains { $0.url == "https://blog.cloudflare.com/clef-decision-models/" && ($0.snippet?.contains("reinforcement learning platform") ?? false) })
                XCTAssertEqual(parsed.nextPageMethod, "POST")
                XCTAssertEqual(parsed.nextPageStart, 10)
                let pageParameters = try XCTUnwrap(parsed.nextPageParameters)
                XCTAssertTrue(pageParameters.contains { $0.name == "q" && $0.value == "Cloudflare \"Clef\" model" })
                XCTAssertTrue(pageParameters.contains { $0.name == "vqd" && !$0.value.isEmpty })
                XCTAssertTrue(pageParameters.contains { $0.name == "dc" && $0.value == "10" })
            } else {
                XCTAssertFalse(parsed.results.contains { $0.url == "https://blog.cloudflare.com/clef-decision-models/" })
                XCTAssertNil(parsed.nextPageURL)
            }
        }
    }

    func testRealWebKitSearchSnapshotKeepsLongHrefAndPaginationFormParameters() async throws {
        let fullURL = "https://example.com/" + String(repeating: "long-path-segment-", count: 180) + "?a=1&b=2"
        let cookieName = "websearch_fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cookieValue = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cookieScript = "document.querySelector('#cookie-copy').textContent = document.cookie.includes('\(cookieName)=\(cookieValue)') ? 'PRIVATE_COOKIE_LEAKED' : 'PRIVATE_COOKIE_ISOLATED';"
        let pageHTML = #"<!doctype html><html><head><title>Search fixture</title></head><body><main><a class="result-link" href="FULL_URL_PLACEHOLDER">A complete title</a><div class="result-snippet">A nested <b>full</b> summary.</div><p id="cookie-copy">PENDING</p><script>COOKIE_SCRIPT_PLACEHOLDER</script><form class="next_form" action="/lite/" method="post"><input type="submit" value="Next Page"><input type="hidden" name="q" value="Cloudflare &quot;Clef&quot; model"><input type="hidden" name="s" value="10"><input type="hidden" name="vqd" value="public-page-token-123"></form></main></body></html>"#
            .replacingOccurrences(of: "FULL_URL_PLACEHOLDER", with: fullURL)
            .replacingOccurrences(of: "COOKIE_SCRIPT_PLACEHOLDER", with: cookieScript)
        let server = try WebSearchSnapshotHTTPServer(html: pageHTML)
        let pageURL = try await server.start()
        defer { server.stop() }

        let defaultCookieStore = WKWebsiteDataStore.default().httpCookieStore
        let privateCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: cookieName, .value: cookieValue
        ]))
        try await withSyntheticCookie(privateCookie, in: defaultCookieStore) {
            let renderer = WebReadRenderer()
            let page = try await renderWithin(
                5,
                renderer: renderer,
                url: pageURL,
                callID: "web-search-render-snapshot-\(UUID().uuidString)",
                deadline: Date().addingTimeInterval(5),
                queryTarget: nil,
                waitForTarget: false,
                preserveSearchStructure: true
            )
            XCTAssertFalse(page.htmlWasTruncated)
            XCTAssertTrue(page.html.contains("PRIVATE_COOKIE_ISOLATED"), "匿名搜索 WebKit 不得读取 default store 的合成 Cookie")
            XCTAssertFalse(page.html.contains("PRIVATE_COOKIE_LEAKED"))

            let extracted = WebSearchHTMLExtractor.extract(html: page.html, baseURL: page.finalURL, maximumResults: 512)
            let entry = try XCTUnwrap(extracted.results.first)
            XCTAssertEqual(entry.url, fullURL)
            XCTAssertGreaterThan(entry.url.unicodeScalars.count, 2048, "搜索渲染路径必须保留完整长来源 URL")
            XCTAssertEqual(entry.snippet, "A nested full summary.")
            XCTAssertEqual(extracted.nextPageURL, "http://127.0.0.1:\(pageURL.port!)/lite/")
            XCTAssertEqual(extracted.nextPageMethod, "POST")
            XCTAssertEqual(extracted.nextPageStart, 10)
            let fields = try XCTUnwrap(extracted.nextPageParameters)
            XCTAssertTrue(fields.contains { $0.name == "q" && $0.value == "Cloudflare \"Clef\" model" })
            XCTAssertTrue(fields.contains { $0.name == "s" && $0.value == "10" })
            XCTAssertTrue(fields.contains { $0.name == "vqd" && $0.value == "public-page-token-123" })

            let defaultCookiesAfterSearch = await cookies(in: defaultCookieStore)
            XCTAssertTrue(defaultCookiesAfterSearch.contains { $0.name == cookieName && $0.value == cookieValue },
                "匿名搜索 renderer 释放后，既有默认 Cookie store 内容必须保持不变")
        }
    }

    func testDuckDuckGoParserDecodesEntitiesNestedTextAndRedirectTargets() throws {
        let html = #"<html><body><a class="result-link" href="https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpath%3Fa%3D1%26b%3D2">A <b>nested</b> &amp; complete title</a><table><tr><td class="result-snippet">Readable <b>nested</b>&nbsp;text &#x2014; with &#65; entities.</td></tr></table></body></html>"#
        let parsed = WebSearchHTMLExtractor.extract(
            html: html,
            baseURL: URL(string: "https://lite.duckduckgo.com/lite/")!,
            maximumResults: 20
        )
        let result = try XCTUnwrap(parsed.results.first)
        XCTAssertEqual(result.title, "A nested & complete title")
        XCTAssertEqual(result.snippet, "Readable nested text — with A entities.")
        XCTAssertEqual(result.url, "https://example.com/path?a=1&b=2")
    }

    func testVerificationPageAndExplicitNoResultsRemainDistinct() throws {
        let baseURL = URL(string: "https://lite.duckduckgo.com/lite/")!
        let challenge = WebSearchHTMLExtractor.extract(
            html: #"<html><form id="challenge-form"><h1 class="anomaly-modal__title">Please complete the following challenge to confirm this search was made by a human.</h1></form></html>"#,
            baseURL: baseURL,
            maximumResults: 20
        )
        let empty = WebSearchHTMLExtractor.extract(
            html: #"<html><div class="no-results">No results found</div></html>"#,
            baseURL: baseURL,
            maximumResults: 20
        )
        XCTAssertTrue(challenge.verificationRequired)
        XCTAssertFalse(challenge.explicitlyNoResults)
        XCTAssertTrue(empty.explicitlyNoResults)
        XCTAssertFalse(empty.verificationRequired)

        let legitimateTopic = Self.searchHTML([
            ("CAPTCHA systems and unusual traffic", "A guide to CAPTCHA and detecting unusual traffic without blocking legitimate users.", "https://example.com/captcha")
        ])
        let topicResults = WebSearchHTMLExtractor.extract(html: legitimateTopic, baseURL: baseURL, maximumResults: 20)
        XCTAssertFalse(topicResults.verificationRequired, "ordinary result content must not be treated as a challenge")
        XCTAssertEqual(topicResults.results.count, 1)

        let actualChallengeShape = #"<html><form id="img-form" action="//duckduckgo.com/anomaly.js?sv=lite" method="POST"></form><form id="challenge-form" action="//duckduckgo.com/anomaly.js?sv=lite" method="POST"><div class="anomaly-modal__mask"><div class="anomaly-modal__modal" data-testid="anomaly-modal"><div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div><div class="anomaly-modal__description">Please complete the following challenge to confirm this search was made by a human.</div><div class="anomaly-modal__instructions">Select all squares containing a duck:</div><input type="checkbox" class="anomaly-modal__check"></div></div></form></html>"#
        XCTAssertTrue(WebSearchHTMLExtractor.extract(html: actualChallengeShape, baseURL: baseURL, maximumResults: 20).verificationRequired)
    }

    func testRejectedUnsafeResultLinkMarksGapAndTriggersFallback() async throws {
        let html = #"<a class="result-link" href="javascript:void(0)">Unsafe source</a><div class="result-snippet">Should not be shown.</div><a class="result-link" href="https://example.com/safe">Safe source</a><div class="result-snippet">Usable citation.</div>"#
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html")])
        let (service, _) = makeSearchService(transport: transport, renderer: StubWebReadRenderer())
        let scope = Self.scope(sessionID: "web-search-rejected-\(UUID().uuidString)")
        let result = try decodeSearch(await service.search(
            request: WebSearchRequest(query: "safe source"), scope: scope,
            callID: "web-search-rejected-\(UUID().uuidString)", batchID: "web-search-rejected-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        ))
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.results.map(\.url), ["https://example.com/safe"])
        XCTAssertTrue(result.limitations.contains { $0.contains("缺少标题或安全 HTTP(S) 来源") })
        XCTAssertEqual(service.recentDiagnostics.last?.networkAttempts, 2)
        service.endRequest(scope: scope)
    }

    func testOversizedInvalidQueryIsRejectedWithBoundedJSON() async throws {
        let transport = StubWebReadTransport(responses: [:])
        let (service, _) = makeSearchService(transport: transport, renderer: StubWebReadRenderer())
        let query = String(repeating: "Q", count: 100_000)
        let outcome = await service.search(
            request: WebSearchRequest(query: query), scope: Self.scope(),
            callID: "web-search-invalid-query-\(UUID().uuidString)", batchID: "web-search-invalid-query-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        XCTAssertLessThan(outcome.json.utf8.count, 10_000)
        XCTAssertEqual(try decodeSearch(outcome).status, .failed)
        XCTAssertTrue(try decodeSearch(outcome).limitations.contains { $0.contains("超过 512") })
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAnonymousSearchReturnsSuccessfulHTTPResultsWithoutCreatingWebView() async throws {
        let html = Self.searchHTML([
            ("Result one", "Full summary for the first source with enough context.", "https://example.com/one"),
            ("Result two", "Full summary for the second source with enough context.", "https://example.com/two"),
        ])
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html; charset=utf-8")])
        let renderer = StubWebReadRenderer()
        let (service, _) = makeSearchService(transport: transport, renderer: renderer)
        let scope = Self.scope(sessionID: "web-search-http-\(UUID().uuidString)")
        let batchID = "web-search-http-batch-\(UUID().uuidString)"
        service.beginBatch(id: batchID, sessionID: scope.sessionID, scope: scope)

        let outcome = await service.search(
            request: WebSearchRequest(query: "sample sources"),
            scope: scope,
            callID: "web-search-http-call-\(UUID().uuidString)",
            batchID: batchID,
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decodeSearch(outcome)

        XCTAssertEqual(result.status, .results)
        XCTAssertEqual(result.results.map(\.title), ["Result one", "Result two"])
        XCTAssertEqual(result.results.map(\.snippet), [
            "Full summary for the first source with enough context.",
            "Full summary for the second source with enough context.",
        ])
        XCTAssertEqual(result.results.map(\.url), ["https://example.com/one", "https://example.com/two"])
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(transport.requests[0].userAgent?.contains("Safari") == true)
        XCTAssertTrue(transport.requests[0].allowsNonSuccessBody)
        XCTAssertEqual(renderer.renderCalls, 0, "有效 Lite HTTP 结果必须直接返回，不创建 WebView")
        XCTAssertEqual(service.recentDiagnostics.last?.networkAttempts, 1)
        XCTAssertEqual(service.recentDiagnostics.last?.fallbackUsed, false)
        service.finishBatch(id: batchID)
        service.endRequest(scope: scope)
    }

    func testAnonymousSearchUsesAtMostOneSameEngineFallbackAfterHTTPFailure() async throws {
        let htmlURL = URL(string: "https://html.duckduckgo.com/html/?q=fixture")!
        let renderedHTML = Self.searchHTML([
            ("Rendered result one", "Rendered summary one.", "https://example.com/rendered-one"),
            ("Rendered result two", "Rendered summary two.", "https://example.com/rendered-two"),
        ], className: "result__a", snippetClass: "result__snippet")
        let renderedPage = WebReadRenderedPage(
            title: "DuckDuckGo Search",
            finalURL: htmlURL,
            html: renderedHTML,
            retrievedAt: Date(),
            htmlWasTruncated: false,
            targetFound: nil,
            targetWaitExpired: false,
            hasLoadingIndicator: false
        )
        let transport = StubWebReadTransport(responses: [:])
        let renderer = StubWebReadRenderer(renderedPage: renderedPage)
        let (service, _) = makeSearchService(transport: transport, renderer: renderer)
        let scope = Self.scope(sessionID: "web-search-fallback-\(UUID().uuidString)")
        let batchID = "web-search-fallback-batch-\(UUID().uuidString)"
        let outcome = await service.search(
            request: WebSearchRequest(query: "fixture"),
            scope: scope,
            callID: "web-search-fallback-call-\(UUID().uuidString)",
            batchID: batchID,
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decodeSearch(outcome)

        XCTAssertEqual(result.status, .results)
        XCTAssertEqual(result.results.count, 2)
        XCTAssertEqual(transport.requests.count, 1, "回退不得再发起第二次 HTTP 尝试")
        XCTAssertEqual(renderer.renderCalls, 1)
        XCTAssertEqual(renderer.renderedURLs.first?.host, "html.duckduckgo.com")
        XCTAssertEqual(renderer.searchStructureRequests, [true], "搜索回退使用保留下一页 form 与完整 href 的专用快照")
        XCTAssertEqual(service.recentDiagnostics.last?.networkAttempts, 2)
        XCTAssertEqual(service.recentDiagnostics.last?.fallbackUsed, true)
        XCTAssertTrue(result.limitations.contains { $0.contains("HTTP 读取失败") })
        service.endRequest(scope: scope)
    }

    func testSearchFallbackDeadlinePreservesAlreadyRetrievedPartialSources() async throws {
        let html = Self.searchHTML([
            ("Retrieved before fallback", "This complete source was obtained before the fallback deadline.", "https://example.com/preserved")
        ])
        let transport = StubWebReadTransport(responses: [
            "/lite/": .init(body: html, statusCode: 206, mimeType: "text/html", bodyWasTruncated: true)
        ])
        let renderer = DeadlineWebSearchRenderer()
        let (service, _) = makeSearchService(transport: transport, renderer: renderer)
        let scope = Self.scope(sessionID: "web-search-fallback-deadline-\(UUID().uuidString)")
        let outcome = await service.search(
            request: WebSearchRequest(query: "preserve partial result"), scope: scope,
            callID: "web-search-fallback-deadline-call-\(UUID().uuidString)",
            batchID: "web-search-fallback-deadline-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(0.25)
        )
        let result = try decodeSearch(outcome)

        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.results.map(\.url), ["https://example.com/preserved"])
        XCTAssertEqual(result.results.first?.title, "Retrieved before fallback")
        XCTAssertTrue(result.limitations.contains { $0.contains("统一截止时间") && $0.contains("未完成") })
        XCTAssertEqual(renderer.renderCalls, 1)
        XCTAssertEqual(transport.requests.count, 1, "达到共享截止时间后不得发起额外 HTTP 请求")
        XCTAssertTrue(service.recentDiagnostics.last?.fallbackUsed == true)
        service.endRequest(scope: scope)
    }

    func testSearchFallbackDeadlineOverOutputBudgetReturnsWholeEntriesWithoutArchive() async throws {
        let expected = (0..<12).map { index in
            (title: "Long result \(index)", snippet: String(repeating: "完整摘要 \(index) ", count: 320), url: "https://example.com/long-\(index)")
        }
        let html = Self.searchHTML(expected)
        let transport = StubWebReadTransport(responses: [
            "/lite/": .init(body: html, statusCode: 206, mimeType: "text/html", bodyWasTruncated: true)
        ])
        let config = Self.searchConfiguration(maximumOutputBytes: 10_240)
        let (service, store) = makeSearchService(transport: transport, renderer: DeadlineWebSearchRenderer(), configuration: config)
        let scope = Self.scope(sessionID: "web-search-fallback-deadline-long-\(UUID().uuidString)")
        let outcome = await service.search(
            request: WebSearchRequest(query: "long partial search"), scope: scope,
            callID: "web-search-fallback-deadline-long-call-\(UUID().uuidString)",
            batchID: "web-search-fallback-deadline-long-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(0.25)
        )
        let result = try decodeSearch(outcome)

        XCTAssertLessThanOrEqual(outcome.json.utf8.count, config.maximumOutputBytes)
        XCTAssertEqual(result.status, .partial)
        XCTAssertGreaterThan(result.results.count, 0)
        XCTAssertLessThan(result.results.count, expected.count, "超时且超过输出预算时只返回完整条目，未回传范围须明确说明")
        XCTAssertNil(result.documentID, "超时部分结果不能引用随后清理的缓存归档")
        XCTAssertNil(result.continuation)
        XCTAssertTrue(result.limitations.contains { $0.contains("未能在输出预算内回传") && $0.contains("不能续读") })
        XCTAssertTrue(result.limitations.contains { $0.contains("另有 \(expected.count - result.results.count) 条") },
            "超时结果必须报告未回传条目的实际数量")
        for entry in result.results {
            let index = try XCTUnwrap(Int(entry.title.replacingOccurrences(of: "Long result ", with: "")))
            let normalizedSnippet = expected[index].snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(entry.snippet, normalizedSnippet, "不得为迁就输出预算而截断规范化后的完整摘要")
            XCTAssertEqual(entry.url, expected[index].url)
        }
        XCTAssertEqual(store.count, 0, "统一截止时间后的部分结果不得写入结果归档缓存")
        XCTAssertEqual(transport.requests.count, 1)
        service.endRequest(scope: scope)
    }

    func testHTTP202CaptchaStaysVerificationRequiredAfterSingleFallback() async throws {
        let challenge = #"<html><form id="challenge-form"><h1 class="anomaly-modal__title">Please complete the following challenge to confirm this search was made by a human.</h1></form></html>"#
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: challenge, statusCode: 202, mimeType: "text/html")])
        let renderedPage = WebReadRenderedPage(
            title: "Verification",
            finalURL: URL(string: "https://html.duckduckgo.com/html/?q=challenge")!,
            html: challenge,
            retrievedAt: Date(),
            htmlWasTruncated: false,
            targetFound: nil,
            targetWaitExpired: false,
            hasLoadingIndicator: false
        )
        let renderer = StubWebReadRenderer(renderedPage: renderedPage)
        let (service, _) = makeSearchService(transport: transport, renderer: renderer)
        let scope = Self.scope(sessionID: "web-search-captcha-\(UUID().uuidString)")
        let outcome = await service.search(
            request: WebSearchRequest(query: "captcha"), scope: scope,
            callID: "web-search-captcha-call-\(UUID().uuidString)",
            batchID: "web-search-captcha-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decodeSearch(outcome)

        XCTAssertEqual(result.status, .verificationRequired)
        XCTAssertTrue(result.results.isEmpty)
        XCTAssertTrue(result.limitations.contains { $0.contains("不会自动解验证码") || $0.contains("没有自动完成挑战") })
        XCTAssertEqual(renderer.renderCalls, 1)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(service.recentDiagnostics.last?.networkAttempts, 2)
        XCTAssertEqual(service.recentDiagnostics.last?.fallbackUsed, true)
        service.endRequest(scope: scope)
    }

    func testTruncatedHTTPNoResultsPageRequiresFallbackAndDoesNotClaimNoResults() async throws {
        let emptyHTML = #"<html><div class="no-results">No results found</div></html>"#
        let transport = StubWebReadTransport(responses: [
            "/lite/": .init(body: emptyHTML, statusCode: 200, mimeType: "text/html", bodyWasTruncated: true)
        ])
        let renderer = ResourceLimitedWebSearchRenderer()
        let (service, _) = makeSearchService(transport: transport, renderer: renderer)
        let scope = Self.scope(sessionID: "web-search-truncated-empty-\(UUID().uuidString)")

        let outcome = await service.search(
            request: WebSearchRequest(query: "truncated empty page"), scope: scope,
            callID: "web-search-truncated-empty-call-\(UUID().uuidString)",
            batchID: "web-search-truncated-empty-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decodeSearch(outcome)

        XCTAssertEqual(result.status, .failed, "被截断的无结果提示不能证明完整搜索页没有结果")
        XCTAssertTrue(result.results.isEmpty)
        XCTAssertEqual(renderer.renderCalls, 1, "截断空页应在共享预算内进行一次回退")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(service.recentDiagnostics.last?.fallbackUsed == true)
        service.endRequest(scope: scope)
    }

    func testHTTP500BodyWithUsableSearchEntryIsPreservedAsPartial() async throws {
        let html = Self.searchHTML([
            ("HTTP error page still has a source", "Preserve this complete source while reporting the server error.", "https://example.com/http-error-source")
        ])
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: html, statusCode: 500, mimeType: "text/html")])
        let renderer = ResourceLimitedWebSearchRenderer()
        let (service, _) = makeSearchService(transport: transport, renderer: renderer)
        let scope = Self.scope(sessionID: "web-search-http-error-body-\(UUID().uuidString)")

        let outcome = await service.search(
            request: WebSearchRequest(query: "http error source"), scope: scope,
            callID: "web-search-http-error-body-call-\(UUID().uuidString)",
            batchID: "web-search-http-error-body-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decodeSearch(outcome)

        XCTAssertEqual(result.status, .partial, "非 2xx 正文可能保留来源，但不能报告为完整搜索结果")
        XCTAssertEqual(result.results.map(\.url), ["https://example.com/http-error-source"])
        XCTAssertTrue(result.limitations.contains { $0.contains("HTTP 500") })
        XCTAssertEqual(renderer.renderCalls, 1)
        service.endRequest(scope: scope)
    }

    func testHTTPChallengeFollowedByUsableFallbackReturnsResultsStatus() async throws {
        let challenge = #"<html><form id="challenge-form"><div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div></form></html>"#
        let renderedHTML = Self.searchHTML([("Recovered result", "Usable after fallback.", "https://example.com/recovered")], className: "result__a", snippetClass: "result__snippet")
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: challenge, statusCode: 202, mimeType: "text/html")])
        let page = WebReadRenderedPage(
            title: "DuckDuckGo",
            finalURL: URL(string: "https://html.duckduckgo.com/html/?q=recovery")!,
            html: renderedHTML,
            retrievedAt: Date(),
            htmlWasTruncated: false,
            targetFound: nil,
            targetWaitExpired: false,
            hasLoadingIndicator: false
        )
        let (service, _) = makeSearchService(transport: transport, renderer: StubWebReadRenderer(renderedPage: page))
        let scope = Self.scope(sessionID: "web-search-challenge-recovered-\(UUID().uuidString)")
        let outcome = await service.search(
            request: WebSearchRequest(query: "recovery"), scope: scope,
            callID: "web-search-challenge-recovered-\(UUID().uuidString)",
            batchID: "web-search-challenge-recovered-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decodeSearch(outcome)
        XCTAssertEqual(result.status, .results)
        XCTAssertEqual(result.results.map(\.url), ["https://example.com/recovered"])
        XCTAssertTrue(result.limitations.contains { $0.contains("要求验证") })
        service.endRequest(scope: scope)
    }

    func testHTTPChallengeFollowedByExplicitEmptyFallbackReturnsNoResults() async throws {
        let challenge = #"<form id="challenge-form"><div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div></form>"#
        let emptyHTML = #"<html><div class="no-results">No results found</div></html>"#
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: challenge, statusCode: 202, mimeType: "text/html")])
        let page = WebReadRenderedPage(
            title: "DuckDuckGo",
            finalURL: URL(string: "https://html.duckduckgo.com/html/?q=empty")!,
            html: emptyHTML,
            retrievedAt: Date(),
            htmlWasTruncated: false,
            targetFound: nil,
            targetWaitExpired: false,
            hasLoadingIndicator: false
        )
        let (service, _) = makeSearchService(transport: transport, renderer: StubWebReadRenderer(renderedPage: page))
        let scope = Self.scope(sessionID: "web-search-challenge-empty-\(UUID().uuidString)")
        let outcome = await service.search(
            request: WebSearchRequest(query: "empty"), scope: scope,
            callID: "web-search-challenge-empty-\(UUID().uuidString)",
            batchID: "web-search-challenge-empty-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decodeSearch(outcome)
        XCTAssertEqual(result.status, .noResults)
        XCTAssertTrue(result.results.isEmpty)
        XCTAssertTrue(result.limitations.contains { $0.contains("另一次匿名响应要求验证") })
        service.endRequest(scope: scope)
    }

    func testSearchPaginationRetainsFullArchiveAndRejectsOtherScopesAndWebRead() async throws {
        let html = Self.searchHTML([
            ("Page result 0", String(repeating: "first summary ", count: 8), "https://example.com/0"),
            ("Page result 1", String(repeating: "second summary ", count: 8), "https://example.com/1"),
            ("Page result 2", String(repeating: "third summary ", count: 8), "https://example.com/2"),
        ])
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html")])
        let renderer = StubWebReadRenderer()
        let (service, store) = makeSearchService(transport: transport, renderer: renderer)
        let scope = Self.scope(sessionID: "web-search-pages-\(UUID().uuidString)", userRequestID: "search-request")
        let batchID = "web-search-pages-batch-\(UUID().uuidString)"
        let first = await service.search(
            request: WebSearchRequest(query: "pages", limit: 1), scope: scope,
            callID: "web-search-page-0-\(UUID().uuidString)", batchID: batchID,
            deadline: Date().addingTimeInterval(2)
        )
        let firstResult = try decodeSearch(first)
        let documentID = try XCTUnwrap(firstResult.documentID)
        XCTAssertEqual(firstResult.results.map(\.title), ["Page result 0"])
        XCTAssertEqual(firstResult.continuation?.nextOffset, 1)
        XCTAssertEqual(firstResult.continuation?.savedEnd, 3)
        XCTAssertEqual(store.document(id: documentID, scope: scope)?.kind, .webSearch)

        let second = await service.search(
            request: WebSearchRequest(query: "pages", documentID: documentID, offset: firstResult.continuation?.nextOffset, limit: 1),
            scope: scope, callID: "web-search-page-1-\(UUID().uuidString)", batchID: batchID,
            deadline: Date().addingTimeInterval(2)
        )
        let secondResult = try decodeSearch(second)
        XCTAssertEqual(secondResult.results.map(\.title), ["Page result 1"])
        XCTAssertEqual(secondResult.continuation?.nextOffset, 2)
        XCTAssertEqual(transport.requests.count, 1, "续读使用归档，不再次发出网络请求")

        let otherScope = Self.scope(sessionID: scope.sessionID, userRequestID: "different-request")
        let crossScope = await service.search(
            request: WebSearchRequest(query: "pages", documentID: documentID, offset: 1, limit: 1),
            scope: otherScope, callID: "web-search-cross-scope-\(UUID().uuidString)", batchID: batchID,
            deadline: Date().addingTimeInterval(2)
        )
        XCTAssertEqual(try decodeSearch(crossScope).status, .failed)

        let readConfig = Self.configuration(maximumDocumentScalars: 2_000_000, maximumCachedBytes: 6 * 1024 * 1024)
        let readService = WebReadService(
            transport: transport, renderer: renderer, documentStore: store, configuration: readConfig
        )
        let misusedByRead = await readService.read(
            request: WebReadRequest(documentID: documentID), scope: scope,
            callID: "web-read-wrong-kind-\(UUID().uuidString)",
            batchID: "web-read-wrong-kind-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        XCTAssertEqual(try decode(misusedByRead).readStatus, .failed)
        XCTAssertEqual(transport.requests.count, 1)
        service.endRequest(scope: scope)
    }

    func testOversizedSingleSearchResultUsesAccessibleFragmentsAndKeepsLaterResults() async throws {
        let fullSummary = String(repeating: "S", count: 2_000)
        let html = Self.searchHTML([
            ("Oversized result", fullSummary, "https://example.com/oversized"),
            ("Following result", "This later source must remain available after the fragment completes.", "https://example.com/following"),
        ])
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html")])
        let searchConfig = Self.searchConfiguration(maximumOutputBytes: 700)
        let (service, store) = makeSearchService(transport: transport, renderer: StubWebReadRenderer(), configuration: searchConfig)
        let scope = Self.scope(sessionID: "web-search-long-entry-\(UUID().uuidString)")
        let outcome = await service.search(
            request: WebSearchRequest(query: "long entry", limit: 1), scope: scope,
            callID: "web-search-long-entry-call-\(UUID().uuidString)",
            batchID: "web-search-long-entry-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let result = try decodeSearch(outcome)
        XCTAssertLessThanOrEqual(outcome.json.utf8.count, searchConfig.maximumOutputBytes)
        XCTAssertEqual(result.status, .partial)
        XCTAssertTrue(result.results.isEmpty)
        XCTAssertNotNil(result.resultFragment)
        let documentID = try XCTUnwrap(result.documentID)
        XCTAssertGreaterThan(store.totalCachedBytes, 0, "超大字段保持在请求期间的完整归档中")

        var fragment = try XCTUnwrap(result.resultFragment)
        var assembled = fragment.content
        while let next = fragment.nextOffset {
            let nextOutcome = await service.search(
                request: WebSearchRequest(query: "long entry", documentID: documentID, offset: next, limit: 200, resultIndex: 0),
                scope: scope, callID: "web-search-long-fragment-\(next)-\(UUID().uuidString)",
                batchID: "web-search-long-entry-batch-\(UUID().uuidString)", deadline: Date().addingTimeInterval(2)
            )
            XCTAssertLessThanOrEqual(nextOutcome.json.utf8.count, searchConfig.maximumOutputBytes)
            fragment = try XCTUnwrap(decodeSearch(nextOutcome).resultFragment)
            XCTAssertEqual(fragment.start, next)
            assembled += fragment.content
        }
        let completeEntry = try JSONDecoder().decode(WebSearchEntry.self, from: Data(assembled.utf8))
        XCTAssertEqual(completeEntry.title, "Oversized result")
        XCTAssertEqual(completeEntry.snippet, fullSummary)
        XCTAssertEqual(completeEntry.url, "https://example.com/oversized")

        let following = try decodeSearch(await service.search(
            request: WebSearchRequest(query: "long entry", documentID: documentID, offset: 1, limit: 1),
            scope: scope, callID: "web-search-following-\(UUID().uuidString)",
            batchID: "web-search-long-entry-batch-\(UUID().uuidString)", deadline: Date().addingTimeInterval(2)
        ))
        XCTAssertEqual(following.results.map(\.title), ["Following result"])
        service.endRequest(scope: scope)
    }

    func testSearchPermitCapsConcurrencyAndQueuedDeadlineDoesNotStartHTTP() async throws {
        let html = Self.searchHTML([("Quick result", "A concise summary.", "https://example.com/quick")])
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html", delay: 0.08)])
        let config = Self.searchConfiguration(maximumActiveSearches: 2, maximumQueuedSearches: 4)
        let (service, _) = makeSearchService(transport: transport, renderer: StubWebReadRenderer(), configuration: config)
        let scope = Self.scope(sessionID: "web-search-concurrency-\(UUID().uuidString)")
        let batchID = "web-search-concurrency-batch-\(UUID().uuidString)"
        service.beginBatch(id: batchID, sessionID: scope.sessionID, scope: scope)
        let tasks = (0..<4).map { index in
            Task {
                await service.search(
                    request: WebSearchRequest(query: "parallel \(index)"), scope: scope,
                    callID: "web-search-parallel-\(index)-\(UUID().uuidString)", batchID: batchID,
                    deadline: Date().addingTimeInterval(2)
                )
            }
        }
        for task in tasks { _ = await task.value }
        XCTAssertEqual(transport.maximumConcurrentRequests, 2)
        XCTAssertEqual(transport.requests.count, 4)
        service.finishBatch(id: batchID)
        service.endRequest(scope: scope)

        let slowTransport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html", delay: 0.25)])
        let singlePermit = Self.searchConfiguration(maximumActiveSearches: 1, maximumQueuedSearches: 1)
        let (queuedService, _) = makeSearchService(transport: slowTransport, renderer: StubWebReadRenderer(), configuration: singlePermit)
        let queuedScope = Self.scope(sessionID: "web-search-queue-deadline-\(UUID().uuidString)")
        let queuedBatch = "web-search-queue-deadline-batch-\(UUID().uuidString)"
        queuedService.beginBatch(id: queuedBatch, sessionID: queuedScope.sessionID, scope: queuedScope)
        let active = Task {
            await queuedService.search(
                request: WebSearchRequest(query: "active"), scope: queuedScope,
                callID: "web-search-active-\(UUID().uuidString)", batchID: queuedBatch,
                deadline: Date().addingTimeInterval(2)
            )
        }
        try await waitForRequestCount(1, transport: slowTransport)
        let queued = await queuedService.search(
            request: WebSearchRequest(query: "queued"), scope: queuedScope,
            callID: "web-search-queued-\(UUID().uuidString)", batchID: queuedBatch,
            deadline: Date().addingTimeInterval(0.04)
        )
        XCTAssertEqual(try decodeSearch(queued).status, .failed)
        XCTAssertEqual(slowTransport.requests.count, 1, "排队期限到达后不得发出迟到的 HTTP 请求")
        let activeOutcome = await active.value
        XCTAssertEqual(try decodeSearch(activeOutcome).status, .results)
        queuedService.finishBatch(id: queuedBatch)
        queuedService.endRequest(scope: queuedScope)
    }

    func testSearchCancellationBatchQueueMemoryPressureAndRecovery() async throws {
        let html = Self.searchHTML([("Recovered result", "A complete summary.", "https://example.com/recovered")])
        let siblingTransport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html", delay: 0.18)])
        let siblingConfig = Self.searchConfiguration(maximumActiveSearches: 2, maximumQueuedSearches: 2)
        let (siblingService, _) = makeSearchService(transport: siblingTransport, renderer: StubWebReadRenderer(), configuration: siblingConfig)
        let siblingScope = Self.scope(sessionID: "web-search-sibling-cancel-\(UUID().uuidString)")
        let siblingBatch = "web-search-sibling-batch-\(UUID().uuidString)"
        siblingService.beginBatch(id: siblingBatch, sessionID: siblingScope.sessionID, scope: siblingScope)
        let cancelledCall = "web-search-sibling-cancelled-\(UUID().uuidString)"
        let survivingCall = "web-search-sibling-survives-\(UUID().uuidString)"
        let cancelledTask = Task {
            await siblingService.search(request: WebSearchRequest(query: "cancel me"), scope: siblingScope, callID: cancelledCall, batchID: siblingBatch, deadline: Date().addingTimeInterval(2))
        }
        let survivingTask = Task {
            await siblingService.search(request: WebSearchRequest(query: "continue"), scope: siblingScope, callID: survivingCall, batchID: siblingBatch, deadline: Date().addingTimeInterval(2))
        }
        try await waitForRequestCount(2, transport: siblingTransport)
        siblingService.cancel(callID: cancelledCall, scope: siblingScope, batchID: siblingBatch)
        let cancelledOutcome = await cancelledTask.value
        let survivingOutcome = await survivingTask.value
        XCTAssertEqual(try decodeSearch(cancelledOutcome).status, .cancelled)
        XCTAssertEqual(try decodeSearch(survivingOutcome).status, .results, "取消一个搜索不得取消同批次兄弟调用")
        siblingService.finishBatch(id: siblingBatch)

        let queueTransport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html", delay: 0.20)])
        let queueConfig = Self.searchConfiguration(maximumActiveSearches: 1, maximumQueuedSearches: 2)
        let (queueService, _) = makeSearchService(transport: queueTransport, renderer: StubWebReadRenderer(), configuration: queueConfig)
        let queueScope = Self.scope(sessionID: "web-search-batch-stop-\(UUID().uuidString)")
        let stoppedBatch = "web-search-stop-batch-\(UUID().uuidString)"
        queueService.beginBatch(id: stoppedBatch, sessionID: queueScope.sessionID, scope: queueScope)
        let active = Task {
            await queueService.search(request: WebSearchRequest(query: "active"), scope: queueScope, callID: "web-search-stopped-active-\(UUID().uuidString)", batchID: stoppedBatch, deadline: Date().addingTimeInterval(2))
        }
        try await waitForRequestCount(1, transport: queueTransport)
        let queued = Task {
            await queueService.search(request: WebSearchRequest(query: "queued"), scope: queueScope, callID: "web-search-stopped-queued-\(UUID().uuidString)", batchID: stoppedBatch, deadline: Date().addingTimeInterval(2))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        queueService.cancelBatch(stoppedBatch)
        let stoppedQueuedOutcome = await queued.value
        let stoppedActiveOutcome = await active.value
        XCTAssertEqual(try decodeSearch(stoppedQueuedOutcome).status, .cancelled)
        XCTAssertEqual(try decodeSearch(stoppedActiveOutcome).status, .cancelled)
        XCTAssertEqual(queueTransport.requests.count, 1, "批次 Stop 后排队搜索不得开始 HTTP")
        queueService.finishBatch(id: stoppedBatch)

        let sessionStopScope = Self.scope(sessionID: "web-search-session-stop-\(UUID().uuidString)")
        let sessionStopBatch = "web-search-session-stop-batch-\(UUID().uuidString)"
        queueService.beginBatch(id: sessionStopBatch, sessionID: sessionStopScope.sessionID, scope: sessionStopScope)
        let sessionActive = Task {
            await queueService.search(request: WebSearchRequest(query: "session active"), scope: sessionStopScope, callID: "web-search-session-active-\(UUID().uuidString)", batchID: sessionStopBatch, deadline: Date().addingTimeInterval(2))
        }
        try await waitForRequestCount(2, transport: queueTransport)
        let sessionQueued = Task {
            await queueService.search(request: WebSearchRequest(query: "session queued"), scope: sessionStopScope, callID: "web-search-session-queued-\(UUID().uuidString)", batchID: sessionStopBatch, deadline: Date().addingTimeInterval(2))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        queueService.cancelSession(sessionStopScope.sessionID)
        let sessionQueuedOutcome = await sessionQueued.value
        let sessionActiveOutcome = await sessionActive.value
        XCTAssertEqual(try decodeSearch(sessionQueuedOutcome).status, .cancelled)
        XCTAssertEqual(try decodeSearch(sessionActiveOutcome).status, .cancelled)
        XCTAssertEqual(queueTransport.requests.count, 2, "会话 Stop 后排队搜索不得开始 HTTP")

        let recoveredSummary = String(repeating: "完整摘要。", count: 180)
        let archiveHTML = Self.searchHTML([("Long result", recoveredSummary, "https://example.com/long")])
        let archiveTransport = StubWebReadTransport(responses: ["/lite/": .init(body: archiveHTML, mimeType: "text/html")])
        let (archiveService, archiveStore) = makeSearchService(
            transport: archiveTransport, renderer: StubWebReadRenderer(),
            configuration: Self.searchConfiguration(maximumOutputBytes: 700)
        )
        let archiveScope = Self.scope(sessionID: "web-search-memory-warning-\(UUID().uuidString)")
        let archived = await archiveService.search(
            request: WebSearchRequest(query: "archive"), scope: archiveScope,
            callID: "web-search-archive-\(UUID().uuidString)", batchID: "web-search-archive-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        XCTAssertEqual(try decodeSearch(archived).status, .partial)
        XCTAssertEqual(archiveStore.count, 1, "续读文档先进入有界缓存")
        let pressure = archiveService.handleMemoryWarning()
        XCTAssertEqual(pressure.removedDocuments, 1)
        XCTAssertEqual(archiveStore.count, 0)
        let recovered = try decodeSearch(await archiveService.search(
            request: WebSearchRequest(query: "recovered"), scope: archiveScope,
            callID: "web-search-after-pressure-\(UUID().uuidString)", batchID: "web-search-after-pressure-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        ))
        XCTAssertEqual(recovered.status, .partial, "受当前输出预算限制的新搜索应如实返回 partial，而不是伪装成完整结果")
        let recoveredDocumentID = try XCTUnwrap(recovered.documentID)
        var fragment = try XCTUnwrap(recovered.resultFragment, "清理后新搜索仍须提供完整结果的续读入口")
        var assembled = fragment.content
        while let next = fragment.nextOffset {
            let nextOutcome = await archiveService.search(
                request: WebSearchRequest(query: "recovered", documentID: recoveredDocumentID, offset: next, limit: 200, resultIndex: 0),
                scope: archiveScope, callID: "web-search-after-pressure-fragment-\(next)-\(UUID().uuidString)",
                batchID: "web-search-after-pressure-fragment-batch-\(UUID().uuidString)",
                deadline: Date().addingTimeInterval(2)
            )
            fragment = try XCTUnwrap(decodeSearch(nextOutcome).resultFragment)
            assembled += fragment.content
        }
        let recoveredEntry = try JSONDecoder().decode(WebSearchEntry.self, from: Data(assembled.utf8))
        XCTAssertEqual(recoveredEntry.title, "Long result")
        XCTAssertEqual(recoveredEntry.snippet, recoveredSummary)
        XCTAssertEqual(recoveredEntry.url, "https://example.com/long")
        XCTAssertEqual(archiveTransport.requests.count, 2, "资源压力清理后仍可发起新请求并完整续读")
        archiveService.endRequest(scope: archiveScope)
    }

    func testChatStoreLocalDeletionCancelsCachedSearchOnlyForDeletedSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-search-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let chatStore = ChatStore(baseURL: directory)
        let deletedSession = await chatStore.createSession(modelId: "test-model", title: "deleted search")
        let siblingSession = await chatStore.createSession(modelId: "test-model", title: "sibling search")

        let summary = String(repeating: "Complete archived search summary. ", count: 120)
        let html = Self.searchHTML([("Session scoped result", summary, "https://example.com/session-scoped")])
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html", delay: 0.20)])
        let configuration = Self.searchConfiguration(maximumOutputBytes: 900)
        let (service, store) = makeSearchService(
            transport: transport,
            renderer: StubWebReadRenderer(),
            configuration: configuration
        )
        let deletedSeedScope = Self.scope(sessionID: deletedSession.id, userRequestID: "deleted-seed")
        let siblingSeedScope = Self.scope(sessionID: siblingSession.id, userRequestID: "sibling-seed")

        defer {
            ViewModelCache.shared.remove(sessionId: deletedSession.id)
            ViewModelCache.shared.remove(sessionId: siblingSession.id)
            service.cancelSession(deletedSession.id)
            service.cancelSession(siblingSession.id)
            Task {
                await chatStore.closeDatabase()
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let deletedSeed = await service.search(
            request: WebSearchRequest(query: "deleted session archive"), scope: deletedSeedScope,
            callID: "web-search-deleted-seed-\(UUID().uuidString)",
            batchID: "web-search-deleted-seed-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let deletedDocumentID = try XCTUnwrap(decodeSearch(deletedSeed).documentID)
        let siblingSeed = await service.search(
            request: WebSearchRequest(query: "sibling session archive"), scope: siblingSeedScope,
            callID: "web-search-sibling-seed-\(UUID().uuidString)",
            batchID: "web-search-sibling-seed-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(2)
        )
        let siblingDocumentID = try XCTUnwrap(decodeSearch(siblingSeed).documentID)
        XCTAssertNotNil(store.document(id: deletedDocumentID, scope: deletedSeedScope))
        XCTAssertNotNil(store.document(id: siblingDocumentID, scope: siblingSeedScope))

        let deletedViewModel = AIChatViewModel()
        deletedViewModel.sessionId = deletedSession.id
        deletedViewModel.webSearchService = service
        deletedViewModel.promptQueue = [QueuedPrompt(text: "must not resume after deletion", attachments: [])]
        ViewModelCache.shared.cacheDraft(deletedViewModel, sessionId: deletedSession.id)
        let siblingViewModel = AIChatViewModel()
        siblingViewModel.sessionId = siblingSession.id
        siblingViewModel.webSearchService = service
        ViewModelCache.shared.cacheDraft(siblingViewModel, sessionId: siblingSession.id)

        let deletedActiveScope = Self.scope(sessionID: deletedSession.id, userRequestID: "deleted-active")
        let siblingActiveScope = Self.scope(sessionID: siblingSession.id, userRequestID: "sibling-active")
        let deletedActive = Task {
            await service.search(
                request: WebSearchRequest(query: "deleted active search"), scope: deletedActiveScope,
                callID: "web-search-deleted-active-\(UUID().uuidString)",
                batchID: "web-search-deleted-active-batch-\(UUID().uuidString)",
                deadline: Date().addingTimeInterval(2)
            )
        }
        let siblingActive = Task {
            await service.search(
                request: WebSearchRequest(query: "sibling active search"), scope: siblingActiveScope,
                callID: "web-search-sibling-active-\(UUID().uuidString)",
                batchID: "web-search-sibling-active-batch-\(UUID().uuidString)",
                deadline: Date().addingTimeInterval(2)
            )
        }
        try await waitForRequestCount(4, transport: transport)

        await chatStore.deleteSessionLocalOnly(deletedSession.id)
        for _ in 0..<100 {
            if ViewModelCache.shared.get(for: deletedSession.id) == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNil(ViewModelCache.shared.get(for: deletedSession.id), "本地及远端删除公共路径必须移除已缓存的目标会话 ViewModel")
        XCTAssertTrue(deletedViewModel.promptQueue.isEmpty, "会话删除必须丢弃待处理提示，不能由 Stop 路径重新排队执行")
        XCTAssertNil(deletedViewModel.currentTask, "会话删除不得启动排队提示的恢复任务")
        XCTAssertNotNil(ViewModelCache.shared.get(for: siblingSession.id), "删除一个会话不得移除兄弟会话 ViewModel")
        XCTAssertNil(store.document(id: deletedDocumentID, scope: deletedSeedScope), "删除会话必须清理其搜索归档")
        XCTAssertNotNil(store.document(id: siblingDocumentID, scope: siblingSeedScope), "删除会话不得清理兄弟会话的搜索归档")

        let deletedOutcome = try decodeSearch(await deletedActive.value)
        let siblingOutcome = try decodeSearch(await siblingActive.value)
        XCTAssertEqual(deletedOutcome.status, .cancelled, "删除会话应停止正在运行的搜索")
        XCTAssertEqual(siblingOutcome.status, .partial, "兄弟会话中的并行搜索应完成，并遵守单次输出预算")
        let activeSiblingDocumentID = try XCTUnwrap(siblingOutcome.documentID)
        var fragment = try XCTUnwrap(siblingOutcome.resultFragment, "超长兄弟结果应提供可续读片段")
        var assembledEntryJSON = fragment.content
        while let nextOffset = fragment.nextOffset {
            let continued = try decodeSearch(await service.search(
                request: WebSearchRequest(
                    query: "sibling active search",
                    documentID: activeSiblingDocumentID,
                    offset: nextOffset,
                    resultIndex: fragment.resultIndex
                ),
                scope: siblingActiveScope,
                callID: "web-search-sibling-active-fragment-\(nextOffset)-\(UUID().uuidString)",
                batchID: "web-search-sibling-active-fragment-batch-\(UUID().uuidString)",
                deadline: Date().addingTimeInterval(2)
            ))
            let nextFragment = try XCTUnwrap(continued.resultFragment)
            XCTAssertEqual(nextFragment.start, nextOffset)
            XCTAssertEqual(nextFragment.resultIndex, fragment.resultIndex)
            assembledEntryJSON += nextFragment.content
            fragment = nextFragment
        }
        let completeSiblingEntry = try JSONDecoder().decode(WebSearchEntry.self, from: Data(assembledEntryJSON.utf8))
        XCTAssertEqual(completeSiblingEntry.url, "https://example.com/session-scoped")
        XCTAssertEqual(completeSiblingEntry.snippet, summary.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testContinuationCancelledBeforeDeadlineStaysCancelledAndRetainsBorrowedArchive() async throws {
        let store = WebReadDocumentStore(configuration: Self.configuration(
            maximumDocumentScalars: 2_000_000,
            maximumCachedBytes: 4 * 1024 * 1024
        ))
        let scope = Self.scope(sessionID: "web-search-continuation-cancel-deadline-\(UUID().uuidString)")
        let entries = (0..<512).map { index in
            WebSearchEntry(
                title: "Large archive entry \(index)",
                snippet: String(repeating: "complete summary \(index) ", count: 160),
                url: "https://example.com/archive/\(index)"
            )
        }
        let archive = WebSearchArchive(
            query: "large archive",
            engine: "duckduckgo_lite",
            status: .partial,
            retrievedAt: "2026-10-03T00:00:00Z",
            results: entries,
            limitations: [],
            nextPageURL: nil,
            nextPageMethod: nil,
            nextPageStart: nil,
            nextPageParameters: nil,
            coverage: "fixture"
        )
        let archiveJSON = try String(decoding: JSONEncoder().encode(archive), as: UTF8.self)
        let document = store.save(
            content: archiveJSON,
            scope: scope,
            url: "https://lite.duckduckgo.com/lite/",
            title: archive.query,
            retrievedAt: archive.retrievedAt,
            limitations: [],
            requestedURL: nil,
            sourceNote: "test fixture",
            resources: [],
            contentIsComplete: true,
            kind: .webSearch,
            maximumScalars: 2_000_000
        )
        let service = WebSearchService(
            transport: StubWebReadTransport(responses: [:]),
            renderer: StubWebReadRenderer(),
            documentStore: store,
            configuration: Self.searchConfiguration(maximumOutputBytes: 10_240)
        )
        let callID = "web-search-continuation-race-\(UUID().uuidString)"
        let batchID = "web-search-continuation-race-batch-\(UUID().uuidString)"
        let deadline = Date().addingTimeInterval(0.08)
        let continuationTask = Task {
            await service.search(
                request: WebSearchRequest(query: archive.query, documentID: document.id, offset: 0, limit: 512),
                scope: scope,
                callID: callID,
                batchID: batchID,
                deadline: deadline
            )
        }
        for _ in 0..<100 where service.activeCallCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(service.activeCallCount, 1)
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertLessThan(Date(), deadline, "取消必须在统一截止时间前触发")
        service.cancel(callID: callID, scope: scope, batchID: batchID)

        let outcome = try decodeSearch(await continuationTask.value)
        XCTAssertEqual(outcome.status, .cancelled, "先发生的用户取消不得被随后到达的期限改写为 failed")
        XCTAssertNotNil(store.document(id: document.id, scope: scope), "续读借用的共享归档应留给同作用域兄弟读取")
    }

    func testSearchPermitCancellationAtGrantReleasesLease() async throws {
        let gate = SearchPermitGate()
        let pool = WebSearchPermitPool(maximumActive: 1, maximumQueued: 0, afterGrant: { await gate.pauseAfterGrant() })
        let racedAcquire = Task {
            try await pool.acquire(id: "cancel-at-grant", deadline: Date().addingTimeInterval(1))
        }
        await gate.waitUntilPaused()
        racedAcquire.cancel()
        await gate.open()
        do {
            try await racedAcquire.value
            XCTFail("取消必须使刚授予的 permit acquisition 失败")
        } catch {
            guard case WebReadFailure.cancelled = error else {
                return XCTFail("permit 应以取消结束，实际错误：\(error)")
            }
        }

        let next = Task {
            try await pool.acquire(id: "next-after-cancel", deadline: Date().addingTimeInterval(1))
        }
        try await next.value
        await pool.release(id: "next-after-cancel")
    }

    func testCancellingOneConcurrentSearchContinuationKeepsSharedArchiveAndUsesGlobalPermits() async throws {
        let summary = String(repeating: "持久化摘要内容。", count: 900)
        let html = Self.searchHTML([("Shared long result", summary, "https://example.com/shared")])
        let config = Self.searchConfiguration(maximumOutputBytes: 700)
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html")])
        let (producer, store) = makeSearchService(transport: transport, renderer: StubWebReadRenderer(), configuration: config)
        let scope = Self.scope(sessionID: "web-search-shared-reader-\(UUID().uuidString)")
        let produced = await producer.search(
            request: WebSearchRequest(query: "shared", limit: 1), scope: scope,
            callID: "web-search-shared-producer-\(UUID().uuidString)", batchID: "web-search-shared-producer-batch-\(UUID().uuidString)",
            deadline: Date().addingTimeInterval(3)
        )
        let documentID = try XCTUnwrap(decodeSearch(produced).documentID)

        let gate = SearchPermitGate()
        let pool = WebSearchPermitPool(maximumActive: 2, maximumQueued: 4, afterGrant: { await gate.pauseAfterGrant() })
        let service = WebSearchService(transport: transport, renderer: StubWebReadRenderer(), documentStore: store, configuration: config, permitPool: pool)
        let readerA = "web-search-reader-a-\(UUID().uuidString)"
        let readerABatch = "web-search-reader-a-batch-\(UUID().uuidString)"
        let readerB = "web-search-reader-b-\(UUID().uuidString)"
        let readerBBatch = "web-search-reader-b-batch-\(UUID().uuidString)"
        let taskA = Task {
            await service.search(request: WebSearchRequest(query: "shared", documentID: documentID, offset: 0, limit: 100, resultIndex: 0), scope: scope, callID: readerA, batchID: readerABatch, deadline: Date().addingTimeInterval(3))
        }
        for _ in 0..<100 {
            if await pool.activeCount >= 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let taskB = Task {
            await service.search(request: WebSearchRequest(query: "shared", documentID: documentID, offset: 0, limit: 100, resultIndex: 0), scope: scope, callID: readerB, batchID: readerBBatch, deadline: Date().addingTimeInterval(3))
        }
        for _ in 0..<100 {
            if await pool.activeCount >= 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let queuedTasks = (0..<4).map { index in
            Task {
                await service.search(
                    request: WebSearchRequest(query: "shared", documentID: documentID, offset: 0, limit: 100, resultIndex: 0),
                    scope: scope,
                    callID: "web-search-continuation-queued-\(index)-\(UUID().uuidString)",
                    batchID: "web-search-continuation-queued-batch-\(index)-\(UUID().uuidString)",
                    deadline: Date().addingTimeInterval(3)
                )
            }
        }
        for _ in 0..<100 {
            if await pool.queuedCount >= 4 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let permitsBeforeRelease = await pool.activeCount
        let queuedBeforeRelease = await pool.queuedCount
        XCTAssertEqual(permitsBeforeRelease, 2, "包括续读在内的全局搜索活动上限为 2")
        XCTAssertEqual(queuedBeforeRelease, 4, "续读共用全局最多 4 个排队位")

        service.cancel(callID: readerA, scope: scope, batchID: readerABatch)
        await gate.open()
        let outcomeA = await taskA.value
        let outcomeB = await taskB.value
        XCTAssertEqual(try decodeSearch(outcomeA).status, .cancelled)
        XCTAssertEqual(try decodeSearch(outcomeB).status, .partial)
        XCTAssertTrue(store.contains(id: documentID, scope: scope), "取消一个借用归档的续读者不得删除共享归档")
        for task in queuedTasks {
            let queuedOutcome = await task.value
            XCTAssertEqual(try decodeSearch(queuedOutcome).status, .partial)
        }
        let permitsAfterRelease = await pool.activeCount
        XCTAssertEqual(permitsAfterRelease, 0)
        service.endRequest(scope: scope)
    }

    func testWebSearchToolDispatchKeepsLargeJSONWholeAndStructured() async throws {
        let summary = String(repeating: "完整摘要 ", count: 3_000)
        let html = Self.searchHTML([("Large full result", summary, "https://example.com/full")])
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html")])
        let searchConfig = Self.searchConfiguration(maximumResponseBytes: 200_000, maximumOutputBytes: 100_000)
        let (service, _) = makeSearchService(transport: transport, renderer: StubWebReadRenderer(), configuration: searchConfig)
        let viewModel = AIChatViewModel()
        let sessionID = "web-search-agent-\(UUID().uuidString)"
        viewModel.sessionId = sessionID
        defer { viewModel.sessionId = nil }
        let toolUseID = "web-search-agent-call-\(UUID().uuidString)"
        viewModel.messages = [ChatMessage(
            role: .assistant,
            content: "",
            blocks: [AssistantBlock(kind: .browserTool(action: "web_search"), content: "", toolUseId: toolUseID)]
        )]
        viewModel.webSearchService = service
        let scope = Self.scope(sessionID: sessionID, userRequestID: "agent-search-request")
        let batchID = "web-search-agent-batch-\(UUID().uuidString)"
        service.beginBatch(id: batchID, sessionID: sessionID, scope: scope)
        let toolUse = AIChatViewModel.StreamResult.ToolEntry(
            id: toolUseID,
            name: "web_search",
            args: ["tool_title": "Find public sources", "query": "large result"],
            blockIdx: 0,
            metadata: nil,
            inputChunkRing: []
        )

        let outcome = await viewModel.executeSingleToolUse(
            tu: toolUse,
            msgIdx: 0,
            tools: viewModel.makeAgentTools(),
            batchBudget: AIChatViewModel.BatchImageBudget(initial: 0),
            webSearchBatchID: batchID,
            webSearchScope: scope,
            webSearchDeadline: Date().addingTimeInterval(2)
        )
        guard case let .toolResult(id, name, content, isError, _, _, _, _) = outcome.resultPart else {
            return XCTFail("web_search 派发必须返回标准 tool_result")
        }
        XCTAssertEqual(id, toolUseID)
        XCTAssertEqual(name, "web_search")
        XCTAssertFalse(isError)
        XCTAssertGreaterThan(content.count, AIChatViewModel.kMaxToolResultChars)
        let result = try decodeSearch(WebSearchOutcome(json: content, isError: false, status: .results, documentID: nil))
        XCTAssertEqual(result.results.first?.snippet, summary.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(viewModel.messages[0].blocks[0].content, content)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(content.utf8)))

        let repaired = WebSearchService.addingInputTruncationLimitation(
            to: WebSearchOutcome(json: content, isError: false, status: .results, documentID: nil),
            query: "large result"
        )
        let repairedResult = try decodeSearch(repaired)
        XCTAssertEqual(repairedResult.status, .partial)
        XCTAssertTrue(repairedResult.limitations.contains { $0.contains("自动修复") })
        XCTAssertEqual(repairedResult.results.first?.snippet, summary.trimmingCharacters(in: .whitespacesAndNewlines))
        service.finishBatch(id: batchID)
        service.endRequest(scope: scope)
    }

    func testSearchPreflightRejectionAndPreStartCancellationReturnValidJSON() async throws {
        let viewModel = AIChatViewModel()
        let rejectedID = "web-search-preflight-\(UUID().uuidString)"
        viewModel.messages = [ChatMessage(
            role: .assistant,
            content: "",
            blocks: [AssistantBlock(kind: .browserTool(action: "web_search"), content: "", toolUseId: rejectedID)]
        )]
        let rejected = await viewModel.executeSingleToolUse(
            tu: AIChatViewModel.StreamResult.ToolEntry(
                id: rejectedID, name: "web_search", args: ["tool_title": "Missing query"],
                blockIdx: 0, metadata: nil, inputChunkRing: []
            ),
            msgIdx: 0, tools: viewModel.makeAgentTools(), batchBudget: AIChatViewModel.BatchImageBudget(initial: 0)
        )
        guard case let .toolResult(_, _, rejectedContent, rejectedError, _, _, _, _) = rejected.resultPart else {
            return XCTFail("输入拒绝结果必须保留工具调用格式")
        }
        XCTAssertTrue(rejectedError)
        XCTAssertEqual(try decodeSearch(WebSearchOutcome(json: rejectedContent, isError: true, status: .failed, documentID: nil)).status, .failed)

        let cancelledID = "web-search-cancelled-\(UUID().uuidString)"
        viewModel.messages = [ChatMessage(
            role: .assistant,
            content: "",
            blocks: [AssistantBlock(kind: .browserTool(action: "web_search"), content: "", toolUseId: cancelledID)]
        )]
        viewModel.commandCancelledByUser = true
        defer { viewModel.commandCancelledByUser = false }
        let cancelled = await viewModel.executeSingleToolUse(
            tu: AIChatViewModel.StreamResult.ToolEntry(
                id: cancelledID, name: "web_search", args: ["tool_title": "Search", "query": "never sent"],
                blockIdx: 0, metadata: nil, inputChunkRing: []
            ),
            msgIdx: 0, tools: viewModel.makeAgentTools(), batchBudget: AIChatViewModel.BatchImageBudget(initial: 0)
        )
        guard case let .toolResult(_, _, cancelledContent, cancelledError, _, _, _, _) = cancelled.resultPart else {
            return XCTFail("取消结果必须保留工具调用格式")
        }
        XCTAssertFalse(cancelledError)
        XCTAssertEqual(try decodeSearch(WebSearchOutcome(json: cancelledContent, isError: false, status: .cancelled, documentID: nil)).status, .cancelled)
    }

    func testSearchInputTruncationRepairKeepsValidJSONAndMarksCoveragePartial() async throws {
        let html = Self.searchHTML([("Repaired query result", "A complete summary for the repaired query.", "https://example.com/repaired")])
        let transport = StubWebReadTransport(responses: ["/lite/": .init(body: html, mimeType: "text/html")])
        let (service, _) = makeSearchService(transport: transport, renderer: StubWebReadRenderer())
        let viewModel = AIChatViewModel()
        let sessionID = "web-search-repair-\(UUID().uuidString)"
        viewModel.sessionId = sessionID
        viewModel.webSearchService = service
        defer { viewModel.sessionId = nil }
        let toolUseID = "web-search-repair-call-\(UUID().uuidString)"
        viewModel.messages = [ChatMessage(
            role: .assistant,
            content: "",
            blocks: [AssistantBlock(kind: .browserTool(action: "web_search"), content: "", toolUseId: toolUseID)]
        )]
        let scope = Self.scope(sessionID: sessionID, userRequestID: "repair-request")
        let batchID = "web-search-repair-batch-\(UUID().uuidString)"
        service.beginBatch(id: batchID, sessionID: sessionID, scope: scope)
        let outcome = await viewModel.executeSingleToolUse(
            tu: AIChatViewModel.StreamResult.ToolEntry(
                id: toolUseID,
                name: "web_search",
                args: [:],
                blockIdx: 0,
                metadata: nil,
                inputChunkRing: [#"{"tool_title":"Search sources","query":"repaired query""#]
            ),
            msgIdx: 0,
            tools: viewModel.makeAgentTools(),
            batchBudget: AIChatViewModel.BatchImageBudget(initial: 0),
            webSearchBatchID: batchID,
            webSearchScope: scope,
            webSearchDeadline: Date().addingTimeInterval(2)
        )
        guard case let .toolResult(_, _, content, isError, _, _, _, _) = outcome.resultPart else {
            return XCTFail("修复后的 web_search 仍须返回标准 JSON tool_result")
        }
        XCTAssertFalse(isError)
        let result = try decodeSearch(WebSearchOutcome(json: content, isError: false, status: .partial, documentID: nil))
        XCTAssertEqual(result.query, "repaired query")
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.results.first?.url, "https://example.com/repaired")
        XCTAssertTrue(result.limitations.contains { $0.contains("自动修复") })
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(content.utf8)))
        service.finishBatch(id: batchID)
        service.endRequest(scope: scope)
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

    private static func searchConfiguration(
        totalTimeout: TimeInterval = 2,
        maximumResponseBytes: Int = 2 * 1024 * 1024,
        maximumResults: Int = 512,
        maximumOutputBytes: Int = 10 * 1024,
        maximumArchiveScalars: Int = 2_000_000,
        maximumArchiveBytes: Int = 2 * 1024 * 1024,
        maximumRedirects: Int = 6,
        maximumActiveSearches: Int = 2,
        maximumQueuedSearches: Int = 4,
        maximumDiagnostics: Int = 128
    ) -> WebSearchConfiguration {
        WebSearchConfiguration(
            totalTimeout: totalTimeout,
            maximumResponseBytes: maximumResponseBytes,
            maximumResults: maximumResults,
            maximumOutputBytes: maximumOutputBytes,
            maximumArchiveScalars: maximumArchiveScalars,
            maximumArchiveBytes: maximumArchiveBytes,
            maximumRedirects: maximumRedirects,
            maximumActiveSearches: maximumActiveSearches,
            maximumQueuedSearches: maximumQueuedSearches,
            maximumDiagnostics: maximumDiagnostics
        )
    }

    private static func searchHTML(
        _ entries: [(title: String, snippet: String, url: String)],
        className: String = "result-link",
        snippetClass: String = "result-snippet"
    ) -> String {
        let body = entries.map { entry in
            "<a class='\(className)' href=\"\(entry.url)\">\(entry.title)</a><div class='\(snippetClass)'>\(entry.snippet)</div>"
        }.joined(separator: "\n")
        return "<!doctype html><html><body>\(body)</body></html>"
    }

    private func makeSearchService(
        transport: StubWebReadTransport,
        renderer: any WebReadRendering,
        configuration: WebSearchConfiguration? = nil
    ) -> (WebSearchService, WebReadDocumentStore) {
        let storeConfiguration = Self.configuration(
            maximumResponseBytes: 2 * 1024 * 1024,
            maximumDocumentScalars: 2_000_000,
            maximumResultBytes: 12_000,
            maximumCachedBytes: 6 * 1024 * 1024,
            maximumCachedDocuments: 32
        )
        let store = WebReadDocumentStore(configuration: storeConfiguration)
        let service = WebSearchService(
            transport: transport,
            renderer: renderer,
            documentStore: store,
            configuration: configuration ?? Self.searchConfiguration()
        )
        return (service, store)
    }

    private func decodeSearch(_ outcome: WebSearchOutcome) throws -> WebSearchResult {
        try JSONDecoder().decode(WebSearchResult.self, from: XCTUnwrap(outcome.json.data(using: .utf8)))
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
        waitForTarget: Bool,
        preserveSearchStructure: Bool = false
    ) async throws -> WebReadRenderedPage {
        try await withThrowingTaskGroup(of: WebReadRenderedPage.self) { group in
            group.addTask {
                try await renderer.render(
                    url: url,
                    callID: callID,
                    deadline: deadline,
                    queryTarget: queryTarget,
                    waitForTarget: waitForTarget,
                    preserveSearchStructure: preserveSearchStructure
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

private final class WebSearchSnapshotHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "WebSearchSnapshotHTTPServer")
    private let html: Data
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<URL, Error>?

    init(html: String) throws {
        self.html = Data(html.utf8)
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(self.html.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: header + self.html, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port?.rawValue,
                          let url = URL(string: "http://127.0.0.1:\(port)/search") else {
                        self.finishStart(throwing: WebReadFailure.invalidURL)
                        return
                    }
                    self.finishStart(returning: url)
                case .failed(let error): self.finishStart(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func finishStart(returning url: URL) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(returning: url)
    }

    private func finishStart(throwing error: Error) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private actor SearchPermitGate {
    private var didPause = false
    private var isOpen = false
    private var pauseContinuations: [CheckedContinuation<Void, Never>] = []
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []

    func pauseAfterGrant() async {
        didPause = true
        let entered = enteredContinuations
        enteredContinuations.removeAll(keepingCapacity: true)
        entered.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            pauseContinuations.append(continuation)
        }
    }

    func waitUntilPaused() async {
        guard !didPause else { return }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let paused = pauseContinuations
        pauseContinuations.removeAll(keepingCapacity: true)
        paused.forEach { $0.resume() }
    }
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
    private var activeRequestCount = 0
    private var maximumConcurrentRequestCount = 0

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

    var maximumConcurrentRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumConcurrentRequestCount
    }

    func fetch(_ request: WebReadFetchRequest) async throws -> WebReadFetchedResponse {
        let response = recordAndFindResponse(for: request)
        defer { finishRequest() }
        guard let response else {
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
        activeRequestCount += 1
        maximumConcurrentRequestCount = max(maximumConcurrentRequestCount, activeRequestCount)
        let path = request.url.path
        if let exact = responses[path] { return exact }
        // Foundation URL.path may omit the terminal slash even when the URL's
        // serialized request target retains it. Treat only that routing
        // normalization as equivalent in this local transport stub.
        let slashVariant = path.hasSuffix("/") ? String(path.dropLast()) : path + "/"
        return responses[slashVariant]
    }

    private func finishRequest() {
        lock.lock()
        activeRequestCount = max(0, activeRequestCount - 1)
        lock.unlock()
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
    private(set) var renderedURLs: [URL] = []
    private(set) var searchStructureRequests: [Bool] = []
    private let renderedPage: WebReadRenderedPage?

    init(renderedPage: WebReadRenderedPage? = nil) {
        self.renderedPage = renderedPage
    }

    func render(
        url: URL,
        callID: String,
        deadline: Date,
        queryTarget: String?,
        waitForTarget: Bool,
        preserveSearchStructure: Bool = false
    ) async throws -> WebReadRenderedPage {
        renderCalls += 1
        renderedURLs.append(url)
        searchStructureRequests.append(preserveSearchStructure)
        if let renderedPage { return renderedPage }
        throw WebReadFailure.transport("此用例不应启动 WebKit 渲染")
    }

    func cancel(callID: String) {}
}

@MainActor
private final class DeadlineWebSearchRenderer: WebReadRendering {
    private(set) var renderCalls = 0

    func render(
        url: URL,
        callID: String,
        deadline: Date,
        queryTarget: String?,
        waitForTarget: Bool,
        preserveSearchStructure: Bool = false
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

@MainActor
private final class ResourceLimitedWebSearchRenderer: WebReadRendering {
    private(set) var renderCalls = 0

    func render(
        url: URL,
        callID: String,
        deadline: Date,
        queryTarget: String?,
        waitForTarget: Bool,
        preserveSearchStructure: Bool = false
    ) async throws -> WebReadRenderedPage {
        renderCalls += 1
        throw WebReadFailure.resourceLimit
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
        waitForTarget: Bool,
        preserveSearchStructure: Bool = false
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
