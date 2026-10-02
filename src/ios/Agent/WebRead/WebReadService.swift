import Foundation

@MainActor
final class WebReadService {
    static let shared = WebReadService(
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
        var timedOut = false
        var resourceLimited = false
        var extractionTask: Task<WebReadExtraction, Error>?
        var deadlineTask: Task<Void, Never>?
        var networkAttempts = 0
        var redirects = 0
        var responseBytes = 0
        var extractedScalars = 0
        var rendererUsed = false
        var savedDocumentID: String?
        var httpDurationMilliseconds = 0
        var extractionDurationMilliseconds = 0
        var renderDurationMilliseconds = 0

        init(operationID: String, callID: String, batchID: String, scope: WebReadScope, deadline: Date) {
            self.operationID = operationID
            self.callID = callID
            self.batchID = batchID
            self.scope = scope
            self.deadline = deadline
        }
    }

    private struct ReadSource {
        let response: WebReadFetchedResponse
        let extraction: WebReadExtraction
    }

    struct MemoryPressureReport: Sendable {
        let cancelledCalls: Int
        let removedDocuments: Int
        let releasedBytes: Int
    }

    struct Diagnostic: Sendable {
        let sessionID: String
        let userRequestID: String
        let identityRevision: String
        let batchID: String
        let callID: String
        let durationMilliseconds: Int
        let httpDurationMilliseconds: Int
        let extractionDurationMilliseconds: Int
        let renderDurationMilliseconds: Int
        let networkAttempts: Int
        let redirects: Int
        let responseBytes: Int
        let extractedScalars: Int
        let rendererUsed: Bool
        let status: WebReadStatus
    }

    private static var activeDownloadCount = 0
    private let transport: WebReadTransport
    private let renderer: WebReadRendering
    private let documentStore: WebReadDocumentStore
    let configuration: WebReadConfiguration
    private var activeCalls: [String: ActiveCall] = [:]
    private var cancelledBatches: Set<String> = []
    private var batchSessions: [String: String] = [:]
    private var batchScopes: [String: Set<WebReadScope>] = [:]
    private var memoryLimitedBatches: Set<String> = []
    private(set) var recentDiagnostics: [Diagnostic] = []
    private let logger = AppLogger(category: "WebRead")
    private let maximumActiveCalls = 8
    private let maximumDiagnosticRecords = 128

    init(
        transport: WebReadTransport,
        renderer: WebReadRendering,
        documentStore: WebReadDocumentStore,
        configuration: WebReadConfiguration = .conservative
    ) {
        self.transport = transport
        self.renderer = renderer
        self.documentStore = documentStore
        self.configuration = configuration
    }

    func beginBatch(id: String, sessionID: String, scope: WebReadScope? = nil) {
        guard !id.isEmpty else { return }
        batchSessions[id] = sessionID
        if let scope { batchScopes[id, default: []].insert(scope) }
    }

    func finishBatch(id: String) {
        cancelledBatches.remove(id)
        batchSessions.removeValue(forKey: id)
        batchScopes.removeValue(forKey: id)
        memoryLimitedBatches.remove(id)
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
        for call in activeCalls.values where call.batchID == id {
            cancel(call)
        }
    }

    func cancelSession(_ sessionID: String) {
        let batches = Set(batchSessions.compactMap { $0.value == sessionID ? $0.key : nil })
        for batchID in batches {
            cancelBatch(batchID)
        }
        for call in activeCalls.values where call.scope.sessionID == sessionID {
            cancel(call)
        }
        for batchID in batchSessions.compactMap({ $0.value == sessionID ? $0.key : nil }) {
            finishBatch(id: batchID)
        }
        documentStore.removeAll(sessionID: sessionID)
    }

    func handleMemoryWarning() -> MemoryPressureReport {
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
        return MemoryPressureReport(
            cancelledCalls: calls.count,
            removedDocuments: documents,
            releasedBytes: bytes
        )
    }

    func endRequest(scope: WebReadScope) {
        let batches = batchScopes.compactMap { batchID, scopes in
            scopes.contains(scope) ? batchID : nil
        }
        for batchID in batches { cancelBatch(batchID) }
        for call in activeCalls.values where call.scope == scope {
            cancel(call)
        }
        documentStore.removeAll(scope: scope)
    }

    func read(
        request: WebReadRequest,
        scope: WebReadScope,
        callID: String,
        batchID: String,
        deadline suppliedDeadline: Date? = nil
    ) async -> WebReadOutcome {
        let deadline = suppliedDeadline ?? Date().addingTimeInterval(configuration.totalTimeout)
        guard !callID.isEmpty, !batchID.isEmpty, !scope.sessionID.isEmpty, !scope.userRequestID.isEmpty else {
            return Self.immediateOutcome(request: request, status: .failed, limitation: "读取范围或调用标识无效。")
        }
        let ownsBatchLifecycle = batchSessions[batchID] == nil
        if ownsBatchLifecycle { batchSessions[batchID] = scope.sessionID }
        defer {
            if ownsBatchLifecycle { finishBatch(id: batchID) }
        }
        batchScopes[batchID, default: []].insert(scope)
        if memoryLimitedBatches.contains(batchID) {
            return Self.immediateOutcome(request: request, status: .failed, limitation: "系统内存压力已停止本批次匿名读取。")
        }
        guard !cancelledBatches.contains(batchID) else {
            return Self.immediateOutcome(request: request, status: .cancelled, limitation: "读取在开始前已停止。")
        }
        guard deadline > Date() else {
            return Self.immediateOutcome(request: request, status: .failed, limitation: "读取超过统一截止时间，未取得正文。")
        }
        guard activeCalls.count < maximumActiveCalls else {
            return Self.immediateOutcome(request: request, status: .failed, limitation: "匿名读取活动调用已达到资源上限。")
        }

        let operationID = "webread_" + UUID().uuidString.lowercased()
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
            self.cancel(call)
        }

        var outcome = await withTaskCancellationHandler {
            await self.performRead(request: request, scope: scope, call: call, deadline: deadline)
        } onCancel: {
            Task { @MainActor [weak self, weak call] in
                guard let self, let call else { return }
                self.cancel(call)
            }
        }
        if call.resourceLimited {
            removeSavedDocument(for: call)
            outcome = Self.immediateOutcome(
                request: request, status: .failed, limitation: "系统内存压力已停止匿名读取。"
            )
        } else if call.timedOut || Date() >= deadline {
            call.timedOut = true
            cancel(call)
            removeSavedDocument(for: call)
            outcome = timeoutOutcome(request: request, previous: outcome)
        } else if Task.isCancelled || call.cancelled || cancelledBatches.contains(batchID) {
            cancel(call)
            removeSavedDocument(for: call)
            outcome = Self.immediateOutcome(
                request: request, status: .cancelled, limitation: "读取已取消。"
            )
        }
        call.deadlineTask?.cancel()
        call.deadlineTask = nil
        activeCalls.removeValue(forKey: operationID)
        recordDiagnostic(call, status: outcome.status)
        return outcome
    }

    private func performRead(
        request: WebReadRequest,
        scope: WebReadScope,
        call: ActiveCall,
        deadline: Date
    ) async -> WebReadOutcome {
        if let rawTarget = request.queryTarget,
           !rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           normalizedTarget(rawTarget) == nil {
            return Self.immediateOutcome(request: request, status: .failed, limitation: "定位目标超过工具允许的长度。")
        }
        if let documentID = request.documentID {
            guard isActive(call), Date() < deadline else {
                return cancellationOutcome(request: request, url: nil, call: call)
            }
            guard let slice = documentStore.read(
                id: documentID,
                scope: scope,
                offset: request.offset,
                limit: request.limit,
                queryTarget: request.queryTarget
            ) else {
                return Self.immediateOutcome(
                    request: request, status: .failed,
                    limitation: "正文编号不存在、已过期或不属于当前聊天、请求及匿名身份。"
                )
            }
            guard isActive(call), Date() < deadline else {
                return cancellationOutcome(request: request, url: slice.document.url, call: call)
            }
            return makeSliceOutcome(slice, queryTarget: request.queryTarget)
        }

        guard let rawURL = request.url, let url = Self.allowedURL(rawURL) else {
            return Self.immediateOutcome(request: request, status: .failed, limitation: "请提供有效的匿名 HTTP 或 HTTPS 网址。")
        }

        var primary: ReadSource?
        do {
            guard isActive(call), Date() < deadline else { throw WebReadFailure.cancelled }
            let response = try await fetch(url, call: call, deadline: deadline)
            guard isActive(call) else { throw WebReadFailure.cancelled }

            if response.statusCode == 401 || response.statusCode == 403 {
                return Self.immediateOutcome(
                    request: request, url: response.finalURL.absoluteString,
                    retrievedAt: response.retrievedAt, status: .restricted,
                    limitation: response.statusCode == 401 ? "匿名访问要求认证。" : "服务器拒绝了匿名访问。"
                )
            }
            guard (200..<300).contains(response.statusCode) else {
                return Self.immediateOutcome(
                    request: request, url: response.finalURL.absoluteString,
                    retrievedAt: response.retrievedAt, status: .failed,
                    limitation: "服务器未能提供可读取的页面（HTTP \(response.statusCode)）。"
                )
            }
            if Self.looksLikeLoginURL(response.finalURL) {
                return Self.immediateOutcome(
                    request: request, url: response.finalURL.absoluteString,
                    retrievedAt: response.retrievedAt, status: .restricted,
                    limitation: "匿名请求被重定向到登录或认证页面。"
                )
            }
            if response.stoppedForUnsupportedContent || Self.isResourceMime(response.mimeType) {
                return resourceOutcome(response, requestedURL: url.absoluteString)
            }

            let extracted = try await extract(response, call: call)
            guard isActive(call) else { throw WebReadFailure.cancelled }
            if Self.looksLikeLoginForm(response.bytes) {
                return Self.immediateOutcome(
                    request: request, url: response.finalURL.absoluteString,
                    retrievedAt: response.retrievedAt, status: .restricted,
                    limitation: "页面要求登录或交互；匿名工具没有取得受限正文。"
                )
            }
            primary = ReadSource(response: response, extraction: extracted)
        } catch {
            if call.resourceLimited {
                return cancellationOutcome(request: request, url: url.absoluteString, call: call)
            }
            if call.timedOut {
                return Self.immediateOutcome(request: request, url: url.absoluteString, status: .failed, limitation: "读取超过统一截止时间，未取得完整正文。")
            }
            if !isActive(call) || isCancellation(error) {
                return Self.immediateOutcome(request: request, url: url.absoluteString, status: .cancelled, limitation: "读取已取消。")
            }
            if let partial = primary, !partial.extraction.markdown.isEmpty {
                return saveSource(
                    partial, request: request, scope: scope, call: call, requestedURL: url.absoluteString,
                    sourceNote: nil, additionalLimitations: ["读取在完成前发生错误；仅返回已取得正文。"],
                    statusOverride: .partial
                )
            }
            return failureOutcome(request: request, url: url.absoluteString, error: error)
        }

        guard var selected = primary else {
            return Self.immediateOutcome(request: request, url: url.absoluteString, status: .failed, limitation: "页面正文无法解析。")
        }
        let primaryPageURL = selected.response.finalURL
        var selectedURL = selected.response.finalURL
        var requestedURL: String? = selectedURL.absoluteString == url.absoluteString ? nil : url.absoluteString
        var sourceNote: String?
        var limitations = sourceLimitations(selected)
        let target = normalizedTarget(request.queryTarget)
        var adequate = isAdequate(selected.extraction, queryTarget: target)
        var rendererReportedLoadingIndicator = false

        if !adequate, call.networkAttempts < configuration.maximumNetworkRequests, Date() < deadline {
            let candidates = Self.linkAlternates(selected.response.headers["link"], baseURL: selected.response.finalURL)
                + selected.extraction.alternateSources
            for alternate in uniqueURLs(candidates).prefix(3) {
                guard call.networkAttempts < configuration.maximumNetworkRequests, Date() < deadline, isActive(call) else { break }
                do {
                    let response = try await fetch(alternate, call: call, deadline: deadline)
                    guard isActive(call) else { throw WebReadFailure.cancelled }
                    guard (200..<300).contains(response.statusCode),
                          !Self.isResourceMime(response.mimeType),
                          !response.stoppedForUnsupportedContent,
                          !Self.looksLikeLoginURL(response.finalURL),
                          !Self.looksLikeLoginForm(response.bytes) else { continue }
                    let extraction = try await extract(response, call: call)
                    guard isActive(call) else { throw WebReadFailure.cancelled }
                    guard !extraction.markdown.isEmpty else { continue }
                    selected = ReadSource(response: response, extraction: extraction)
                    selectedURL = response.finalURL
                    requestedURL = url.absoluteString
                    adequate = isAdequate(extraction, queryTarget: target)
                    sourceNote = "使用页面明确声明的公开备用正文；内容范围以该备用来源为准。"
                    limitations = sourceLimitations(selected)
                    if !adequate {
                        limitations.append("备用正文仍未确认包含指定目标或完整页面内容。")
                    }
                    break
                } catch {
                    if call.resourceLimited {
                        return cancellationOutcome(request: request, url: url.absoluteString, call: call)
                    }
                    if call.timedOut { break }
                    if !isActive(call) || isCancellation(error) {
                        return Self.immediateOutcome(request: request, url: url.absoluteString, status: .cancelled, limitation: "读取已取消。")
                    }
                    continue
                }
            }
        }

        let shouldRender = request.renderRequested || !adequate
        if shouldRender, Date() < deadline, isActive(call), call.networkAttempts < configuration.maximumNetworkRequests {
            let registryID = call.operationID
            let acquired = BrowserTabPoolRegistry.shared.acquireAnonymousWebReadRenderer(callID: registryID)
            if acquired {
                defer { BrowserTabPoolRegistry.shared.releaseAnonymousWebReadRenderer(callID: registryID) }
                call.networkAttempts += 1
                call.rendererUsed = true
                do {
                    let renderDeadline = min(deadline, Date().addingTimeInterval(configuration.renderTargetWaitTimeout + 1))
                    let rendered = try await renderPage(
                        url: primaryPageURL,
                        callID: registryID,
                        deadline: renderDeadline,
                        queryTarget: target,
                        waitForTarget: !adequate || request.renderRequested,
                        call: call
                    )
                    guard isActive(call) else { throw WebReadFailure.cancelled }
                    rendererReportedLoadingIndicator = rendered.hasLoadingIndicator
                    if Self.looksLikeLoginURL(rendered.finalURL)
                        || Self.looksLikeLoginForm(Data(rendered.html.utf8)) {
                        return Self.immediateOutcome(
                            request: request, url: rendered.finalURL.absoluteString,
                            retrievedAt: rendered.retrievedAt, status: .restricted,
                            limitation: "渲染页面要求登录或交互；匿名工具没有取得受限正文。"
                        )
                    }
                    let renderedResponse = WebReadFetchedResponse(
                        requestedURL: url, finalURL: rendered.finalURL, statusCode: 200,
                        mimeType: "text/html", suggestedFilename: nil, headers: [:], bytes: Data(),
                        retrievedAt: rendered.retrievedAt, redirectCount: 0,
                        bodyWasTruncated: rendered.htmlWasTruncated, stoppedForUnsupportedContent: false
                    )
                    let renderedExtraction = try await extractHTML(
                        rendered.html, baseURL: rendered.finalURL, call: call
                    )
                    guard isActive(call) else { throw WebReadFailure.cancelled }
                    let renderedSource = ReadSource(response: renderedResponse, extraction: renderedExtraction)
                    let renderAdequate = isAdequate(renderedExtraction, queryTarget: target)
                    if renderAdequate || renderedExtraction.markdown.unicodeScalars.count > selected.extraction.markdown.unicodeScalars.count {
                        selected = renderedSource
                        selectedURL = rendered.finalURL
                        sourceNote = "正文由独立匿名 WebKit 渲染取得。"
                        requestedURL = selectedURL.absoluteString == url.absoluteString ? nil : url.absoluteString
                        limitations = sourceLimitations(selected)
                    }
                    adequate = isAdequate(selected.extraction, queryTarget: target)
                    if target != nil, rendered.targetWaitExpired && rendered.targetFound != true {
                        limitations.append("匿名渲染等待后仍未发现指定目标。")
                    }
                    if rendered.hasLoadingIndicator {
                        limitations.append("匿名渲染等待结束时页面仍显示加载状态；本次正文可能不完整。")
                    }
                    if request.renderRequested && renderedExtraction.markdown.isEmpty {
                        limitations.append("已执行显式动态渲染，但没有提取到可读正文。")
                    }
                    if !adequate {
                        limitations.append("页面仍有未确认内容；本次结果只包含已取得的正文。")
                    }
                } catch {
                    if call.resourceLimited {
                        return cancellationOutcome(request: request, url: url.absoluteString, call: call)
                    }
                    if call.timedOut {
                        limitations.append("读取达到统一截止时间；已返回此前取得的正文。")
                    } else if !isActive(call) || isCancellation(error) {
                        return Self.immediateOutcome(request: request, url: url.absoluteString, status: .cancelled, limitation: "读取已取消。")
                    }
                    let note = renderFailureLimitation(error)
                    limitations.append(note)
                    if selected.extraction.markdown.isEmpty {
                        return Self.immediateOutcome(
                            request: request, url: selectedURL.absoluteString,
                            retrievedAt: selected.response.retrievedAt,
                            status: isRestricted(error) ? .restricted : .failed,
                            limitation: note
                        )
                    }
                }
            } else {
                limitations.append("匿名渲染资源槽位已满；保留当前静态读取结果。")
                if selected.extraction.markdown.isEmpty {
                    return Self.immediateOutcome(
                        request: request, url: selectedURL.absoluteString,
                        retrievedAt: selected.response.retrievedAt, status: .failed,
                        limitation: "匿名渲染资源槽位已满，无法取得正文。"
                    )
                }
            }
        } else if shouldRender {
            limitations.append(call.networkAttempts >= configuration.maximumNetworkRequests
                ? "匿名读取尝试次数已达上限，未启动渲染。"
                : "统一截止时间已到，未启动匿名渲染。")
        }

        if selected.extraction.markdown.isEmpty {
            if !selected.extraction.resources.isEmpty {
                return resourceOutcome(selected.response, requestedURL: url.absoluteString, resources: selected.extraction.resources)
            }
            if rendererReportedLoadingIndicator {
                return Self.immediateOutcome(
                    request: request, url: selectedURL.absoluteString,
                    retrievedAt: selected.response.retrievedAt, status: .partial,
                    limitation: "匿名渲染等待结束时页面仍显示加载状态，且没有取得可读正文。"
                )
            }
            return Self.immediateOutcome(
                request: request, url: selectedURL.absoluteString,
                retrievedAt: selected.response.retrievedAt, status: .failed,
                limitation: "页面没有可读取的正文。"
            )
        }

        let incomplete = selected.response.bodyWasTruncated
            || selected.extraction.wasTruncated
            || selected.extraction.hasLoadingMarker
            || selected.extraction.usedStructuredArticleBody
            || rendererReportedLoadingIndicator
            || !adequate
        if selected.response.bodyWasTruncated {
            limitations.append("响应超过单次下载上限；只保留已取得的正文前缀。")
        }
        if selected.extraction.wasTruncated {
            limitations.append("正文超过保存上限；后续未取得范围不可续读。")
        }
        if selected.extraction.hasLoadingMarker {
            limitations.append("页面仍显示内容加载提示，正文可能尚未完整。")
        }
        if selected.extraction.usedStructuredArticleBody {
            limitations.append("正文来自页面声明的结构化 articleBody，可能不包含页面全部结构。")
        }
        if let target, !selected.extraction.markdown.localizedCaseInsensitiveContains(target) {
            limitations.append("指定目标不在当前已取得正文中。")
        }
        if Date() >= deadline || call.timedOut {
            limitations.append("读取达到统一截止时间；仅返回截止前取得的正文。")
            call.timedOut = true
            cancel(call)
            return uncachedPartialOutcome(
                selected, request: request, requestedURL: requestedURL,
                sourceNote: sourceNote, limitations: uniqueStrings(limitations)
            )
        }
        guard isActive(call) else {
            return cancellationOutcome(request: request, url: selectedURL.absoluteString, call: call)
        }
        return saveSource(
            selected, request: request, scope: scope, call: call,
            requestedURL: requestedURL,
            sourceNote: sourceNote,
            additionalLimitations: uniqueStrings(limitations),
            statusOverride: incomplete || call.timedOut ? .partial : .textReady
        )
    }

    func addingInputTruncationLimitation(
        to outcome: WebReadOutcome,
        queryTarget: String?
    ) -> WebReadOutcome {
        guard let data = outcome.json.data(using: .utf8),
              var result = try? JSONDecoder().decode(WebReadResult.self, from: data) else {
            let status: WebReadStatus = outcome.isError ? .failed : .partial
            return Self.immediateOutcome(
                request: WebReadRequest(queryTarget: queryTarget), status: status,
                limitation: "读取参数曾被截断并修复；原始请求可能不完整。"
            )
        }
        var limitations = result.limitations
        let warning = "读取参数曾被截断并自动修复；本次请求可能不完整。"
        if !limitations.contains(warning) { limitations.append(warning) }
        let status: WebReadStatus = result.readStatus == .textReady || result.readStatus == .resourceOnly
            ? .partial : result.readStatus
        result = WebReadResult(
            url: result.url, title: result.title, retrievedAt: result.retrievedAt,
            readStatus: status, content: result.content, limitations: limitations,
            requestedURL: result.requestedURL, sourceNote: result.sourceNote,
            documentID: result.documentID, continuation: result.continuation,
            locateStatus: result.locateStatus, resources: result.resources
        )
        return Self.encodeOutcome(
            result, queryTarget: queryTarget, isError: outcome.isError,
            maximumBytes: configuration.maximumResultBytes
        )
    }

    static func immediateOutcome(
        request: WebReadRequest,
        url: String? = nil,
        retrievedAt: Date? = nil,
        status: WebReadStatus,
        limitation: String
    ) -> WebReadOutcome {
        let result = WebReadResult(
            url: url ?? request.url ?? "",
            title: nil,
            retrievedAt: retrievedAt.map(iso8601),
            readStatus: status,
            content: "",
            limitations: [limitation],
            requestedURL: nil,
            sourceNote: nil,
            documentID: nil,
            continuation: nil,
            locateStatus: nil,
            resources: nil
        )
        return encodeOutcome(result, queryTarget: request.queryTarget, isError: status.rawValue == "failed" || status.rawValue == "restricted")
    }

    private func fetch(
        _ url: URL, call: ActiveCall, deadline: Date
    ) async throws -> WebReadFetchedResponse {
        guard isActive(call) else { throw WebReadFailure.cancelled }
        guard deadline > Date() else { throw WebReadFailure.deadlineExceeded }
        guard Self.allowedURL(url.absoluteString) != nil else { throw WebReadFailure.restricted }
        guard Self.activeDownloadCount < configuration.maximumConcurrentDownloads else {
            throw WebReadFailure.resourceLimit
        }
        guard call.networkAttempts < configuration.maximumNetworkRequests else {
            throw WebReadFailure.resourceLimit
        }
        call.networkAttempts += 1
        Self.activeDownloadCount += 1
        let startedAt = Date()
        defer {
            call.httpDurationMilliseconds += max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            Self.activeDownloadCount = max(0, Self.activeDownloadCount - 1)
        }
        let response = try await transport.fetch(WebReadFetchRequest(
            url: url,
            callID: call.operationID,
            deadline: deadline,
            maximumBytes: configuration.maximumResponseBytes,
            maximumRedirects: configuration.maximumRedirects
        ))
        call.redirects += response.redirectCount
        call.responseBytes += response.bytes.count
        return response
    }

    private func extract(_ response: WebReadFetchedResponse, call: ActiveCall) async throws -> WebReadExtraction {
        try await extractBytes(
            response.bytes, mimeType: response.mimeType, baseURL: response.finalURL, call: call
        )
    }

    private func extractHTML(_ html: String, baseURL: URL, call: ActiveCall) async throws -> WebReadExtraction {
        let maximumScalars = configuration.maximumDocumentScalars
        return try await runExtraction(call) {
            try WebReadHTMLExtractor.extract(
                html: html, baseURL: baseURL, maximumScalars: maximumScalars
            )
        }
    }

    private func extractBytes(
        _ bytes: Data, mimeType: String?, baseURL: URL, call: ActiveCall
    ) async throws -> WebReadExtraction {
        let maximumScalars = configuration.maximumDocumentScalars
        return try await runExtraction(call) {
            try WebReadHTMLExtractor.text(
                bytes: bytes, mimeType: mimeType, baseURL: baseURL,
                maximumScalars: maximumScalars
            )
        }
    }

    private func runExtraction(
        _ call: ActiveCall,
        work: @escaping @Sendable () throws -> WebReadExtraction
    ) async throws -> WebReadExtraction {
        guard isActive(call) else { throw WebReadFailure.cancelled }
        let startedAt = Date()
        let task = Task.detached(priority: .utility) {
            try work()
        }
        call.extractionTask = task
        defer {
            call.extractionDurationMilliseconds += max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            call.extractionTask = nil
        }
        let result = try await task.value
        guard isActive(call) else { throw WebReadFailure.cancelled }
        call.extractedScalars += result.markdown.unicodeScalars.count
        return result
    }

    private func renderPage(
        url: URL,
        callID: String,
        deadline: Date,
        queryTarget: String?,
        waitForTarget: Bool,
        call: ActiveCall
    ) async throws -> WebReadRenderedPage {
        let startedAt = Date()
        defer {
            call.renderDurationMilliseconds += max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        }
        return try await renderer.render(
            url: url, callID: callID, deadline: deadline,
            queryTarget: queryTarget, waitForTarget: waitForTarget
        )
    }

    private func saveSource(
        _ source: ReadSource,
        request: WebReadRequest,
        scope: WebReadScope,
        call: ActiveCall,
        requestedURL: String?,
        sourceNote: String?,
        additionalLimitations: [String],
        statusOverride: WebReadStatus
    ) -> WebReadOutcome {
        guard Date() < call.deadline, !Task.isCancelled, !call.cancelled else {
            if Date() >= call.deadline {
                call.timedOut = true
                cancel(call)
            }
            return cancellationOutcome(request: request, url: source.response.finalURL.absoluteString, call: call)
        }
        let extraction = source.extraction
        let document = documentStore.save(
            content: extraction.markdown,
            scope: scope,
            url: source.response.finalURL.absoluteString,
            title: extraction.title,
            retrievedAt: Self.iso8601(source.response.retrievedAt),
            limitations: additionalLimitations,
            requestedURL: requestedURL,
            sourceNote: sourceNote,
            resources: extraction.resources,
            contentIsComplete: statusOverride.rawValue == "text_ready"
        )
        call.savedDocumentID = document.id
        guard isActive(call) else {
            removeSavedDocument(for: call)
            return cancellationOutcome(request: request, url: source.response.finalURL.absoluteString, call: call)
        }
        guard documentStore.contains(id: document.id, scope: scope) else {
            return Self.immediateOutcome(
                request: request, url: source.response.finalURL.absoluteString,
                retrievedAt: source.response.retrievedAt, status: .partial,
                limitation: "正文缓存预算不足，无法安全提供续读编号。"
            )
        }
        let slice = documentStore.read(
            id: document.id, scope: scope, limit: 8_000,
            queryTarget: request.queryTarget
        )
        guard isActive(call) else {
            removeSavedDocument(for: call)
            return cancellationOutcome(request: request, url: source.response.finalURL.absoluteString, call: call)
        }
        guard let slice else {
            return Self.immediateOutcome(request: request, status: .failed, limitation: "正文保存后无法读取。")
        }
        var limitations = additionalLimitations
        if slice.coverageKnownIncomplete && !limitations.contains("正文仅保存了已取得范围，不能续读未保存内容。") {
            limitations.append("正文仅保存了已取得范围，不能续读未保存内容。")
        }
        if slice.locateStatus == .notFoundInSavedContent {
            limitations.append("指定目标在完整已保存正文中未找到。")
        } else if slice.locateStatus == .notCovered {
            limitations.append("在已保存范围内未命中；正文尚未完整取得，未取得部分是否包含目标尚不能判断。")
        }
        let status: WebReadStatus = statusOverride.rawValue == "text_ready" && !slice.coverageKnownIncomplete
            && slice.end == slice.continuation.savedEnd
            ? .textReady : .partial
        let result = WebReadResult(
            url: document.url, title: document.title, retrievedAt: document.retrievedAt,
            readStatus: status, content: slice.content,
            limitations: uniqueStrings(limitations),
            requestedURL: document.requestedURL, sourceNote: document.sourceNote,
            documentID: document.id, continuation: slice.continuation,
            locateStatus: slice.locateStatus, resources: document.resources.isEmpty ? nil : document.resources
        )
        let outcome = Self.encodeOutcome(
            result, queryTarget: request.queryTarget, isError: false,
            maximumBytes: configuration.maximumResultBytes
        )
        guard isActive(call) else {
            removeSavedDocument(for: call)
            return cancellationOutcome(request: request, url: source.response.finalURL.absoluteString, call: call)
        }
        return outcome
    }

    private func removeSavedDocument(for call: ActiveCall) {
        guard let documentID = call.savedDocumentID else { return }
        documentStore.remove(id: documentID, scope: call.scope)
        call.savedDocumentID = nil
    }

    private func uncachedPartialOutcome(
        _ source: ReadSource,
        request: WebReadRequest,
        requestedURL: String?,
        sourceNote: String?,
        limitations: [String]
    ) -> WebReadOutcome {
        let scalars = Array(source.extraction.markdown.unicodeScalars.prefix(8_000))
        let content = String(String.UnicodeScalarView(scalars))
        let target = normalizedTarget(request.queryTarget)
        let locateStatus: WebReadLocateStatus? = {
            guard let target, content.localizedCaseInsensitiveContains(target) else { return nil }
            return .found
        }()
        var finalLimitations = limitations
        finalLimitations.append("正文未能在截止时间前保存为可续读文档；当前片段之外的范围不可续读。")
        let result = WebReadResult(
            url: source.response.finalURL.absoluteString,
            title: source.extraction.title,
            retrievedAt: Self.iso8601(source.response.retrievedAt),
            readStatus: .partial,
            content: content,
            limitations: uniqueStrings(finalLimitations),
            requestedURL: requestedURL,
            sourceNote: sourceNote,
            documentID: nil,
            continuation: nil,
            locateStatus: locateStatus,
            resources: source.extraction.resources.isEmpty ? nil : source.extraction.resources
        )
        return Self.encodeOutcome(
            result, queryTarget: target, isError: false,
            maximumBytes: configuration.maximumResultBytes
        )
    }

    private func makeSliceOutcome(_ slice: WebReadDocumentSlice, queryTarget: String?) -> WebReadOutcome {
        var limitations = slice.document.limitations
        if slice.coverageKnownIncomplete {
            limitations.append("正文仅保存了已取得范围，不能续读未保存内容。")
        }
        if slice.locateStatus == .notFoundInSavedContent {
            limitations.append("指定目标在完整已保存正文中未找到。")
        } else if slice.locateStatus == .notCovered {
            limitations.append("在已保存范围内未命中；正文尚未完整取得，未取得部分是否包含目标尚不能判断。")
        }
        let status: WebReadStatus = slice.coverageKnownIncomplete || slice.end < slice.document.content.unicodeScalars.count
            ? .partial : .textReady
        let result = WebReadResult(
            url: slice.document.url, title: slice.document.title, retrievedAt: slice.document.retrievedAt,
            readStatus: status, content: slice.content, limitations: uniqueStrings(limitations),
            requestedURL: slice.document.requestedURL, sourceNote: slice.document.sourceNote,
            documentID: slice.document.id, continuation: slice.continuation,
            locateStatus: slice.locateStatus,
            resources: slice.document.resources.isEmpty ? nil : slice.document.resources
        )
        return Self.encodeOutcome(
            result, queryTarget: queryTarget, isError: false,
            maximumBytes: configuration.maximumResultBytes
        )
    }

    private func sourceLimitations(_ source: ReadSource) -> [String] {
        var result: [String] = []
        if source.response.bodyWasTruncated { result.append("响应超过单次下载上限；只保留已取得的正文前缀。") }
        if source.extraction.wasTruncated { result.append("正文超过保存上限；后续未取得范围不可续读。") }
        if source.extraction.hasLoadingMarker { result.append("页面仍显示内容加载提示，正文可能尚未完整。") }
        if source.extraction.usedStructuredArticleBody { result.append("正文来自页面声明的结构化 articleBody，可能不包含页面全部结构。") }
        return result
    }

    private func isAdequate(_ extraction: WebReadExtraction, queryTarget: String?) -> Bool {
        guard !extraction.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !extraction.hasLoadingMarker else { return false }
        guard let queryTarget else { return true }
        return extraction.markdown.localizedCaseInsensitiveContains(queryTarget)
    }

    private func resourceOutcome(
        _ response: WebReadFetchedResponse,
        requestedURL: String,
        resources: [WebReadResource]? = nil
    ) -> WebReadOutcome {
        let detectedMime = Self.resourceSignature(response.bytes)
        let mime = detectedMime ?? response.mimeType ?? Self.resourceType(response.suggestedFilename)
        let resource = WebReadResource(
            url: response.finalURL.absoluteString, type: mime,
            readStatus: "not_read", context: "资源已定位，但本工具未读取其内部内容。"
        )
        let result = WebReadResult(
            url: response.finalURL.absoluteString, title: nil,
            retrievedAt: Self.iso8601(response.retrievedAt),
            readStatus: .resourceOnly, content: "",
            limitations: ["PDF、图片或其他非文本资源的内部内容未读取。"],
            requestedURL: response.finalURL.absoluteString == requestedURL ? nil : requestedURL,
            sourceNote: nil, documentID: nil, continuation: nil, locateStatus: nil,
            resources: resources ?? [resource]
        )
        return Self.encodeOutcome(
            result, queryTarget: nil, isError: false,
            maximumBytes: configuration.maximumResultBytes
        )
    }

    private func failureOutcome(request: WebReadRequest, url: String, error: Error) -> WebReadOutcome {
        if let failure = error as? WebReadFailure {
            switch failure {
            case .cancelled:
                return Self.immediateOutcome(request: request, url: url, status: .cancelled, limitation: "读取已取消。")
            case .deadlineExceeded:
                return Self.immediateOutcome(request: request, url: url, status: .failed, limitation: "读取超过统一截止时间，未取得正文。")
            case .restricted:
                return Self.immediateOutcome(request: request, url: url, status: .restricted, limitation: "匿名读取遇到认证或访问限制。")
            case .resourceLimit:
                return Self.immediateOutcome(request: request, url: url, status: .failed, limitation: "匿名读取达到并发资源上限。")
            case .invalidURL, .invalidScope, .notFound, .responseTooLarge:
                return Self.immediateOutcome(request: request, url: url, status: .failed, limitation: "匿名读取未能完成。")
            case .transport:
                return Self.immediateOutcome(request: request, url: url, status: .failed, limitation: "网络请求未能完成。")
            }
        }
        return Self.immediateOutcome(request: request, url: url, status: .failed, limitation: "页面读取或解析未能完成。")
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let failure = error as? WebReadFailure else { return false }
        if case .cancelled = failure { return true }
        return false
    }

    private func isRestricted(_ error: Error) -> Bool {
        guard let failure = error as? WebReadFailure else { return false }
        if case .restricted = failure { return true }
        return false
    }

    private func renderFailureLimitation(_ error: Error) -> String {
        guard let failure = error as? WebReadFailure else { return "匿名渲染未能完成。" }
        switch failure {
        case .restricted:
            return "匿名渲染遇到访问或交互限制。"
        case .deadlineExceeded:
            return "匿名渲染超过统一截止时间。"
        case .responseTooLarge:
            return "匿名渲染主文档超过单次大小上限。"
        case .resourceLimit:
            return "匿名渲染资源达到并发或尝试上限。"
        case .cancelled:
            return "匿名渲染已取消。"
        case .invalidURL, .invalidScope, .notFound, .transport:
            return "匿名渲染未能完成。"
        }
    }

    private func cancel(_ call: ActiveCall) {
        guard !call.cancelled else { return }
        call.cancelled = true
        call.extractionTask?.cancel()
        transport.cancel(callID: call.operationID)
        renderer.cancel(callID: call.operationID)
    }

    private func isActive(_ call: ActiveCall) -> Bool {
        guard !Task.isCancelled, !call.cancelled, !cancelledBatches.contains(call.batchID),
              activeCalls[call.operationID] === call else { return false }
        guard Date() < call.deadline else {
            call.timedOut = true
            cancel(call)
            return false
        }
        return true
    }

    private func timeoutOutcome(request: WebReadRequest, previous: WebReadOutcome) -> WebReadOutcome {
        guard let data = previous.json.data(using: .utf8),
              let saved = try? JSONDecoder().decode(WebReadResult.self, from: data),
              !saved.content.isEmpty else {
            return Self.immediateOutcome(
                request: request, status: .failed,
                limitation: "读取超过统一截止时间，未取得正文。"
            )
        }
        var limitations = saved.limitations
        limitations.append("读取超过统一截止时间；保留已取得的正文片段，不提供续读编号。")
        let locateStatus: WebReadLocateStatus? = {
            guard saved.locateStatus == .found,
                  let target = normalizedTarget(request.queryTarget),
                  saved.content.localizedCaseInsensitiveContains(target) else {
                return saved.locateStatus == .found ? nil : saved.locateStatus
            }
            return .found
        }()
        let result = WebReadResult(
            url: saved.url, title: saved.title, retrievedAt: saved.retrievedAt,
            readStatus: .partial, content: saved.content,
            limitations: uniqueStrings(limitations),
            requestedURL: saved.requestedURL, sourceNote: saved.sourceNote,
            documentID: nil, continuation: nil,
            locateStatus: locateStatus, resources: saved.resources
        )
        return Self.encodeOutcome(
            result, queryTarget: request.queryTarget, isError: false,
            maximumBytes: configuration.maximumResultBytes
        )
    }

    private func cancellationOutcome(request: WebReadRequest, url: String?, call: ActiveCall) -> WebReadOutcome {
        if call.resourceLimited {
            return Self.immediateOutcome(request: request, url: url, status: .failed, limitation: "系统内存压力已停止匿名读取。")
        }
        if call.timedOut {
            return Self.immediateOutcome(request: request, url: url, status: .failed, limitation: "读取超过统一截止时间。")
        }
        return Self.immediateOutcome(request: request, url: url, status: .cancelled, limitation: "读取已取消。")
    }

    private func recordDiagnostic(_ call: ActiveCall, status: WebReadStatus) {
        let duration = max(0, Int(Date().timeIntervalSince(call.startedAt) * 1_000))
        let record = Diagnostic(
            sessionID: call.scope.sessionID,
            userRequestID: call.scope.userRequestID,
            identityRevision: call.scope.identityRevision,
            batchID: call.batchID,
            callID: call.callID,
            durationMilliseconds: duration,
            httpDurationMilliseconds: call.httpDurationMilliseconds,
            extractionDurationMilliseconds: call.extractionDurationMilliseconds,
            renderDurationMilliseconds: call.renderDurationMilliseconds,
            networkAttempts: call.networkAttempts,
            redirects: call.redirects,
            responseBytes: call.responseBytes,
            extractedScalars: call.extractedScalars,
            rendererUsed: call.rendererUsed,
            status: status
        )
        recentDiagnostics.append(record)
        if recentDiagnostics.count > maximumDiagnosticRecords {
            recentDiagnostics.removeFirst(recentDiagnostics.count - maximumDiagnosticRecords)
        }
        logger.info(
            "read session=\(record.sessionID) request=\(record.userRequestID) identity=\(record.identityRevision) " +
                "batch=\(record.batchID) call=\(record.callID) duration_ms=\(duration) " +
                "http_ms=\(record.httpDurationMilliseconds) extract_ms=\(record.extractionDurationMilliseconds) " +
                "render_ms=\(record.renderDurationMilliseconds) attempts=\(record.networkAttempts) " +
                "redirects=\(record.redirects) bytes=\(record.responseBytes) " +
                "scalars=\(record.extractedScalars) renderer=\(record.rendererUsed) status=\(record.status.rawValue)"
        )
    }

    private static func allowedURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    private static func isResourceMime(_ mime: String?) -> Bool {
        guard let mime = mime?.lowercased() else { return false }
        return mime.contains("pdf") || mime.hasPrefix("image/")
            || mime.hasPrefix("audio/") || mime.hasPrefix("video/")
            || mime.hasPrefix("application/octet-stream")
    }

    private static func resourceSignature(_ data: Data) -> String? {
        let prefix = Array(data.prefix(16))
        if prefix.starts(with: Array("%PDF-".utf8)) { return "application/pdf" }
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if prefix.starts(with: Array("GIF87a".utf8)) || prefix.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if prefix.count >= 12, prefix.starts(with: Array("RIFF".utf8)),
           Array(prefix[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }

    private static func resourceType(_ filename: String?) -> String {
        let ext = URL(fileURLWithPath: filename ?? "").pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    private static func looksLikeLoginURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.split(separator: "/").contains(where: {
            ["login", "signin", "sign-in", "authenticate", "auth"].contains(String($0))
        })
    }

    private static func looksLikeLoginForm(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(512 * 1024), as: UTF8.self).lowercased()
        guard text.contains("type=\"password\"") || text.contains("type='password'") else { return false }
        return text.contains("login") || text.contains("sign in") || text.contains("signin")
            || text.contains("password")
    }

    private static func linkAlternates(_ header: String?, baseURL: URL) -> [URL] {
        guard let header else { return [] }
        let pattern = #"(?i)<([^>]+)>\s*((?:;(?!\s*<)[^,]*)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = header as NSString
        let range = NSRange(location: 0, length: ns.length)
        var result: [URL] = []
        regex.enumerateMatches(in: header, range: range) { match, _, stop in
            guard let match, let urlRange = Range(match.range(at: 1), in: header),
                  let paramsRange = Range(match.range(at: 2), in: header) else { return }
            let params = String(header[paramsRange]).lowercased()
            guard params.contains("rel=\"alternate\"") || params.contains("rel=alternate"),
                  params.contains("text/markdown") || params.contains("text/plain")
                    || String(header[urlRange]).lowercased().hasSuffix(".md")
                    || String(header[urlRange]).lowercased().hasSuffix(".txt"),
                  let url = URL(string: String(header[urlRange]), relativeTo: baseURL)?.absoluteURL,
                  allowedURL(url.absoluteString) != nil else { return }
            if !result.contains(url) { result.append(url) }
            if result.count >= 3 { stop.pointee = true }
        }
        return result
    }

    private func uniqueURLs(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.absoluteString).inserted }
    }

    private func normalizedTarget(_ target: String?) -> String? {
        guard let target else { return nil }
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= 512 else { return nil }
        return value
    }

    private func uniqueStrings(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func encodeOutcome(
        _ original: WebReadResult,
        queryTarget: String?,
        isError: Bool,
        maximumBytes: Int = WebReadConfiguration.conservative.maximumResultBytes
    ) -> WebReadOutcome {
        var result = original
        var data = encode(result)
        while data.count > maximumBytes, !result.content.isEmpty {
            let scalars = Array(result.content.unicodeScalars)
            let targetRange = scalarRange(of: queryTarget, in: result.content)
            let targetLength = targetRange?.count ?? 0
            let reducedCount = max(0, scalars.count - max(1, scalars.count / 8))
            let nextCount = result.locateStatus == .found && targetLength > 0
                ? max(targetLength, reducedCount)
                : reducedCount
            let windowStart: Int
            let canPreserveFoundTarget = result.locateStatus == .found
                && targetRange != nil
                && targetLength <= nextCount
            if canPreserveFoundTarget, let targetRange {
                let context = nextCount - targetRange.count
                windowStart = min(
                    max(0, targetRange.lowerBound - context / 3),
                    max(0, scalars.count - nextCount)
                )
            } else {
                windowStart = 0
            }
            let windowEnd = min(scalars.count, windowStart + nextCount)
            let clipped = String(String.UnicodeScalarView(scalars[windowStart..<windowEnd]))
            // 目标本身已占满可保留窗口但 JSON 仍超限时，交由下方失败回退，避免主线程死循环。
            guard clipped != result.content else { break }
            let continuation: WebReadContinuation?
            if let previous = result.continuation {
                let start = min(previous.savedEnd, previous.start + windowStart)
                let end = min(previous.savedEnd, start + clipped.unicodeScalars.count)
                continuation = WebReadContinuation(
                    start: start, end: end, savedEnd: previous.savedEnd,
                    nextOffset: end < previous.savedEnd ? end : nil
                )
            } else {
                continuation = nil
            }
            var limitations = result.limitations
            if !limitations.contains("结果大小受限；正文片段已缩短，可从返回位置继续读取。") {
                limitations.append("结果大小受限；正文片段已缩短，可从返回位置继续读取。")
            }
            var locateStatus = result.locateStatus
            if locateStatus == .found {
                if !canPreserveFoundTarget {
                    locateStatus = nil
                    limitations.append("输出预算无法保留完整定位目标；定位状态已撤销。")
                }
            }
            result = WebReadResult(
                url: result.url, title: result.title, retrievedAt: result.retrievedAt,
                readStatus: .partial, content: clipped, limitations: uniqueEncodedLimitations(limitations),
                requestedURL: result.requestedURL, sourceNote: result.sourceNote,
                documentID: result.documentID, continuation: continuation,
                locateStatus: locateStatus, resources: result.resources
            )
            data = encode(result)
        }
        if data.count > maximumBytes {
            result = WebReadResult(
                url: String(result.url.prefix(1_024)), title: nil, retrievedAt: result.retrievedAt,
                readStatus: .failed, content: "", limitations: ["结果元数据超过安全大小上限。"],
                requestedURL: nil, sourceNote: nil, documentID: nil, continuation: nil,
                locateStatus: nil, resources: nil
            )
            data = encode(result)
        }
        let json = String(data: data, encoding: .utf8) ?? "{\"url\":\"\",\"title\":null,\"retrieved_at\":null,\"read_status\":\"failed\",\"content\":\"\",\"limitations\":[\"结果编码失败\"]}"
        let adjustedError = isError || result.readStatus.rawValue == "failed" || result.readStatus.rawValue == "restricted"
        return WebReadOutcome(json: json, isError: adjustedError, status: result.readStatus, documentID: result.documentID)
    }


    private static func scalarRange(of target: String?, in content: String) -> Range<Int>? {
        guard let target, !target.isEmpty,
              let range = content.range(of: target, options: [.caseInsensitive]) else { return nil }
        let lower = content[..<range.lowerBound].unicodeScalars.count
        let matched = content[range].unicodeScalars.count
        return lower..<(lower + matched)
    }

    private static func uniqueEncodedLimitations(_ limitations: [String]) -> [String] {
        var seen = Set<String>()
        return limitations.filter { seen.insert($0).inserted }
    }
    private static func encode(_ result: WebReadResult) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(result)) ?? Data()
    }
}
