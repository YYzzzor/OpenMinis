import Foundation
import Combine

struct DeepSeekAccountIdentity: Hashable {
    let providerID: String
    let configRevision: UInt
    let authRevision: UInt
}

/// 禁止重定向，避免把账户凭据发给余额接口之外的地址。
private final class DeepSeekBalanceRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum DeepSeekBalanceClient {
    enum Failure: Error { case unavailable, oversized }

    static func makeRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        return request
    }

    static func fetch(apiKey: String) async throws -> DeepSeekBalance {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: DeepSeekBalanceRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: makeRequest(apiKey: apiKey))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw Failure.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16_384 else { throw Failure.oversized }
            data.append(byte)
        }
        return try DeepSeekBalance.decode(data)
    }
}

/// 页面拥有查询状态；只有一个账户、一个结果缓存，不在后台轮询。
@MainActor
final class DeepSeekBalanceModel: ObservableObject {
    @Published private(set) var amountCNY: Decimal?
    @Published private(set) var isLoading = false
    @Published private(set) var hasFailed = false
    @Published private(set) var updatedAt: Date?
    private var identity: DeepSeekAccountIdentity?
    private var generation: UInt = 0
    private let fetch: (String) async throws -> DeepSeekBalance

    init(fetch: @escaping (String) async throws -> DeepSeekBalance = DeepSeekBalanceClient.fetch) {
        self.fetch = fetch
    }

    func isCurrent(_ account: DeepSeekAccountIdentity?) -> Bool {
        account != nil && account == identity
    }

    func refresh(identity requested: DeepSeekAccountIdentity?, force: Bool = false,
                 apiKey: () -> String?) async {
        if identity != requested {
            generation &+= 1
            identity = requested
            amountCNY = nil
            updatedAt = nil
            hasFailed = false
            isLoading = false
        }
        guard requested != nil else { return }
        if !force, let updatedAt, Date().timeIntervalSince(updatedAt) < 60 { return }
        generation &+= 1
        let current = generation
        guard let key = apiKey(), !key.isEmpty else {
            amountCNY = nil
            updatedAt = nil
            hasFailed = true
            isLoading = false
            return
        }
        isLoading = true
        hasFailed = false
        // 刷新失败后不把旧余额继续当作实时数值。
        amountCNY = nil
        updatedAt = nil
        do {
            let balance = try await fetch(key)
            try Task.checkCancellation()
            guard current == generation, requested == identity else { return }
            amountCNY = balance.amountCNY
            updatedAt = Date()
            isLoading = false
        } catch {
            guard current == generation, requested == identity else { return }
            isLoading = false
            hasFailed = !Task.isCancelled
        }
    }
}
