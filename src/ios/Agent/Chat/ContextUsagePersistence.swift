import Foundation
import CryptoKit

/// 只保存用量、来源和校验摘要，不复制消息正文或凭据。
struct PersistedContextUsage: Codable, Equatable {
    let id: UUID
    let sessionID: String
    let usedTokens: Int
    let entryID: String
    let modelID: String
    let providerID: String
    let contextWindow: Int
    let configurationKey: String
    let history: ContextUsageHistoryAnchor

    func snapshot(matching identity: ContextUsageIdentity) -> ContextUsageSnapshot? {
        guard entryID == identity.entryID, modelID == identity.modelID,
              providerID == identity.providerID, contextWindow == identity.contextWindow else { return nil }
        return ContextUsageSnapshot(usedTokens: usedTokens, identity: identity, requestRevision: 0)
    }
}

struct ContextUsageHistoryAnchor: Codable, Equatable {
    let messageCount: Int
    let messageDigest: String
    let compactDigest: String

    static func digest<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 与页面缓存分离；淘汰聊天页面或重启进程不会丢失各会话的统计。
@MainActor
final class ContextUsagePersistence {
    static let shared = ContextUsagePersistence(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MinisX/context-usage.json"))

    private struct Archive: Codable {
        let version: Int
        let records: [String: PersistedContextUsage]
    }
    private let fileURL: URL
    private var records: [String: PersistedContextUsage] = [:]
    private var generations: [String: UInt64] = [:]
    private struct Scope: Hashable { let sessionID: String; let entryID: String; let includesBinding: Bool }
    private var configurationVersions: [Scope: (key: String?, revision: UInt)] = [:]
    private var nextConfigurationVersion: UInt = 0

    func configurationRevision(sessionID: String, entryID: String, key: String?, includesBinding: Bool = true) -> UInt {
        let scope = Scope(sessionID: sessionID, entryID: entryID, includesBinding: includesBinding)
        if let previous = configurationVersions[scope], previous.key == key { return previous.revision }
        nextConfigurationVersion &+= 1
        configurationVersions[scope] = (key, nextConfigurationVersion)
        return nextConfigurationVersion
    }


    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1 {
            records = archive.records.filter { key, value in
                key == value.sessionID && value.usedTokens > 0 && value.contextWindow > 0
                    && value.history.messageCount > 0
            }
        }
    }

    func record(for sessionID: String) -> PersistedContextUsage? { records[sessionID] }

    /// 页面实例可以更换；接收版本归属于会话，旧实例的结果也不能覆盖新实例。
    @discardableResult
    func beginOperation(sessionID: String) -> UInt64 {
        let next = (generations[sessionID] ?? 0) &+ 1
        generations[sessionID] = next
        return next
    }

    func isCurrent(sessionID: String, generation: UInt64) -> Bool {
        generations[sessionID] == generation
    }

    @discardableResult
    func save(_ record: PersistedContextUsage, generation: UInt64? = nil) throws -> Bool {
        if let generation, !isCurrent(sessionID: record.sessionID, generation: generation) { return false }
        records[record.sessionID] = record
        try write()
        return true
    }

    func remove(sessionID: String) throws {
        beginOperation(sessionID: sessionID)
        guard records.removeValue(forKey: sessionID) != nil else { return }
        try write()
    }

    /// 在配置每次保存时核对，A→B→A 也不能复活已失效的 A 统计。
    func reconcile(configurationKey: (String, String, Bool) -> String?) throws {
        // 也追踪尚无已保存统计的首个请求，保证相关配置 A→B→A 后拒绝旧结果。
        for scope in Array(configurationVersions.keys) {
            _ = configurationRevision(sessionID: scope.sessionID, entryID: scope.entryID,
                key: configurationKey(scope.sessionID, scope.entryID, scope.includesBinding), includesBinding: scope.includesBinding)
        }
        let retained = records.filter { _, value in configurationKey(value.sessionID, value.entryID, true) == value.configurationKey }
        guard retained.count != records.count else { return }
        for sessionID in records.keys where retained[sessionID] == nil { beginOperation(sessionID: sessionID) }
        records = retained
        try write()
    }

    private func write() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Archive(version: 1, records: records))
        try data.write(to: fileURL, options: .atomic)
    }
}
