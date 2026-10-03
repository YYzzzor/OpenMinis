import Foundation

enum WebReadDocumentKind: String, Sendable, Equatable {
    case webRead = "web_read"
    case webSearch = "web_search"
}

struct WebReadSavedDocument: Sendable {
    let id: String
    let kind: WebReadDocumentKind
    let scope: WebReadScope
    let url: String
    let title: String?
    let retrievedAt: String?
    let content: String
    let limitations: [String]
    let requestedURL: String?
    let sourceNote: String?
    let resources: [WebReadResource]
    let contentIsComplete: Bool
    let createdAt: Date
}

struct WebReadDocumentSlice: Sendable {
    let document: WebReadSavedDocument
    let content: String
    let start: Int
    let end: Int
    let locateStatus: WebReadLocateStatus?
    let coverageKnownIncomplete: Bool
    let targetRangeLength: Int?

    var continuation: WebReadContinuation {
        WebReadContinuation(
            start: start,
            end: end,
            savedEnd: document.content.unicodeScalars.count,
            nextOffset: end < document.content.unicodeScalars.count ? end : nil
        )
    }
}

@MainActor
final class WebReadDocumentStore {
    static let shared = WebReadDocumentStore(configuration: .conservative)

    private struct Entry {
        var document: WebReadSavedDocument
        var lastAccess: Date
        var byteCount: Int { document.content.utf8.count }
    }

    let configuration: WebReadConfiguration
    private var entries: [String: Entry] = [:]
    private var cachedBytes = 0

    init(configuration: WebReadConfiguration) {
        self.configuration = configuration
    }

    var count: Int {
        purgeExpired()
        return entries.count
    }

    var totalCachedBytes: Int {
        purgeExpired()
        return cachedBytes
    }

    @discardableResult
    func save(
        content: String,
        scope: WebReadScope,
        url: String,
        title: String?,
        retrievedAt: String?,
        limitations: [String],
        requestedURL: String?,
        sourceNote: String?,
        resources: [WebReadResource],
        contentIsComplete: Bool,
        kind: WebReadDocumentKind = .webRead,
        maximumScalars: Int? = nil,
        now: Date = Date()
    ) -> WebReadSavedDocument {
        purgeExpired(now: now)
        // The scalar cap bounds per-document parsing; the byte cap remains an
        // eviction budget. Capping here by bytes used to turn oversized ASCII
        // web_read bodies into deceptively complete-looking short documents.
        let maximum = max(0, maximumScalars ?? configuration.maximumDocumentScalars)
        let bounded = Self.prefixScalars(content, maximum: maximum)
        let wasCut = bounded.unicodeScalars.count < content.unicodeScalars.count
        let document = WebReadSavedDocument(
            id: "wr_" + UUID().uuidString.lowercased(),
            kind: kind,
            scope: scope,
            url: url,
            title: title,
            retrievedAt: retrievedAt,
            content: bounded,
            limitations: limitations,
            requestedURL: requestedURL,
            sourceNote: sourceNote,
            resources: resources,
            contentIsComplete: contentIsComplete && !wasCut,
            createdAt: now
        )
        entries[document.id] = Entry(document: document, lastAccess: now)
        cachedBytes += document.content.utf8.count
        enforceLimits(now: now)
        return document
    }

    func contains(id: String, scope: WebReadScope, now: Date = Date()) -> Bool {
        purgeExpired(now: now)
        guard let entry = entries[id] else { return false }
        return entry.document.scope == scope
    }

    /// Returns a scoped document without applying the web_read slice limit.
    /// Search archives use this only to decode their bounded structured result list.
    func document(id: String, scope: WebReadScope, now: Date = Date()) -> WebReadSavedDocument? {
        purgeExpired(now: now)
        guard var entry = entries[id], entry.document.scope == scope else { return nil }
        entry.lastAccess = now
        entries[id] = entry
        return entry.document
    }

    func read(
        id: String,
        scope: WebReadScope,
        offset: Int? = nil,
        limit: Int? = nil,
        queryTarget: String? = nil,
        now: Date = Date()
    ) -> WebReadDocumentSlice? {
        purgeExpired(now: now)
        guard var entry = entries[id], entry.document.scope == scope else { return nil }
        entry.lastAccess = now
        entries[id] = entry

        let scalars = Array(entry.document.content.unicodeScalars)
        let total = scalars.count
        let boundedLimit = min(max(1, limit ?? 8_000), configuration.maximumResultBytes)
        let requestedOffset = min(max(0, offset ?? 0), total)
        let target = queryTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !target.isEmpty {
            if let targetRange = entry.document.content.range(of: target, options: [.caseInsensitive]) {
                let scalarView = entry.document.content.unicodeScalars
                guard let scalarStart = targetRange.lowerBound.samePosition(in: scalarView),
                      let scalarEnd = targetRange.upperBound.samePosition(in: scalarView) else {
                    return nil
                }
                let targetOffset = scalarView.distance(from: scalarView.startIndex, to: scalarStart)
                let targetLength = scalarView.distance(from: scalarStart, to: scalarEnd)
                guard targetLength <= configuration.maximumResultBytes else {
                    return WebReadDocumentSlice(
                        document: entry.document,
                        content: "",
                        start: targetOffset,
                        end: targetOffset,
                        locateStatus: nil,
                        coverageKnownIncomplete: !entry.document.contentIsComplete,
                        targetRangeLength: targetLength
                    )
                }
                let effectiveLimit = min(
                    configuration.maximumResultBytes,
                    max(boundedLimit, targetLength)
                )
                let targetEnd = targetOffset + targetLength
                let contextBefore = max(0, (effectiveLimit - targetLength) / 3)
                let latestStart = max(0, total - effectiveLimit)
                let start = min(max(0, targetOffset - contextBefore), latestStart)
                // 续读必须完整包含命中词；上下文预算不足时缩小上下文，而不是截断命中。
                let end = min(total, max(targetEnd, start + effectiveLimit))
                return WebReadDocumentSlice(
                    document: entry.document,
                    content: Self.scalarSlice(scalars, start: start, end: end),
                    start: start,
                    end: end,
                    locateStatus: .found,
                    coverageKnownIncomplete: !entry.document.contentIsComplete,
                    targetRangeLength: targetLength
                )
            }
            return WebReadDocumentSlice(
                document: entry.document,
                content: "",
                start: total,
                end: total,
                locateStatus: entry.document.contentIsComplete ? .notFoundInSavedContent : .notCovered,
                coverageKnownIncomplete: !entry.document.contentIsComplete,
                targetRangeLength: nil
            )
        }

        let end = min(total, requestedOffset + boundedLimit)
        return WebReadDocumentSlice(
            document: entry.document,
            content: Self.scalarSlice(scalars, start: requestedOffset, end: end),
            start: requestedOffset,
            end: end,
            locateStatus: nil,
            coverageKnownIncomplete: !entry.document.contentIsComplete,
            targetRangeLength: nil
        )
    }

    func remove(id: String, scope: WebReadScope) {
        guard let entry = entries[id], entry.document.scope == scope else { return }
        entries.removeValue(forKey: id)
        cachedBytes = max(0, cachedBytes - entry.byteCount)
    }

    func removeAll(scope: WebReadScope) {
        remove(where: { $0.scope == scope })
    }

    func removeAll(sessionID: String) {
        remove(where: { $0.scope.sessionID == sessionID })
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        cachedBytes = 0
    }

    private func purgeExpired(now: Date = Date()) {
        let lifetime = configuration.documentLifetime
        remove(where: { now.timeIntervalSince($0.createdAt) > lifetime })
    }

    private func enforceLimits(now: Date) {
        while entries.count > configuration.maximumCachedDocuments
            || cachedBytes > configuration.maximumCachedBytes {
            guard let oldest = entries.values.min(by: { $0.lastAccess < $1.lastAccess }) else { break }
            entries.removeValue(forKey: oldest.document.id)
            cachedBytes = max(0, cachedBytes - oldest.byteCount)
        }
        _ = now
    }

    private func remove(where predicate: (WebReadSavedDocument) -> Bool) {
        let ids = entries.compactMap { predicate($0.value.document) ? $0.key : nil }
        for id in ids {
            if let entry = entries.removeValue(forKey: id) {
                cachedBytes = max(0, cachedBytes - entry.byteCount)
            }
        }
    }

    static func prefixScalars(_ value: String, maximum: Int) -> String {
        guard maximum >= 0, value.unicodeScalars.count > maximum else { return value }
        let scalars = Array(value.unicodeScalars.prefix(maximum))
        return String(String.UnicodeScalarView(scalars))
    }

    private static func scalarSlice(_ scalars: [Unicode.Scalar], start: Int, end: Int) -> String {
        guard start < end else { return "" }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }
}
