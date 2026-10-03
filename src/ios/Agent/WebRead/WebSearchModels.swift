import Foundation

enum WebSearchStatus: String, Codable, Sendable {
    case results
    case noResults = "no_results"
    case verificationRequired = "verification_required"
    case partial
    case failed
    case cancelled
}

struct WebSearchRequest: Sendable {
    let query: String
    let documentID: String?
    let offset: Int?
    let limit: Int?
    let resultIndex: Int?
    let inputWasTruncated: Bool

    init(
        query: String,
        documentID: String? = nil,
        offset: Int? = nil,
        limit: Int? = nil,
        resultIndex: Int? = nil,
        inputWasTruncated: Bool = false
    ) {
        self.query = query
        self.documentID = documentID
        self.offset = offset
        self.limit = limit
        self.resultIndex = resultIndex
        self.inputWasTruncated = inputWasTruncated
    }
}

struct WebSearchEntry: Codable, Sendable, Equatable {
    let title: String
    let snippet: String?
    let url: String
}

struct WebSearchContinuation: Codable, Sendable, Equatable {
    let start: Int
    let end: Int
    let savedEnd: Int
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case start, end
        case savedEnd = "saved_end"
        case nextOffset = "next_offset"
    }
}

struct WebSearchResultFragment: Codable, Sendable, Equatable {
    let resultIndex: Int
    let start: Int
    let end: Int
    let savedEnd: Int
    let nextOffset: Int?
    let contentFormat: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case start, end, content
        case resultIndex = "result_index"
        case savedEnd = "saved_end"
        case nextOffset = "next_offset"
        case contentFormat = "content_format"
    }
}

struct WebSearchFormField: Codable, Sendable, Equatable {
    let name: String
    let value: String
}

struct WebSearchResult: Codable, Sendable {
    let query: String
    let engine: String
    let status: WebSearchStatus
    let retrievedAt: String?
    let results: [WebSearchEntry]
    let limitations: [String]
    let documentID: String?
    let continuation: WebSearchContinuation?
    let resultFragment: WebSearchResultFragment?
    let nextPageURL: String?
    let nextPageMethod: String?
    let nextPageStart: Int?
    let nextPageParameters: [WebSearchFormField]?
    let coverage: String

    init(
        query: String, engine: String, status: WebSearchStatus, retrievedAt: String?,
        results: [WebSearchEntry], limitations: [String], documentID: String?,
        continuation: WebSearchContinuation?, resultFragment: WebSearchResultFragment? = nil,
        nextPageURL: String?, nextPageMethod: String?, nextPageStart: Int?,
        nextPageParameters: [WebSearchFormField]? = nil, coverage: String
    ) {
        self.query = query
        self.engine = engine
        self.status = status
        self.retrievedAt = retrievedAt
        self.results = results
        self.limitations = limitations
        self.documentID = documentID
        self.continuation = continuation
        self.resultFragment = resultFragment
        self.nextPageURL = nextPageURL
        self.nextPageMethod = nextPageMethod
        self.nextPageStart = nextPageStart
        self.nextPageParameters = nextPageParameters
        self.coverage = coverage
    }

    enum CodingKeys: String, CodingKey {
        case query, engine, status, results, limitations, coverage
        case retrievedAt = "retrieved_at"
        case documentID = "document_id"
        case continuation
        case resultFragment = "result_fragment"
        case nextPageURL = "next_page_url"
        case nextPageMethod = "next_page_method"
        case nextPageStart = "next_page_start"
        case nextPageParameters = "next_page_parameters"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(query, forKey: .query)
        try container.encode(engine, forKey: .engine)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(retrievedAt, forKey: .retrievedAt)
        try container.encode(results, forKey: .results)
        try container.encode(limitations, forKey: .limitations)
        try container.encodeIfPresent(documentID, forKey: .documentID)
        try container.encodeIfPresent(continuation, forKey: .continuation)
        try container.encodeIfPresent(resultFragment, forKey: .resultFragment)
        try container.encodeIfPresent(nextPageURL, forKey: .nextPageURL)
        try container.encodeIfPresent(nextPageMethod, forKey: .nextPageMethod)
        try container.encodeIfPresent(nextPageStart, forKey: .nextPageStart)
        try container.encodeIfPresent(nextPageParameters, forKey: .nextPageParameters)
        try container.encode(coverage, forKey: .coverage)
    }
}

struct WebSearchOutcome: Sendable {
    let json: String
    let isError: Bool
    let status: WebSearchStatus
    let documentID: String?
}

struct WebSearchConfiguration: Sendable {
    let totalTimeout: TimeInterval
    let maximumResponseBytes: Int
    let maximumResults: Int
    let maximumOutputBytes: Int
    let maximumArchiveScalars: Int
    let maximumArchiveBytes: Int
    let maximumRedirects: Int
    let maximumActiveSearches: Int
    let maximumQueuedSearches: Int
    let maximumDiagnostics: Int

    static let conservative = WebSearchConfiguration(
        totalTimeout: 40,
        maximumResponseBytes: 2 * 1024 * 1024,
        maximumResults: 512,
        maximumOutputBytes: 10 * 1024,
        maximumArchiveScalars: 2_000_000,
        maximumArchiveBytes: 2 * 1024 * 1024,
        maximumRedirects: 6,
        maximumActiveSearches: 2,
        maximumQueuedSearches: 4,
        maximumDiagnostics: 128
    )
}

struct WebSearchDiagnostic: Sendable {
    let sessionID: String
    let userRequestID: String
    let batchID: String
    let callID: String
    let durationMilliseconds: Int
    let networkAttempts: Int
    let redirects: Int
    let responseBytes: Int
    let fallbackUsed: Bool
    let status: WebSearchStatus
}

struct WebSearchExtraction: Sendable {
    let results: [WebSearchEntry]
    let hasResultStructure: Bool
    let explicitlyNoResults: Bool
    let verificationRequired: Bool
    let resultsTruncated: Bool
    let resultAnchors: Int
    let rejectedResultAnchors: Int
    let nextPageURL: String?
    let nextPageMethod: String?
    let nextPageStart: Int?
    let nextPageParameters: [WebSearchFormField]?
}

struct WebSearchFetchResult: Sendable {
    let extraction: WebSearchExtraction
    let retrievedAt: String?
    let responseBytes: Int
    let wasTruncated: Bool
    let loadingIndicator: Bool
}

struct WebSearchArchive: Codable, Sendable {
    let query: String
    let engine: String
    let status: WebSearchStatus
    let retrievedAt: String?
    let results: [WebSearchEntry]
    let limitations: [String]
    let nextPageURL: String?
    let nextPageMethod: String?
    let nextPageStart: Int?
    let nextPageParameters: [WebSearchFormField]?
    let coverage: String

    enum CodingKeys: String, CodingKey {
        case query, engine, status, results, limitations, coverage
        case retrievedAt = "retrieved_at"
        case nextPageURL = "next_page_url"
        case nextPageMethod = "next_page_method"
        case nextPageStart = "next_page_start"
        case nextPageParameters = "next_page_parameters"
    }
}
