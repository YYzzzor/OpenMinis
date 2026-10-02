import Foundation

enum WebReadStatus: String, Codable, Sendable {
    case textReady = "text_ready"
    case partial
    case resourceOnly = "resource_only"
    case restricted
    case failed
    case cancelled
}

enum WebReadLocateStatus: String, Codable, Sendable {
    case found
    case notFoundInSavedContent = "not_found_in_saved_content"
    case notCovered = "not_covered"
}

struct WebReadScope: Hashable, Sendable {
    let sessionID: String
    let userRequestID: String
    let identityRevision: String

    static let anonymousIdentity = "anonymous-v1"

    init(sessionID: String, userRequestID: String, identityRevision: String = anonymousIdentity) {
        self.sessionID = sessionID
        self.userRequestID = userRequestID
        self.identityRevision = identityRevision
    }
}

struct WebReadRequest: Sendable {
    let url: String?
    let queryTarget: String?
    let renderRequested: Bool
    let documentID: String?
    let offset: Int?
    let limit: Int?

    init(
        url: String? = nil,
        queryTarget: String? = nil,
        renderRequested: Bool = false,
        documentID: String? = nil,
        offset: Int? = nil,
        limit: Int? = nil
    ) {
        self.url = url
        self.queryTarget = queryTarget
        self.renderRequested = renderRequested
        self.documentID = documentID
        self.offset = offset
        self.limit = limit
    }
}

struct WebReadContinuation: Codable, Sendable {
    let start: Int
    let end: Int
    let savedEnd: Int
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case savedEnd = "saved_end"
        case nextOffset = "next_offset"
    }
}

struct WebReadResource: Codable, Sendable {
    let url: String
    let type: String
    let readStatus: String
    let context: String?

    enum CodingKeys: String, CodingKey {
        case url
        case type
        case readStatus = "read_status"
        case context
    }
}

struct WebReadResult: Codable, Sendable {
    let url: String
    let title: String?
    let retrievedAt: String?
    let readStatus: WebReadStatus
    let content: String
    let limitations: [String]
    let requestedURL: String?
    let sourceNote: String?
    let documentID: String?
    let continuation: WebReadContinuation?
    let locateStatus: WebReadLocateStatus?
    let resources: [WebReadResource]?

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case retrievedAt = "retrieved_at"
        case readStatus = "read_status"
        case content
        case limitations
        case requestedURL = "requested_url"
        case sourceNote = "source_note"
        case documentID = "document_id"
        case continuation
        case locateStatus = "locate_status"
        case resources
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        if let title {
            try container.encode(title, forKey: .title)
        } else {
            try container.encodeNil(forKey: .title)
        }
        if let retrievedAt {
            try container.encode(retrievedAt, forKey: .retrievedAt)
        } else {
            try container.encodeNil(forKey: .retrievedAt)
        }
        try container.encode(readStatus, forKey: .readStatus)
        try container.encode(content, forKey: .content)
        try container.encode(limitations, forKey: .limitations)
        try container.encodeIfPresent(requestedURL, forKey: .requestedURL)
        try container.encodeIfPresent(sourceNote, forKey: .sourceNote)
        try container.encodeIfPresent(documentID, forKey: .documentID)
        try container.encodeIfPresent(continuation, forKey: .continuation)
        try container.encodeIfPresent(locateStatus, forKey: .locateStatus)
        try container.encodeIfPresent(resources, forKey: .resources)
    }
}

struct WebReadOutcome: Sendable {
    let json: String
    let isError: Bool
    let status: WebReadStatus
    let documentID: String?
}

struct WebReadConfiguration: Sendable {
    let totalTimeout: TimeInterval
    let maximumResponseBytes: Int
    let maximumDocumentScalars: Int
    let maximumResultBytes: Int
    /// HTTP 请求入口与匿名渲染入口合计的尝试上限；每个入口内的跳转由 maximumRedirects 单独限制。
    let maximumNetworkRequests: Int
    let maximumRedirects: Int
    let maximumConcurrentDownloads: Int
    let maximumConcurrentRenderers: Int
    let maximumCachedBytes: Int
    let maximumCachedDocuments: Int
    let documentLifetime: TimeInterval
    let resourceWaitTimeout: TimeInterval
    let renderTargetWaitTimeout: TimeInterval

    static let conservative = WebReadConfiguration(
        totalTimeout: 40,
        maximumResponseBytes: 2 * 1024 * 1024,
        maximumDocumentScalars: 120_000,
        maximumResultBytes: 12 * 1024,
        maximumNetworkRequests: 4,
        maximumRedirects: 8,
        maximumConcurrentDownloads: 3,
        maximumConcurrentRenderers: 1,
        maximumCachedBytes: 6 * 1024 * 1024,
        maximumCachedDocuments: 32,
        documentLifetime: 600,
        resourceWaitTimeout: 8,
        renderTargetWaitTimeout: 10
    )
}

struct WebReadFetchRequest: Sendable {
    let url: URL
    let callID: String
    let deadline: Date
    let maximumBytes: Int
    let maximumRedirects: Int
}

struct WebReadFetchedResponse: Sendable {
    let requestedURL: URL
    let finalURL: URL
    let statusCode: Int
    let mimeType: String?
    let suggestedFilename: String?
    let headers: [String: String]
    let bytes: Data
    let retrievedAt: Date
    let redirectCount: Int
    let bodyWasTruncated: Bool
    let stoppedForUnsupportedContent: Bool
}

protocol WebReadTransport: Sendable {
    func fetch(_ request: WebReadFetchRequest) async throws -> WebReadFetchedResponse
    func cancel(callID: String)
}

struct WebReadRenderedPage: Sendable {
    let title: String?
    let finalURL: URL
    let html: String
    let retrievedAt: Date
    let htmlWasTruncated: Bool
    let targetFound: Bool?
    let targetWaitExpired: Bool
    let hasLoadingIndicator: Bool
}

@MainActor
protocol WebReadRendering: AnyObject {
    func render(
        url: URL,
        callID: String,
        deadline: Date,
        queryTarget: String?,
        waitForTarget: Bool
    ) async throws -> WebReadRenderedPage
    func cancel(callID: String)
}

enum WebReadFailure: Error, Sendable {
    case invalidURL
    case invalidScope
    case notFound
    case deadlineExceeded
    case responseTooLarge
    case restricted
    case cancelled
    case resourceLimit
    case transport(String)
}
