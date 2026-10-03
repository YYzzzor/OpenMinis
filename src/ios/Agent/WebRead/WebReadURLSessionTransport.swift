import Foundation

private final class WebReadRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumRedirects: Int
    private var redirectCounts: [Int: Int] = [:]
    private var restrictedRequestWasRejected = false

    var rejectedRestrictedRequest: Bool { withLock { restrictedRequestWasRejected } }

    init(maximumRedirects: Int) {
        self.maximumRedirects = max(0, maximumRedirects)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let count = withLock {
            redirectCounts[task.taskIdentifier, default: 0] += 1
            return redirectCounts[task.taskIdentifier, default: 0]
        }
        let allowedURL = Self.isAnonymousHTTPURL(request.url)
        if !allowedURL { withLock { restrictedRequestWasRejected = true } }
        completionHandler(count <= maximumRedirects && allowedURL ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            withLock { restrictedRequestWasRejected = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private static func isAnonymousHTTPURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }

    func redirectCount(for taskIdentifier: Int) -> Int {
        withLock { redirectCounts[taskIdentifier, default: 0] }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class URLSessionWebReadTransport: WebReadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]

    func fetch(_ request: WebReadFetchRequest) async throws -> WebReadFetchedResponse {
        let remaining = request.deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw WebReadFailure.deadlineExceeded }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = max(1, remaining)
        configuration.timeoutIntervalForResource = max(1, remaining)
        configuration.httpAdditionalHeaders = [
            "Accept": "text/html, text/markdown, text/plain, application/json;q=0.9, */*;q=0.1",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache"
        ]

        let redirectDelegate = WebReadRedirectDelegate(maximumRedirects: request.maximumRedirects)
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        withLock { sessions[request.callID] = session }
        defer {
            _ = withLock { sessions.removeValue(forKey: request.callID) }
            session.finishTasksAndInvalidate()
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = max(1, remaining)
        if let userAgent = request.userAgent, !userAgent.isEmpty {
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        do {
            return try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: urlRequest, delegate: redirectDelegate)
                if redirectDelegate.rejectedRestrictedRequest {
                    bytes.task.cancel()
                    throw WebReadFailure.restricted
                }
                guard let http = response as? HTTPURLResponse else {
                    bytes.task.cancel()
                    throw WebReadFailure.transport("The server returned a non-HTTP response.")
                }
                let finalURL = http.url ?? request.url
                let mimeType = http.mimeType?.lowercased()
                let headers = Self.stringHeaders(http)
                let suggestedFilename = http.suggestedFilename
                let retrievedAt = Date()

                if Self.isUnsupportedMime(mimeType)
                    || (!(200..<300).contains(http.statusCode) && !request.allowsNonSuccessBody) {
                    bytes.task.cancel()
                    return WebReadFetchedResponse(
                        requestedURL: request.url, finalURL: finalURL, statusCode: http.statusCode,
                        mimeType: mimeType, suggestedFilename: suggestedFilename, headers: headers,
                        bytes: Data(), retrievedAt: retrievedAt,
                        redirectCount: redirectDelegate.redirectCount(for: bytes.task.taskIdentifier),
                        bodyWasTruncated: false, stoppedForUnsupportedContent: Self.isUnsupportedMime(mimeType)
                    )
                }

                var body = Data()
                body.reserveCapacity(min(request.maximumBytes, 64 * 1024))
                var wasTruncated = false
                var stoppedForUnsupportedContent = false
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if body.count >= request.maximumBytes {
                        wasTruncated = true
                        bytes.task.cancel()
                        break
                    }
                    body.append(byte)
                    if body.count <= 16, Self.hasBinarySignature(body) {
                        stoppedForUnsupportedContent = true
                        bytes.task.cancel()
                        break
                    }
                }

                return WebReadFetchedResponse(
                    requestedURL: request.url, finalURL: finalURL, statusCode: http.statusCode,
                    mimeType: mimeType, suggestedFilename: suggestedFilename, headers: headers,
                    bytes: body, retrievedAt: retrievedAt,
                    redirectCount: redirectDelegate.redirectCount(for: bytes.task.taskIdentifier),
                    bodyWasTruncated: wasTruncated,
                    stoppedForUnsupportedContent: stoppedForUnsupportedContent
                )
            } onCancel: {
                self.cancel(callID: request.callID)
            }
        } catch is CancellationError {
            cancel(callID: request.callID)
            throw WebReadFailure.cancelled
        } catch let error as WebReadFailure {
            throw error
        } catch {
            if Task.isCancelled { throw WebReadFailure.cancelled }
            if redirectDelegate.rejectedRestrictedRequest { throw WebReadFailure.restricted }
            let code = (error as NSError).code
            throw WebReadFailure.transport("The HTTP request failed with network error \(code).")
        }
    }

    func cancel(callID: String) {
        let session = withLock { sessions.removeValue(forKey: callID) }
        session?.invalidateAndCancel()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func stringHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        let allowed = Set(["content-type", "content-length", "content-disposition", "content-language", "link", "content-location"])
        for (key, value) in response.allHeaderFields {
            let normalized = String(describing: key).lowercased()
            guard allowed.contains(normalized) else { continue }
            result[normalized] = String(describing: value)
        }
        return result
    }

    private static func isUnsupportedMime(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.contains("pdf") || mime.hasPrefix("image/")
            || mime.hasPrefix("audio/") || mime.hasPrefix("video/")
    }

    private static func hasBinarySignature(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) { return true }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.count >= 6, Array(bytes[0..<6]) == Array("GIF87a".utf8) { return true }
        if bytes.count >= 6, Array(bytes[0..<6]) == Array("GIF89a".utf8) { return true }
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)),
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return true }
        return false
    }
}
