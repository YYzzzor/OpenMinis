import Foundation
import UIKit

actor WebSearchPermitPool {
    private struct Waiter {
        let id: String
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumActive: Int
    private let maximumQueued: Int
    private let afterGrant: (@Sendable () async -> Void)?
    private var activeIDs: Set<String> = []
    private var waiters: [Waiter] = []

    init(maximumActive: Int, maximumQueued: Int, afterGrant: (@Sendable () async -> Void)? = nil) {
        self.maximumActive = max(1, maximumActive)
        self.maximumQueued = max(0, maximumQueued)
        self.afterGrant = afterGrant
    }

    func acquire(id: String, deadline: Date) async throws {
        try Task.checkCancellation()
        guard deadline > Date() else { throw WebReadFailure.deadlineExceeded }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if activeIDs.count < maximumActive {
                    activeIDs.insert(id)
                    continuation.resume()
                } else if waiters.count < maximumQueued {
                    waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                } else {
                    continuation.resume(throwing: WebReadFailure.resourceLimit)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
        await afterGrant?()
        guard !Task.isCancelled else {
            // The slot may already have been promoted when cancellation races
            // with continuation resumption. Release that lease before throwing.
            release(id: id)
            throw WebReadFailure.cancelled
        }
    }

    func cancel(id: String) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: WebReadFailure.cancelled)
        promoteWaiters()
    }

    func release(id: String) {
        guard activeIDs.remove(id) != nil else { return }
        promoteWaiters()
    }

    var activeCount: Int { activeIDs.count }
    var queuedCount: Int { waiters.count }

    private func promoteWaiters() {
        while activeIDs.count < maximumActive, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            guard waiter.deadline > Date() else {
                waiter.continuation.resume(throwing: WebReadFailure.deadlineExceeded)
                continue
            }
            activeIDs.insert(waiter.id)
            waiter.continuation.resume()
        }
    }
}

@MainActor
final class WebSearchService {
    static let shared = WebSearchService(
        transport: URLSessionWebReadTransport(),
        renderer: WebReadRenderer(),
        documentStore: .shared,
        configuration: .conservative
    )

    private final class ActiveCall {
        let operationID: String
        let callID: String
        let batchID: String
        let scope: WebReadScope
        let deadline: Date
        let startedAt = Date()
        var cancelled = false
        var explicitlyStopped = false
        var timedOut = false
        var preservePartialAfterTimeout = false
        var resourceLimited = false
        var hasPermit = false
        var networkAttempts = 0
        var redirects = 0
        var responseBytes = 0
        var fallbackUsed = false
        var savedDocumentID: String?
        var borrowedDocumentID: String?
        var deadlineTask: Task<Void, Never>?

        init(operationID: String, callID: String, batchID: String, scope: WebReadScope, deadline: Date) {
            self.operationID = operationID
            self.callID = callID
            self.batchID = batchID
            self.scope = scope
            self.deadline = deadline
        }
    }

    private struct SearchCandidate {
        let extraction: WebSearchExtraction
        let retrievedAt: String?
        let wasTruncated: Bool
        let loadingIndicator: Bool
        let statusCode: Int
    }

    let configuration: WebSearchConfiguration
    private let transport: WebReadTransport
    private let renderer: WebReadRendering
    private let documentStore: WebReadDocumentStore
    private let permits: WebSearchPermitPool
    private var activeCalls: [String: ActiveCall] = [:]
    private var cancelledBatches: Set<String> = []
    private var memoryLimitedBatches: Set<String> = []
    private var batchSessions: [String: String] = [:]
    private var batchScopes: [String: Set<WebReadScope>] = [:]
    private(set) var recentDiagnostics: [WebSearchDiagnostic] = []
    private var memoryWarningObserver: NSObjectProtocol?
    private let logger = AppLogger(category: "WebSearch")

    init(
        transport: WebReadTransport,
        renderer: WebReadRendering,
        documentStore: WebReadDocumentStore,
        configuration: WebSearchConfiguration = .conservative,
        permitPool: WebSearchPermitPool? = nil
    ) {
        self.transport = transport
        self.renderer = renderer
        self.documentStore = documentStore
        self.configuration = configuration
        self.permits = permitPool ?? WebSearchPermitPool(
            maximumActive: configuration.maximumActiveSearches,
            maximumQueued: configuration.maximumQueuedSearches
        )
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in _ = self?.handleMemoryWarning() }
        }
    }

    deinit {
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
    }

    func beginBatch(id: String, sessionID: String, scope: WebReadScope? = nil) {
        guard !id.isEmpty else { return }
        batchSessions[id] = sessionID
        if let scope { batchScopes[id, default: []].insert(scope) }
    }

    func finishBatch(id: String) {
        cancelledBatches.remove(id)
        memoryLimitedBatches.remove(id)
        batchSessions.removeValue(forKey: id)
        batchScopes.removeValue(forKey: id)
    }

    func cancel(callID: String, scope: WebReadScope, batchID: String) {
        guard let call = activeCalls.values.first(where: {
            $0.callID == callID && $0.scope == scope && $0.batchID == batchID
        }) else { return }
        cancel(call)
    }

    func cancelBatch(_ id: String) {
        guard !id.isEmpty else { return }
        cancelledBatches.insert(id)
        for call in activeCalls.values where call.batchID == id { cancel(call) }
        for scope in batchScopes[id] ?? [] { documentStore.removeAll(scope: scope) }
    }

    func cancelSession(_ sessionID: String) {
        let batches = Set(batchSessions.compactMap { $0.value == sessionID ? $0.key : nil })
        for batchID in batches { cancelBatch(batchID) }
        for call in activeCalls.values where call.scope.sessionID == sessionID { cancel(call) }
        for batchID in batchSessions.compactMap({ $0.value == sessionID ? $0.key : nil }) {
            finishBatch(id: batchID)
        }
        documentStore.removeAll(sessionID: sessionID)
    }

    func endRequest(scope: WebReadScope) {
        let batches = batchScopes.compactMap { batchID, scopes in scopes.contains(scope) ? batchID : nil }
        for batchID in batches { cancelBatch(batchID) }
        for call in activeCalls.values where call.scope == scope { cancel(call) }
        documentStore.removeAll(scope: scope)
    }

    @discardableResult
    func handleMemoryWarning() -> (cancelledCalls: Int, queuedCalls: Int, removedDocuments: Int, releasedBytes: Int) {
        let calls = Array(activeCalls.values)
        let batches = Set(batchSessions.keys).union(calls.map(\.batchID))
        memoryLimitedBatches.formUnion(batches)
        for call in calls {
            call.resourceLimited = true
            cancel(call)
        }
        let documents = documentStore.count
        let bytes = documentStore.totalCachedBytes
        documentStore.removeAll()
        return (calls.count, calls.filter { !$0.hasPermit }.count, documents, bytes)
    }

    func search(
        request: WebSearchRequest,
        scope: WebReadScope,
        callID: String,
        batchID: String,
        deadline suppliedDeadline: Date? = nil
    ) async -> WebSearchOutcome {
        let deadline = suppliedDeadline ?? Date().addingTimeInterval(configuration.totalTimeout)
        guard !callID.isEmpty, !batchID.isEmpty, !scope.sessionID.isEmpty, !scope.userRequestID.isEmpty else {
            return Self.immediateOutcome(query: request.query, status: .failed, limitation: "搜索范围或调用标识无效。")
        }
        let ownsBatchLifecycle = batchSessions[batchID] == nil
        if ownsBatchLifecycle { batchSessions[batchID] = scope.sessionID }
        defer { if ownsBatchLifecycle { finishBatch(id: batchID) } }
        batchScopes[batchID, default: []].insert(scope)

        if memoryLimitedBatches.contains(batchID) {
            return Self.immediateOutcome(query: request.query, status: .failed, limitation: "系统内存压力已停止本批次网页搜索。")
        }
        guard !cancelledBatches.contains(batchID) else {
            return Self.immediateOutcome(query: request.query, status: .cancelled, limitation: "搜索在开始前已停止。")
        }
        guard deadline > Date() else {
            return Self.immediateOutcome(query: request.query, status: .failed, limitation: "搜索超过统一截止时间，未取得结果。")
        }

        if let documentID = request.documentID {
            return await performContinuation(
                request: request, scope: scope, callID: callID, batchID: batchID,
                deadline: deadline, documentID: documentID
            )
        }
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.unicodeScalars.count <= 512 else {
            return Self.immediateOutcome(query: query, status: .failed, limitation: "搜索关键词为空或超过 512 个 Unicode 字符，未发出网络请求。")
        }

        let maximumTrackedCalls = configuration.maximumActiveSearches + configuration.maximumQueuedSearches
        guard activeCalls.count < maximumTrackedCalls else {
            return Self.immediateOutcome(query: query, status: .failed, limitation: "网页搜索活动项与排队项已达到资源上限。")
        }

        let operationID = "websearch_" + UUID().uuidString.lowercased()
        let call = ActiveCall(operationID: operationID, callID: callID, batchID: batchID, scope: scope, deadline: deadline)
        activeCalls[operationID] = call
        call.deadlineTask = Task { @MainActor [weak self, weak call] in
            guard let self, let call else { return }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(remaining, 3_600) * 1_000_000_000))
            }
            guard !Task.isCancelled, self.isActive(call) else { return }
            call.timedOut = true
            self.cancel(call, explicitlyStopped: false)
        }

        var outcome = await withTaskCancellationHandler {
            await self.performSearch(request: request, query: query, scope: scope, call: call)
        } onCancel: {
            Task { @MainActor [weak self, weak call] in
                guard let self, let call else { return }
                self.cancel(call)
            }
        }

        if call.resourceLimited {
            removeSavedDocument(for: call)
            outcome = Self.immediateOutcome(query: query, status: .failed, limitation: "系统内存压力已停止网页搜索。")
        } else if Task.isCancelled || call.explicitlyStopped || cancelledBatches.contains(batchID) {
            cancel(call)
            removeSavedDocument(for: call)
            outcome = Self.immediateOutcome(query: query, status: .cancelled, limitation: "网页搜索已取消。")
        } else if call.timedOut || Date() >= deadline {
            call.timedOut = true
            let canKeepPartial = call.preservePartialAfterTimeout
                && outcome.status == .partial
                && !call.explicitlyStopped
                && !Task.isCancelled
                && !cancelledBatches.contains(batchID)
            cancel(call, explicitlyStopped: false)
            if !canKeepPartial {
                removeSavedDocument(for: call)
                outcome = Self.immediateOutcome(query: query, status: .failed, limitation: "网页搜索达到统一截止时间；未启动后续回退。")
            }
        }

        call.deadlineTask?.cancel()
        call.deadlineTask = nil
        activeCalls.removeValue(forKey: operationID)
        recordDiagnostic(call, status: outcome.status)
        return outcome
    }

    private func performSearch(
        request: WebSearchRequest,
        query: String,
        scope: WebReadScope,
        call: ActiveCall
    ) async -> WebSearchOutcome {
        do {
            try await permits.acquire(id: call.operationID, deadline: call.deadline)
            call.hasPermit = true
        } catch {
            if call.cancelled || isCancellation(error) {
                return Self.immediateOutcome(query: query, status: .cancelled, limitation: "排队期间网页搜索已取消。")
            }
            let note = call.timedOut || Date() >= call.deadline
                ? "网页搜索在队列中达到统一截止时间。"
                : "网页搜索队列已达到资源上限。"
            return Self.immediateOutcome(query: query, status: .failed, limitation: note)
        }

        var outcome: WebSearchOutcome
        do {
            outcome = try await searchWithFallback(query: query, request: request, scope: scope, call: call)
        } catch {
            outcome = if call.cancelled || isCancellation(error) {
                Self.immediateOutcome(query: query, status: .cancelled, limitation: "网页搜索已取消。")
            } else {
                Self.immediateOutcome(query: query, status: .failed, limitation: failureLimitation(error))
            }
        }
        call.hasPermit = false
        await permits.release(id: call.operationID)
        return outcome
    }

    private func performContinuation(
        request: WebSearchRequest,
        scope: WebReadScope,
        callID: String,
        batchID: String,
        deadline: Date,
        documentID: String
    ) async -> WebSearchOutcome {
        let maximumTrackedCalls = configuration.maximumActiveSearches + configuration.maximumQueuedSearches
        guard activeCalls.count < maximumTrackedCalls else {
            return Self.immediateOutcome(query: request.query, status: .failed, limitation: "网页搜索活动项与排队项已达到资源上限。")
        }
        let operationID = "websearch_" + UUID().uuidString.lowercased()
        let call = ActiveCall(operationID: operationID, callID: callID, batchID: batchID, scope: scope, deadline: deadline)
        activeCalls[operationID] = call
        call.deadlineTask = Task { @MainActor [weak self, weak call] in
            guard let self, let call else { return }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(remaining, 3_600) * 1_000_000_000))
            }
            guard !Task.isCancelled, self.isActive(call) else { return }
            call.timedOut = true
            self.cancel(call, explicitlyStopped: false)
        }

        var outcome: WebSearchOutcome
        do {
            try await permits.acquire(id: call.operationID, deadline: deadline)
            call.hasPermit = true
            outcome = await continuationOutcome(request: request, scope: scope, documentID: documentID, call: call)
            call.hasPermit = false
            await permits.release(id: call.operationID)
        } catch {
            call.hasPermit = false
            if call.cancelled || isCancellation(error) {
                outcome = Self.immediateOutcome(query: request.query, status: .cancelled, limitation: "搜索续读在队列中取消。")
            } else if call.timedOut || Date() >= deadline {
                call.timedOut = true
                outcome = Self.immediateOutcome(query: request.query, status: .failed, limitation: "搜索续读在队列中达到统一截止时间。")
            } else {
                outcome = Self.immediateOutcome(query: request.query, status: .failed, limitation: "搜索续读队列已达到资源上限。")
            }
        }
        if call.resourceLimited {
            removeSavedDocument(for: call)
            outcome = Self.immediateOutcome(query: request.query, status: .failed, limitation: "系统内存压力已停止网页搜索续读。")
        } else if Task.isCancelled || call.explicitlyStopped || cancelledBatches.contains(batchID) {
            cancel(call)
            removeSavedDocument(for: call)
            outcome = Self.immediateOutcome(query: request.query, status: .cancelled, limitation: "网页搜索续读已取消。")
        } else if call.timedOut || Date() >= deadline {
            call.timedOut = true
            cancel(call, explicitlyStopped: false)
            // A continuation borrows a previously committed archive. A local
            // timeout only ends this read; it must not remove shared data that
            // sibling readers in the same scope may still be using.
            removeSavedDocument(for: call)
            outcome = Self.immediateOutcome(query: request.query, status: .failed, limitation: "网页搜索续读达到统一截止时间。")
        } else if let borrowedDocumentID = call.borrowedDocumentID,
                  !documentStore.contains(id: borrowedDocumentID, scope: scope) {
            outcome = Self.immediateOutcome(query: request.query, status: .cancelled, limitation: "续读期间文档作用域已结束，迟到结果已丢弃。")
        }
        call.deadlineTask?.cancel()
        activeCalls.removeValue(forKey: operationID)
        recordDiagnostic(call, status: outcome.status)
        return outcome
    }

    private func searchWithFallback(
        query: String,
        request: WebSearchRequest,
        scope: WebReadScope,
        call: ActiveCall
    ) async throws -> WebSearchOutcome {
        guard isActive(call), Date() < call.deadline else { throw WebReadFailure.cancelled }
        let liteURL = try searchURL(host: "lite.duckduckgo.com", path: "/lite/", query: query)
        var initial: SearchCandidate?
        var initialError: Error?
        call.networkAttempts += 1
        do {
            let response = try await transport.fetch(WebReadFetchRequest(
                url: liteURL,
                callID: call.operationID,
                deadline: call.deadline,
                maximumBytes: configuration.maximumResponseBytes,
                maximumRedirects: configuration.maximumRedirects,
                userAgent: Self.searchUserAgent,
                allowsNonSuccessBody: true
            ))
            guard isActive(call), Date() < call.deadline else { throw WebReadFailure.cancelled }
            call.redirects += response.redirectCount
            call.responseBytes += response.bytes.count
            let html = String(data: response.bytes, encoding: .utf8)
                ?? String(data: response.bytes, encoding: .isoLatin1)
                ?? ""
            let extraction = try await extract(html: html, baseURL: response.finalURL, call: call)
            initial = SearchCandidate(
                extraction: extraction,
                retrievedAt: Self.iso8601(response.retrievedAt),
                wasTruncated: response.bodyWasTruncated,
                loadingIndicator: false,
                statusCode: response.statusCode
            )
        } catch {
            if !isActive(call) || isCancellation(error) { throw WebReadFailure.cancelled }
            initialError = error
        }

        guard isActive(call), Date() < call.deadline else { throw WebReadFailure.cancelled }
        if let initial,
           initial.extraction.explicitlyNoResults,
           !initial.extraction.verificationRequired,
           initial.extraction.results.isEmpty,
           (200..<300).contains(initial.statusCode),
           !initial.wasTruncated,
           !initial.loadingIndicator,
           !request.inputWasTruncated {
            return await saveAndFormat(
                request: request, query: query, scope: scope, call: call,
                candidates: [initial], preferred: initial,
                limitations: [], status: .noResults
            )
        }

        if let initial,
           isUsable(initial),
           !initial.wasTruncated,
           (200..<300).contains(initial.statusCode) {
            return await saveAndFormat(
                request: request, query: query, scope: scope, call: call,
                candidates: [initial], preferred: initial,
                limitations: request.inputWasTruncated ? [Self.inputTruncationLimitation] : [],
                status: request.inputWasTruncated ? .partial : .results
            )
        }

        var limitations: [String] = request.inputWasTruncated ? [Self.inputTruncationLimitation] : []
        if let initialError {
            limitations.append("DuckDuckGo Lite HTTP 读取失败；在剩余截止时间内尝试一次同引擎匿名 HTML 渲染回退。")
            limitations.append(failureLimitation(initialError))
        } else if let initial {
            if initial.extraction.verificationRequired {
                limitations.append("DuckDuckGo 要求完成验证；应用不会自动解验证码，并会在剩余预算内尝试一次同引擎匿名 HTML 渲染。")
            } else if initial.extraction.results.isEmpty {
                limitations.append("DuckDuckGo Lite 响应没有可识别的结果条目；在剩余截止时间内尝试一次同引擎匿名 HTML 渲染回退。")
            } else {
                limitations.append("DuckDuckGo Lite 响应包含部分条目或不完整结构；在剩余截止时间内尝试一次同引擎匿名 HTML 渲染回退。")
            }
        }

        var candidates = initial.map { [$0] } ?? []
        var fallbackError: Error?
        var renderedCandidate: SearchCandidate?
        if call.networkAttempts < 2, isActive(call), Date() < call.deadline {
            call.networkAttempts += 1
            call.fallbackUsed = true
            let htmlURL = try searchURL(host: "html.duckduckgo.com", path: "/html/", query: query)
            let acquired = BrowserTabPoolRegistry.shared.acquireAnonymousWebReadRenderer(callID: call.operationID)
            if acquired {
                defer { BrowserTabPoolRegistry.shared.releaseAnonymousWebReadRenderer(callID: call.operationID) }
                do {
                    let rendered = try await renderer.render(
                        url: htmlURL,
                        callID: call.operationID,
                        deadline: call.deadline,
                        queryTarget: nil,
                        waitForTarget: false,
                        preserveSearchStructure: true
                    )
                    guard isActive(call), Date() < call.deadline else { throw WebReadFailure.cancelled }
                    let extraction = try await extract(html: rendered.html, baseURL: rendered.finalURL, call: call)
                    renderedCandidate = SearchCandidate(
                        extraction: extraction,
                        retrievedAt: Self.iso8601(rendered.retrievedAt),
                        wasTruncated: rendered.htmlWasTruncated,
                        loadingIndicator: rendered.hasLoadingIndicator || rendered.targetWaitExpired,
                        statusCode: 200
                    )
                    if let renderedCandidate { candidates.append(renderedCandidate) }
                } catch {
                    if call.resourceLimited || Task.isCancelled || call.explicitlyStopped
                        || cancelledBatches.contains(call.batchID) {
                        throw WebReadFailure.cancelled
                    }
                    if call.timedOut || Date() >= call.deadline {
                        call.timedOut = true
                        if !mergedResults(from: candidates).isEmpty {
                            call.preservePartialAfterTimeout = true
                            let results = mergedResults(from: candidates)
                            return await deadlinePartialOutcome(
                                query: query,
                                candidates: candidates,
                                preferred: initial,
                                results: results,
                                limitations: Self.unique(limitations + [
                                    "统一截止时间已到；保留截止前取得的结果，未完成匿名 HTML 回退。"
                                ]),
                                call: call
                            )
                        } else {
                            throw WebReadFailure.deadlineExceeded
                        }
                    } else if !isActive(call) || isCancellation(error) {
                        throw WebReadFailure.cancelled
                    } else {
                        fallbackError = error
                    }
                }
            } else {
                fallbackError = WebReadFailure.resourceLimit
            }
        } else {
            fallbackError = WebReadFailure.deadlineExceeded
        }

        guard (isActive(call) && Date() < call.deadline) || canContinueFormatting(call) else {
            throw WebReadFailure.cancelled
        }
        let results = mergedResults(from: candidates)
        let anchorsTruncated = candidates.contains { $0.extraction.resultsTruncated }
        if anchorsTruncated {
            limitations.append("DuckDuckGo 当前页超过安全解析上限；已解析的条目保留，未解析部分明确标记为缺口。")
        }
        let preferred = renderedCandidate ?? initial
        let hasVerification = candidates.contains { $0.extraction.verificationRequired }
        let hasLoading = candidates.contains { $0.loadingIndicator || $0.wasTruncated }
        let hasCompleteExplicitNoResults = candidates.contains {
            $0.extraction.explicitlyNoResults
                && !$0.extraction.verificationRequired
                && !$0.wasTruncated
                && !$0.loadingIndicator
                && (200..<300).contains($0.statusCode)
        }
        let hasRejectedAnchors = candidates.contains { $0.extraction.rejectedResultAnchors > 0 }
        if hasRejectedAnchors {
            let rejectedCount = candidates.reduce(0) { $0 + $1.extraction.rejectedResultAnchors }
            limitations.append("搜索页含有 \(rejectedCount) 个缺少标题或安全 HTTP(S) 来源的结果链接；这些链接未返回，并已标记结果不完整。")
        }
        if call.preservePartialAfterTimeout {
            limitations.append("统一截止时间已到；保留截止前取得的结果，未完成匿名 HTML 回退。")
        }
        var status: WebSearchStatus
        if !results.isEmpty {
            let chosen = preferred
            status = call.preservePartialAfterTimeout
                ? .partial
                : (!hasRejectedAnchors && !anchorsTruncated
                && (chosen.map { isUsable($0) && !$0.wasTruncated && !$0.loadingIndicator } ?? false)
                ? .results : .partial)
            if hasVerification {
                limitations.append("某次匿名响应要求验证；另一次尝试仍提供了可用结果，未自动完成挑战。")
            }
            if hasLoading { limitations.append("响应正文被截断或渲染等待结束时仍有加载标记；结果可能不完整。") }
            if fallbackError != nil { limitations.append("同引擎匿名 HTML 渲染回退未完成；仅返回已取得的条目。") }
        } else if let chosen = preferred,
                  chosen.extraction.explicitlyNoResults,
                  !chosen.extraction.verificationRequired,
                  !chosen.wasTruncated,
                  !chosen.loadingIndicator,
                  (200..<300).contains(chosen.statusCode) {
            status = .noResults
            limitations.append("最终同引擎响应明确标示当前结果页无结果。")
            if hasVerification { limitations.append("另一次匿名响应要求验证；应用没有自动完成挑战。") }
        } else if hasVerification {
            status = .verificationRequired
            limitations.append("匿名 HTTP 或渲染响应仍显示验证页面；没有自动完成挑战。")
        } else if hasCompleteExplicitNoResults {
            status = .noResults
            limitations.append("DuckDuckGo HTML 页面明确显示当前结果页无结果。")
        } else {
            status = .failed
            limitations.append(fallbackError.map(failureLimitation) ?? "Lite 与 HTML 页面均没有可识别的公开搜索结果。")
        }
        if request.inputWasTruncated && (status == .results || status == .noResults) {
            status = .partial
        }
        if let initial, !(200..<300).contains(initial.statusCode) {
            limitations.append("DuckDuckGo Lite 返回 HTTP \(initial.statusCode)。")
        }
        if let preferred, preferred.extraction.nextPageURL != nil {
            limitations.append("只覆盖 DuckDuckGo 当前结果页；下一页入口已保留，尚未请求下一页。")
        } else {
            limitations.append("只覆盖 DuckDuckGo 当前结果页；没有继续请求后续结果页。")
        }

        return await saveAndFormat(
            request: request, query: query, scope: scope, call: call,
            candidates: candidates,
            preferred: preferred,
            resultsOverride: results,
            limitations: Self.unique(limitations),
            status: status
        )
    }

    private func extract(html: String, baseURL: URL, call: ActiveCall) async throws -> WebSearchExtraction {
        guard isActive(call) else { throw WebReadFailure.cancelled }
        let maximumResults = configuration.maximumResults
        let extraction = try await Task.detached(priority: .userInitiated) {
            WebSearchHTMLExtractor.extract(html: html, baseURL: baseURL, maximumResults: maximumResults)
        }.value
        guard isActive(call) else { throw WebReadFailure.cancelled }
        return extraction
    }

    private func deadlinePartialOutcome(
        query: String,
        candidates: [SearchCandidate],
        preferred: SearchCandidate?,
        results: [WebSearchEntry],
        limitations: [String],
        call: ActiveCall
    ) async -> WebSearchOutcome {
        guard canEmitTimedOutPartial(call) else {
            return Self.immediateOutcome(query: query, status: .cancelled, limitation: "停止期间丢弃了迟到的部分搜索结果。")
        }
        let selected = preferred ?? candidates.first
        let nextPage = selected?.extraction
        let baseArchive = WebSearchArchive(
            query: query,
            engine: "duckduckgo_lite",
            status: .partial,
            retrievedAt: selected?.retrievedAt,
            results: results,
            limitations: limitations,
            nextPageURL: nextPage?.nextPageURL,
            nextPageMethod: nextPage?.nextPageMethod,
            nextPageStart: nextPage?.nextPageStart,
            nextPageParameters: nextPage?.nextPageParameters,
            coverage: "统一截止时间前取得了部分 DuckDuckGo 当前页结果；没有完成后续回退。"
        )
        var low = 1
        var high = results.count
        var bestJSON: String?
        var bestCount = 0
        while low <= high && canEmitTimedOutPartial(call) {
            let count = low + (high - low) / 2
            let omitted = results.count - count
            var notes = limitations
            if omitted > 0 {
                notes.append("另有 \(omitted) 条已取得结果未能在输出预算内回传；超时结果未存入缓存，不能续读。")
            }
            let archive = WebSearchArchive(
                query: baseArchive.query,
                engine: baseArchive.engine,
                status: .partial,
                retrievedAt: baseArchive.retrievedAt,
                results: results,
                limitations: Self.unique(notes),
                nextPageURL: baseArchive.nextPageURL,
                nextPageMethod: baseArchive.nextPageMethod,
                nextPageStart: baseArchive.nextPageStart,
                nextPageParameters: baseArchive.nextPageParameters,
                coverage: baseArchive.coverage
            )
            let payload = Self.payload(
                archive: archive,
                results: Array(results.prefix(count)),
                documentID: nil,
                continuation: nil
            )
            if let json = await Self.encodeOffMain(payload),
               canEmitTimedOutPartial(call),
               json.utf8.count <= configuration.maximumOutputBytes {
                bestJSON = json
                bestCount = count
                low = count + 1
            } else {
                high = count - 1
            }
        }
        guard canEmitTimedOutPartial(call) else {
            return Self.immediateOutcome(query: query, status: .cancelled, limitation: "停止期间丢弃了迟到的部分搜索结果。")
        }
        if let bestJSON, bestCount > 0 {
            return WebSearchOutcome(json: bestJSON, isError: false, status: .partial, documentID: nil)
        }
        return Self.immediateOutcome(
            query: query,
            status: .partial,
            limitation: "截止前已取得的 \(results.count) 条结果均超过单次输出预算；超时结果未存入缓存，因此没有可续读编号。"
        )
    }

    private func isUsable(_ candidate: SearchCandidate) -> Bool {
        candidate.extraction.hasResultStructure
            && !candidate.extraction.results.isEmpty
            && !candidate.extraction.verificationRequired
            && !candidate.extraction.resultsTruncated
            && candidate.extraction.rejectedResultAnchors == 0
            && (200..<300).contains(candidate.statusCode)
    }

    private func mergedResults(from candidates: [SearchCandidate]) -> [WebSearchEntry] {
        var resultByURL: [String: WebSearchEntry] = [:]
        var order: [String] = []
        for candidate in candidates {
            for result in candidate.extraction.results {
                if resultByURL[result.url] == nil { order.append(result.url) }
                if let existing = resultByURL[result.url],
                   (existing.snippet?.unicodeScalars.count ?? 0) >= (result.snippet?.unicodeScalars.count ?? 0) {
                    continue
                }
                resultByURL[result.url] = result
            }
        }
        return order.compactMap { resultByURL[$0] }
    }

    private func saveAndFormat(
        request: WebSearchRequest,
        query: String,
        scope: WebReadScope,
        call: ActiveCall,
        candidates: [SearchCandidate],
        preferred: SearchCandidate?,
        resultsOverride: [WebSearchEntry]? = nil,
        limitations: [String],
        status: WebSearchStatus
    ) async -> WebSearchOutcome {
        guard canContinueFormatting(call) else {
            return Self.immediateOutcome(query: query, status: .cancelled, limitation: "网页搜索已取消，迟到结果已丢弃。")
        }
        let results = resultsOverride ?? mergedResults(from: candidates)
        let selected = preferred ?? candidates.first
        let nextPage = selected?.extraction
        let coverage = nextPage?.nextPageURL != nil
            ? "已解析 DuckDuckGo 当前结果页；后续页面尚未请求。"
            : "已解析 DuckDuckGo 当前结果页；后续页面尚未请求。"
        let archive = WebSearchArchive(
            query: query,
            engine: "duckduckgo_lite",
            status: status,
            retrievedAt: selected?.retrievedAt,
            results: results,
            limitations: limitations,
            nextPageURL: nextPage?.nextPageURL,
            nextPageMethod: nextPage?.nextPageMethod,
            nextPageStart: nextPage?.nextPageStart,
            nextPageParameters: nextPage?.nextPageParameters,
            coverage: coverage
        )
        let fullPayload = Self.payload(archive: archive, results: results, documentID: nil, continuation: nil)
        let fullJSON = await Self.encodeOffMain(fullPayload)
        guard canContinueFormatting(call) else {
            return Self.immediateOutcome(query: query, status: .cancelled, limitation: "网页搜索已取消，未保存迟到结果。")
        }
        let requestedLimit = request.limit.map { max(1, min($0, configuration.maximumResults)) }
        let needsContinuation = results.count > (requestedLimit ?? results.count)
            || (fullJSON?.utf8.count ?? 0) > configuration.maximumOutputBytes
        guard needsContinuation else {
            guard let fullJSON else {
                return Self.immediateOutcome(query: query, status: .failed, limitation: "网页搜索结果无法编码为 JSON。")
            }
            return WebSearchOutcome(json: fullJSON, isError: status == .failed, status: status, documentID: nil)
        }

        guard canContinueFormatting(call) else {
            return Self.immediateOutcome(query: query, status: .cancelled, limitation: "网页搜索已取消，未保存迟到结果。")
        }
        guard let archiveJSON = await Self.encodeOffMain(archive),
              canContinueFormatting(call),
              archiveJSON.unicodeScalars.count <= configuration.maximumArchiveScalars,
              archiveJSON.utf8.count <= configuration.maximumArchiveBytes,
              archiveJSON.utf8.count <= documentStore.configuration.maximumCachedBytes else {
            let limitation = "完整当前页归档超过匿名存储预算；本次只返回预算内条目，未创建不可续读的编号。"
            let partialArchive = WebSearchArchive(
                query: archive.query, engine: archive.engine, status: .partial,
                retrievedAt: archive.retrievedAt, results: archive.results,
                limitations: Self.unique(archive.limitations + [limitation]),
                nextPageURL: archive.nextPageURL, nextPageMethod: archive.nextPageMethod,
                nextPageStart: archive.nextPageStart, nextPageParameters: archive.nextPageParameters,
                coverage: archive.coverage
            )
            var low = 1
            var high = results.count
            var bestJSON: String?
            var bestCount = 0
            while low <= high && canContinueFormatting(call) {
                let prefixCount = low + (high - low) / 2
                let omitted = results.count - prefixCount
                let notedArchive = WebSearchArchive(
                    query: archive.query, engine: archive.engine, status: .partial,
                    retrievedAt: archive.retrievedAt, results: archive.results,
                    limitations: Self.unique(archive.limitations + [limitation, "因匿名归档预算不足，未保存的其余 \(omitted) 条结果无法续读。"]),
                    nextPageURL: archive.nextPageURL, nextPageMethod: archive.nextPageMethod,
                    nextPageStart: archive.nextPageStart, nextPageParameters: archive.nextPageParameters,
                    coverage: archive.coverage
                )
                let payload = Self.payload(archive: notedArchive, results: Array(results.prefix(prefixCount)), documentID: nil, continuation: nil)
                if let json = await Self.encodeOffMain(payload),
                   canContinueFormatting(call),
                   json.utf8.count <= configuration.maximumOutputBytes {
                    bestJSON = json
                    bestCount = prefixCount
                    low = prefixCount + 1
                } else {
                    high = prefixCount - 1
                }
            }
            if let bestJSON, bestCount > 0 {
                return WebSearchOutcome(json: bestJSON, isError: false, status: .partial, documentID: nil)
            }
            return Self.immediateOutcome(query: query, status: .partial, limitation: limitation)
        }
        let document = documentStore.save(
            content: archiveJSON,
            scope: scope,
            url: "https://lite.duckduckgo.com/lite/",
            title: query,
            retrievedAt: archive.retrievedAt,
            limitations: limitations,
            requestedURL: nil,
            sourceNote: "DuckDuckGo Lite 匿名搜索结果归档",
            resources: [],
            contentIsComplete: true,
            kind: .webSearch,
            maximumScalars: configuration.maximumArchiveScalars
        )
        guard document.contentIsComplete, document.content == archiveJSON,
              let saved = documentStore.document(id: document.id, scope: scope) else {
            documentStore.remove(id: document.id, scope: scope)
            return Self.immediateOutcome(query: query, status: results.isEmpty ? status : .partial,
                limitation: "结果缓存没有完整保存；未提供不可续读的编号。")
        }
        guard let restored = await Self.decodeArchive(saved.content), canContinueFormatting(call) else {
            documentStore.remove(id: document.id, scope: scope)
            return Self.immediateOutcome(query: query, status: .cancelled, limitation: "归档解码期间搜索已取消。")
        }
        call.savedDocumentID = document.id
        return await pageOutcome(archive: restored, documentID: document.id, start: 0, requestedLimit: requestedLimit, call: call)
    }

    private func continuationOutcome(request: WebSearchRequest, scope: WebReadScope, documentID: String, call: ActiveCall) async -> WebSearchOutcome {
        guard isActive(call), Date() < call.deadline, !Task.isCancelled else {
            return Self.immediateOutcome(query: request.query, status: .cancelled, limitation: "搜索续读已停止或超过截止时间。")
        }
        guard let document = documentStore.document(id: documentID, scope: scope),
              document.kind == .webSearch, document.contentIsComplete else {
            return Self.immediateOutcome(query: request.query, status: .failed,
                limitation: "document_id 不存在、已过期或不属于当前会话、请求与匿名身份。")
        }
        call.borrowedDocumentID = documentID
        guard let archive = await Self.decodeArchive(document.content), isActive(call), Date() < call.deadline, !Task.isCancelled,
              documentStore.contains(id: documentID, scope: scope) else {
            return Self.immediateOutcome(query: request.query, status: .cancelled, limitation: "搜索归档续读已取消。")
        }
        if let suppliedQuery = request.query.nilIfBlank,
           suppliedQuery.caseInsensitiveCompare(archive.query) != .orderedSame {
            return Self.immediateOutcome(query: archive.query, status: .failed,
                limitation: "续读关键词与已保存搜索不匹配，未读取其他文档。")
        }
        let limit = request.limit.map { max(1, min($0, configuration.maximumResults)) }
        if let resultIndex = request.resultIndex {
            return await resultFragmentOutcome(
                archive: archive, documentID: documentID, resultIndex: resultIndex,
                start: max(0, request.offset ?? 0), requestedLimit: limit, call: call
            )
        }
        let start = max(0, request.offset ?? 0)
        return await pageOutcome(archive: archive, documentID: documentID, start: start, requestedLimit: limit, call: call)
    }

    private func pageOutcome(
        archive: WebSearchArchive,
        documentID: String,
        start requestedStart: Int,
        requestedLimit: Int?,
        call: ActiveCall? = nil
    ) async -> WebSearchOutcome {
        let results = archive.results
        let start = min(max(0, requestedStart), results.count)
        var low = start + 1
        var high = min(results.count, start + (requestedLimit ?? configuration.maximumResults))
        var best: (result: WebSearchResult, json: String)?
        while low <= high && (call.map(canContinueFormatting) ?? true) {
            let end = low + (high - low) / 2
            let slice = Array(results[start..<end])
            let continuation = end < results.count
                ? WebSearchContinuation(start: start, end: end, savedEnd: results.count, nextOffset: end)
                : WebSearchContinuation(start: start, end: end, savedEnd: results.count, nextOffset: nil)
            let result = Self.payload(archive: archive, results: slice, documentID: end < results.count ? documentID : nil, continuation: continuation)
            if let json = await Self.encodeOffMain(result),
               (call.map(canContinueFormatting) ?? true), json.utf8.count <= configuration.maximumOutputBytes {
                best = (result, json)
                low = end + 1
            } else {
                high = end - 1
            }
        }
        if call.map({ !canContinueFormatting($0) }) == true {
            return Self.immediateOutcome(query: archive.query, status: .cancelled, limitation: "结果分页期间搜索已停止，迟到 JSON 已丢弃。")
        }
        if let best {
            let isError = best.result.status == .failed || best.result.status == .verificationRequired
            return WebSearchOutcome(json: best.json, isError: isError, status: best.result.status, documentID: best.result.documentID)
        }
        guard start < results.count else {
            return Self.immediateOutcome(query: archive.query, status: .partial, limitation: "结果续读位置已超出归档范围。")
        }
        return await resultFragmentOutcome(archive: archive, documentID: documentID, resultIndex: start, start: 0, requestedLimit: nil, call: call)
    }

    private func resultFragmentOutcome(
        archive: WebSearchArchive,
        documentID: String,
        resultIndex: Int,
        start: Int,
        requestedLimit: Int?,
        call: ActiveCall? = nil
    ) async -> WebSearchOutcome {
        guard archive.results.indices.contains(resultIndex),
              let serializedEntry = await Self.encodeOffMain(archive.results[resultIndex]) else {
            return Self.immediateOutcome(query: archive.query, status: .failed, limitation: "结果片段索引无效或已过期。")
        }
        let scalars = Array(serializedEntry.unicodeScalars)
        let fragmentStart = min(max(0, start), scalars.count)
        var low = 1
        var high = min(scalars.count - fragmentStart, requestedLimit ?? 4_096)
        var best: (result: WebSearchResult, json: String)?
        while low <= high && (call.map(canContinueFormatting) ?? true) {
            let length = low + (high - low) / 2
            let end = fragmentStart + length
            let content = String(String.UnicodeScalarView(scalars[fragmentStart..<end]))
            let hasMoreFragments = end < scalars.count
            let hasMoreResults = resultIndex + 1 < archive.results.count
            let fragment = WebSearchResultFragment(
                resultIndex: resultIndex,
                start: fragmentStart,
                end: end,
                savedEnd: scalars.count,
                nextOffset: hasMoreFragments ? end : nil,
                contentFormat: "web_search_entry_json",
                content: content
            )
            let result = WebSearchResult(
                query: archive.query,
                engine: archive.engine,
                status: .partial,
                retrievedAt: archive.retrievedAt,
                results: [],
                limitations: Self.unique(archive.limitations + ["第 \(resultIndex + 1) 条结果以 JSON Unicode 标量片段续读；按 start/end 拼接 content 后解析完整条目。"]),
                documentID: hasMoreFragments || hasMoreResults ? documentID : nil,
                continuation: nil,
                resultFragment: fragment,
                nextPageURL: archive.nextPageURL,
                nextPageMethod: archive.nextPageMethod,
                nextPageStart: archive.nextPageStart,
                nextPageParameters: archive.nextPageParameters,
                coverage: archive.coverage
            )
            if let json = await Self.encodeOffMain(result),
               (call.map(canContinueFormatting) ?? true), json.utf8.count <= configuration.maximumOutputBytes {
                best = (result, json)
                low = length + 1
            } else {
                high = length - 1
            }
        }
        if call.map({ !canContinueFormatting($0) }) == true {
            return Self.immediateOutcome(query: archive.query, status: .cancelled, limitation: "结果片段期间搜索已停止，迟到 JSON 已丢弃。")
        }
        if let best {
            return WebSearchOutcome(json: best.json, isError: false, status: .partial, documentID: best.result.documentID)
        }
        return Self.immediateOutcome(query: archive.query, status: .partial, limitation: "输出预算不足以容纳搜索结果片段元数据；请提高工具输出预算。")
    }

    private func searchURL(host: String, path: String, query: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw WebReadFailure.invalidURL }
        return url
    }

    private func cancel(_ call: ActiveCall, explicitlyStopped: Bool = true) {
        if explicitlyStopped { call.explicitlyStopped = true }
        guard !call.cancelled else { return }
        call.cancelled = true
        call.deadlineTask?.cancel()
        call.deadlineTask = nil
        transport.cancel(callID: call.operationID)
        renderer.cancel(callID: call.operationID)
        Task { await permits.cancel(id: call.operationID) }
    }

    private func removeSavedDocument(for call: ActiveCall) {
        guard let documentID = call.savedDocumentID else { return }
        documentStore.remove(id: documentID, scope: call.scope)
        call.savedDocumentID = nil
    }

    private func isActive(_ call: ActiveCall) -> Bool {
        activeCalls[call.operationID] === call && !call.cancelled && !cancelledBatches.contains(call.batchID)
    }

    private func canContinueFormatting(_ call: ActiveCall) -> Bool {
        if isActive(call) { return true }
        return call.timedOut
            && call.preservePartialAfterTimeout
            && !call.explicitlyStopped
            && !call.resourceLimited
            && !Task.isCancelled
            && !cancelledBatches.contains(call.batchID)
            && activeCalls[call.operationID] === call
    }

    private func canEmitTimedOutPartial(_ call: ActiveCall) -> Bool {
        call.timedOut
            && call.preservePartialAfterTimeout
            && !call.explicitlyStopped
            && !call.resourceLimited
            && !Task.isCancelled
            && !cancelledBatches.contains(call.batchID)
            && activeCalls[call.operationID] === call
    }

    var activeCallCount: Int { activeCalls.count }

    private func recordDiagnostic(_ call: ActiveCall, status: WebSearchStatus) {
        recentDiagnostics.append(WebSearchDiagnostic(
            sessionID: call.scope.sessionID,
            userRequestID: call.scope.userRequestID,
            batchID: call.batchID,
            callID: call.callID,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(call.startedAt) * 1_000)),
            networkAttempts: call.networkAttempts,
            redirects: call.redirects,
            responseBytes: call.responseBytes,
            fallbackUsed: call.fallbackUsed,
            status: status
        ))
        if recentDiagnostics.count > configuration.maximumDiagnostics {
            recentDiagnostics.removeFirst(recentDiagnostics.count - configuration.maximumDiagnostics)
        }
        logger.info("[Search] call=\(call.callID.prefix(24)) status=\(status.rawValue) attempts=\(call.networkAttempts) redirects=\(call.redirects) bytes=\(call.responseBytes) fallback=\(call.fallbackUsed) durationMs=\(Int(Date().timeIntervalSince(call.startedAt) * 1_000))")
    }

    private func failureLimitation(_ error: Error) -> String {
        switch error as? WebReadFailure {
        case .invalidURL: "搜索网址无效。"
        case .deadlineExceeded: "网页搜索达到统一截止时间。"
        case .responseTooLarge: "DuckDuckGo 响应超过下载上限。"
        case .restricted: "DuckDuckGo 重定向要求不允许的身份验证或非 HTTP(S) 地址。"
        case .cancelled: "网页搜索已取消。"
        case .resourceLimit: "匿名搜索资源或渲染器达到上限。"
        case .transport(let note): "匿名 HTTP 传输失败：\(note)"
        case .invalidScope: "搜索范围无效。"
        case .notFound: "保存的搜索结果不存在。"
        case nil: "网页搜索读取失败。"
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let failure = error as? WebReadFailure, case .cancelled = failure { return true }
        return false
    }

    private static func payload(
        archive: WebSearchArchive,
        results: [WebSearchEntry],
        documentID: String?,
        continuation: WebSearchContinuation?
    ) -> WebSearchResult {
        WebSearchResult(
            query: archive.query,
            engine: archive.engine,
            status: archive.status,
            retrievedAt: archive.retrievedAt,
            results: results,
            limitations: archive.limitations,
            documentID: documentID,
            continuation: continuation,
            nextPageURL: archive.nextPageURL,
            nextPageMethod: archive.nextPageMethod,
            nextPageStart: archive.nextPageStart,
            nextPageParameters: archive.nextPageParameters,
            coverage: archive.coverage
        )
    }

    nonisolated static func immediateOutcome(query: String, status: WebSearchStatus, limitation: String) -> WebSearchOutcome {
        let boundedQuery = String(String.UnicodeScalarView(query.unicodeScalars.prefix(256)))
        let boundedLimitation = query.unicodeScalars.count > 256
            ? limitation + " 原关键词超过回显上限，已省略其余内容。"
            : limitation
        let result = WebSearchResult(
            query: boundedQuery,
            engine: "duckduckgo_lite",
            status: status,
            retrievedAt: nil,
            results: [],
            limitations: [boundedLimitation],
            documentID: nil,
            continuation: nil,
            nextPageURL: nil,
            nextPageMethod: nil,
            nextPageStart: nil,
            nextPageParameters: nil,
            coverage: "没有完成当前 DuckDuckGo 结果页读取。"
        )
        return WebSearchOutcome(
            json: encode(result) ?? "{\"query\":\"\",\"engine\":\"duckduckgo_lite\",\"status\":\"failed\",\"results\":[],\"limitations\":[\"结果编码失败\"],\"coverage\":\"读取未完成\"}",
            isError: status == .failed || status == .verificationRequired,
            status: status,
            documentID: nil
        )
    }

    nonisolated static func addingInputTruncationLimitation(to outcome: WebSearchOutcome, query: String) -> WebSearchOutcome {
        guard let data = outcome.json.data(using: .utf8),
              let original = try? JSONDecoder().decode(WebSearchResult.self, from: data) else {
            return immediateOutcome(query: query, status: .partial, limitation: "搜索关键词参数在传输中被截断；结果可能不完整。")
        }
        let updated = WebSearchResult(
            query: original.query,
            engine: original.engine,
            status: original.status == .results ? .partial : original.status,
            retrievedAt: original.retrievedAt,
            results: original.results,
            limitations: Self.unique(original.limitations + ["搜索参数在传输中被截断并经过自动修复；请核对实际关键词与结果。"]),
            documentID: original.documentID,
            continuation: original.continuation,
            nextPageURL: original.nextPageURL,
            nextPageMethod: original.nextPageMethod,
            nextPageStart: original.nextPageStart,
            nextPageParameters: original.nextPageParameters,
            coverage: original.coverage
        )
        return WebSearchOutcome(json: encode(updated) ?? outcome.json, isError: outcome.isError, status: updated.status, documentID: outcome.documentID)
    }

    private nonisolated static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func encodeOffMain<T: Encodable & Sendable>(_ value: T) async -> String? {
        await Task.detached(priority: .utility) {
            encode(value)
        }.value
    }

    private nonisolated static func decodeArchive(_ content: String) async -> WebSearchArchive? {
        await Task.detached(priority: .utility) {
            try? JSONDecoder().decode(WebSearchArchive.self, from: Data(content.utf8))
        }.value
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private nonisolated static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static let searchUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let inputTruncationLimitation = "搜索关键词参数在传输中被截断并经过自动修复；请核对实际关键词与结果。"
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
