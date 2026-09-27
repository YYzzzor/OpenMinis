import Foundation

/// Determines offload / compact / exhausted thresholds based on model context window size.
///
/// Tiers:
/// - **< 32K**: No auto-offload, no auto-compact. Prompt "start new / clear" when full.
/// - **32K–64K**: Auto-offload when remaining ≤ 10K. No auto-compact (user can manually).
///   Prompt "start new / clear" when exhausted.
/// - **64K–128K**: Auto-offload when remaining ≤ 20K. Auto-compact when remaining ≤ 10K.
/// - **≥ 128K**: Auto-offload when remaining ≤ 40K. Auto-compact when remaining ≤ 20K.
struct ContextPolicy {
    /// Tokens used must exceed this to trigger auto-offload. 0 = offload disabled.
    let offloadThreshold: Int
    /// Target token count after offloading. 0 = offload everything eligible.
    let offloadTarget: Int
    /// Tokens used must exceed this to trigger auto-compact. 0 = auto-compact disabled.
    let compactThreshold: Int
    /// When true, reaching the limit shows "start new session / clear" instead of compact.
    let exhaustedOnly: Bool
    /// Whether user-initiated manual compact is allowed.
    let manualCompactAllowed: Bool

    init(contextWindow: Int) {
        if contextWindow < 32_000 {
            // < 32K: no offload, no compact
            offloadThreshold = 0
            offloadTarget = 0
            compactThreshold = 0
            exhaustedOnly = true
            manualCompactAllowed = false
        } else if contextWindow < 64_000 {
            // 32K–64K: offload when remaining ≤ 10K, no auto-compact
            offloadThreshold = contextWindow - 10_000
            offloadTarget = contextWindow - 15_000
            compactThreshold = 0
            exhaustedOnly = true
            manualCompactAllowed = true
        } else if contextWindow < 128_000 {
            // 64K–128K: offload when remaining ≤ 20K, compact when remaining ≤ 10K
            offloadThreshold = contextWindow - 20_000
            offloadTarget = contextWindow - 30_000
            compactThreshold = contextWindow - 10_000
            exhaustedOnly = false
            manualCompactAllowed = true
        } else {
            // ≥ 128K: offload when remaining ≤ 40K, compact when remaining ≤ 20K
            offloadThreshold = contextWindow - 40_000
            offloadTarget = contextWindow - 60_000
            compactThreshold = contextWindow - 20_000
            exhaustedOnly = false
            manualCompactAllowed = true
        }
    }

    // MARK: - Pre-send Check

    /// Pre-send context check result.
    enum CheckResult {
        /// Context is fine, proceed normally.
        case ok
        /// Context is near capacity — auto-compact before sending.
        case needsCompact
        /// Context is exhausted — prompt user to start new session or clear chat.
        case exhausted
    }

    /// Evaluate current token usage against policy thresholds.
    func check(estimatedTokens: Int, contextWindow: Int) -> CheckResult {
        // Check compact threshold first (only for tiers that support auto-compact)
        if compactThreshold > 0, estimatedTokens >= compactThreshold {
            return .needsCompact
        }

        // For tiers where auto-compact is disabled, check if context is exhausted
        if exhaustedOnly {
            let exhaustedThreshold = offloadThreshold > 0
                ? offloadThreshold
                : Int(Double(contextWindow) * 0.90)
            if estimatedTokens >= exhaustedThreshold {
                return .exhausted
            }
        }

        return .ok
    }

    /// Whether auto-offload should trigger at the given token count.
    func shouldOffload(estimatedTokens: Int) -> Bool {
        offloadThreshold > 0 && estimatedTokens >= offloadThreshold
    }

}

/// 标识一次统计对应的模型来源，避免把旧模型的分子除以新模型的窗口。
struct ContextUsageIdentity: Equatable {
    let entryID: String
    let modelID: String
    let providerID: String
    let contextWindow: Int
    let configRevision: UInt
    var routeConfigRevision: UInt? = nil

    /// 比较请求路由本身；fallback 保存绑定会递增 revision，但实际模型仍可相同。
    func matchesRoute(_ other: ContextUsageIdentity) -> Bool {
        entryID == other.entryID
            && modelID == other.modelID
            && providerID == other.providerID
            && contextWindow == other.contextWindow
            && routeConfigRevision == other.routeConfigRevision
    }
}

/// 最近一次有效请求的输入上下文用量；不包含本地草稿或模型输出。
struct ContextUsageSnapshot: Equatable {
    let usedTokens: Int
    let contextWindow: Int
    let percentage: Int
    let fraction: Double

    fileprivate let identity: ContextUsageIdentity
    fileprivate let requestRevision: UInt64

    init?(
        usedTokens: Int,
        identity: ContextUsageIdentity,
        requestRevision: UInt64
    ) {
        guard identity.contextWindow > 0, usedTokens > 0 else { return nil }

        let ratio = Double(usedTokens) / Double(identity.contextWindow)
        let rawPercentage = ratio * 100
        self.usedTokens = usedTokens
        contextWindow = identity.contextWindow
        fraction = min(1, max(0, ratio))
        // 保留超限比例供 UI 提示；1000 是安全上限，对应 999%+ 的显示。
        percentage = rawPercentage >= 1000
            ? 1000
            : Int(rawPercentage.rounded(.toNearestOrAwayFromZero))
        self.identity = identity
        self.requestRevision = requestRevision
    }
}

/// 保存最近快照并拒绝已经失效请求的迟到结果。
struct ContextUsageState {
    private(set) var requestRevision: UInt64 = 0
    private(set) var latestSnapshot: ContextUsageSnapshot?

    /// 新请求只更新接收结果的版本；等待期间继续显示上次有效统计。
    mutating func beginRequest() -> UInt64 {
        requestRevision &+= 1
        return requestRevision
    }

    /// 压缩、截断或重载使旧输入不再适用，与普通续聊分开处理。
    mutating func invalidate() {
        _ = beginRequest()
        latestSnapshot = nil
    }

    @discardableResult
    mutating func record(
        usedTokens: Int,
        identity: ContextUsageIdentity,
        requestRevision: UInt64
    ) -> Bool {
        guard requestRevision == self.requestRevision,
              let snapshot = ContextUsageSnapshot(
                usedTokens: usedTokens,
                identity: identity,
                requestRevision: requestRevision
              ) else {
            return false
        }
        latestSnapshot = snapshot
        return true
    }

    /// 请求来源与当前路由必须同时匹配；把发布判断保留为纯逻辑，覆盖重试和配置切换边界。
    @discardableResult
    mutating func recordRequest(
        usedTokens: Int,
        initialEntryID: String?,
        streamEntryID: String?,
        streamConfigRevision: UInt?,
        capturedIdentities: [String: ContextUsageIdentity],
        currentIdentity: ContextUsageIdentity?,
        requestRevision: UInt64
    ) -> Bool {
        guard let streamEntryID, let streamConfigRevision,
              let capturedIdentity = capturedIdentities[streamEntryID],
              let currentIdentity,
              currentIdentity.entryID == streamEntryID,
              capturedIdentity.matchesRoute(currentIdentity),
              currentIdentity.configRevision == streamConfigRevision else {
            return false
        }
        // 同一 entry 跨过配置切换时拒绝旧统计；真正 fallback 到预捕获成员才允许新的配置修订。
        if streamEntryID == initialEntryID,
           capturedIdentity.configRevision != streamConfigRevision {
            return false
        }
        return record(
            usedTokens: usedTokens,
            identity: currentIdentity,
            requestRevision: requestRevision
        )
    }

    func snapshot(matching identity: ContextUsageIdentity) -> ContextUsageSnapshot? {
        guard let latestSnapshot,
              latestSnapshot.identity == identity else {
            return nil
        }
        return latestSnapshot
    }
}
