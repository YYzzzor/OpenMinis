//
//  AIChatViewModel+ContextUsage.swift
//  Minis - AIChatViewModel 扩展（Agent/Chat）
//
//  上下文用量、会话 token 统计和模型能力查询（上下文窗口、推理、思考强度）。
//  contextUsageIdentity、recordContextUsage 等用量快照函数是 MinisX 独有的，
//  职责最接近本文件，所以放在这里。
//  代码从 AIChatViewModel.swift 逐字移出。
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UIKit
import os.log

private let logger = AppLogger(category: "AIChatVM")

extension AIChatViewModel {

    /// 只在统计仍属于当前已解析模型时返回，避免显示历史会话或旧模型的占比。
    var currentContextUsage: ContextUsageSnapshot? {
        guard remoteDeviceId == nil, let sessionId, let record = loadedContextUsage,
              record.sessionID == sessionId,
              ContextUsagePersistence.shared.record(for: sessionId)?.id == record.id,
              let entry = resolveCurrentEntry(),
              ProviderConfigStore.shared.contextUsageConfigurationKey(sessionID: sessionId, entryID: entry.id) == record.configurationKey else { return nil }
        return record.snapshot(matching: contextUsageIdentity(for: entry))
    }

    /// Session-level token totals.
    var sessionTokenStats: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int, context: Int, loopCount: Int) {
        var context = 0
        var toolCalls = 0
        for msg in messages where msg.role == .assistant {
            if let u = msg.usage, u.latestContextTokens > 0 {
                context = u.latestContextTokens
            }
            for block in msg.blocks {
                switch block.kind {
                case .text, .info: break
                default: toolCalls += 1
                }
            }
        }
        let assistantCount = messages.filter({ $0.role == .assistant }).count
        return (sessionInputTokens, sessionOutputTokens, sessionCacheReadTokens, sessionCacheWriteTokens, context, max(toolCalls, assistantCount))
    }

    /// Context window size of the current model (from models.dev or heuristic).
    /// Resolved via `resolveCurrentEntry()` so the UI shows the same window the
    /// send path and capacity checks use (availability re-routing included).
    var currentModelContextWindow: Int? {
        guard let entry = resolveCurrentEntry() else { return nil }
        return effectiveContextWindow(for: entry.model)
    }

    func contextUsageIdentity(for entry: ModelEntry) -> ContextUsageIdentity {
        let sid = sessionId ?? ""
        let key = ProviderConfigStore.shared.contextUsageConfigurationKey(sessionID: sid, entryID: entry.id)
        let routeKey = ProviderConfigStore.shared.contextUsageConfigurationKey(sessionID: sid, entryID: entry.id, includesBinding: false)
        return ContextUsageIdentity(
            entryID: entry.id, modelID: entry.model.id, providerID: entry.providerInstanceId,
            contextWindow: effectiveContextWindow(for: entry.model),
            // 配置版本按会话和请求来源分开，另一会话的保存不丢弃本次有效 usage。
            configRevision: ContextUsagePersistence.shared.configurationRevision(sessionID: sid, entryID: entry.id, key: key),
            // fallback 可以改写绑定，但不能借此接受请求途中被改过的 provider 配置。
            routeConfigRevision: ContextUsagePersistence.shared.configurationRevision(sessionID: sid, entryID: entry.id, key: routeKey, includesBinding: false)
        )
    }

    func captureContextUsageIdentities(
        activeEntryId: String?,
        activeGroupId: String?
    ) -> [String: ContextUsageIdentity] {
        let store = ProviderConfigStore.shared
        var entryIDs = Set<String>()
        if let activeEntryId { entryIDs.insert(activeEntryId) }
        if let activeGroupId, let group = store.group(for: activeGroupId) {
            entryIDs.formUnion(group.memberEntryIds)
        }

        var identities: [String: ContextUsageIdentity] = [:]
        for entryID in entryIDs {
            guard let entry = store.entry(for: entryID) else { continue }
            identities[entryID] = contextUsageIdentity(for: entry)
        }
        return identities
    }

    func beginContextUsageRequest() -> UInt64 {
        if let sessionId { contextUsageGeneration = ContextUsagePersistence.shared.beginOperation(sessionID: sessionId) }
        var state = contextUsageState
        let revision = state.beginRequest()
        contextUsageState = state
        return revision
    }

    /// 真正截断或改写上下文时，同时清除内存与持久记录。
    func invalidateContextUsage() {
        contextUsageState.invalidate()
        loadedContextUsage = nil
        if let sessionId, remoteDeviceId == nil {
            do { try ContextUsagePersistence.shared.remove(sessionID: sessionId) }
            catch { logger.error("Failed to remove stored context usage: \(error)") }
        }
    }

    /// 页面重载只作废旧回调；会话记录验证通过后可以继续使用。
    func beginContextUsageReload() -> UInt64 {
        if let sessionId { contextUsageGeneration = ContextUsagePersistence.shared.beginOperation(sessionID: sessionId) }
        contextUsageState.invalidate()
        return contextUsageState.requestRevision
    }

    func restoreContextUsage(sessionID: String, revision: UInt64) async {
        guard remoteDeviceId == nil,
              let record = ContextUsagePersistence.shared.record(for: sessionID) else { return }
        let generation = contextUsageGeneration
        let history = await ChatStore.shared.contextUsageHistoryAnchor(sessionID: sessionID, prefixCount: record.history.messageCount)
        guard ContextUsagePersistence.shared.isCurrent(sessionID: sessionID, generation: generation),
              self.sessionId == sessionID, contextUsageState.requestRevision == revision,
              ContextUsagePersistence.shared.record(for: sessionID)?.id == record.id else { return }
        guard history == record.history,
              let entry = resolveCurrentEntry(), record.snapshot(matching: contextUsageIdentity(for: entry)) != nil,
              ProviderConfigStore.shared.contextUsageConfigurationKey(sessionID: sessionID, entryID: entry.id) == record.configurationKey else {
            invalidateContextUsage()
            return
        }
        loadedContextUsage = record
    }

    func recordContextUsage(
        _ usage: TokenUsage,
        initialEntryId: String?,
        streamEntryId: String?,
        streamConfigRevision: UInt?,
        identities: [String: ContextUsageIdentity],
        requestRevision: UInt64
    ) async {
        guard remoteDeviceId == nil, let sessionId else { return }
        let generation = contextUsageGeneration
        let history = await ChatStore.shared.contextUsageHistoryAnchor(sessionID: sessionId)
        guard ContextUsagePersistence.shared.isCurrent(sessionID: sessionId, generation: generation),
              self.sessionId == sessionId, let history else { return }
        let currentIdentity = resolveCurrentEntry().map { contextUsageIdentity(for: $0) }
        var state = contextUsageState
        guard state.recordRequest(
            usedTokens: usage.latestContextTokens,
            initialEntryID: initialEntryId,
            streamEntryID: streamEntryId,
            streamConfigRevision: streamConfigRevision,
            capturedIdentities: identities,
            currentIdentity: currentIdentity,
            requestRevision: requestRevision
        ) else {
            return
        }
        guard let identity = currentIdentity,
              let configurationKey = ProviderConfigStore.shared.contextUsageConfigurationKey(sessionID: sessionId, entryID: identity.entryID) else { return }
        let record = PersistedContextUsage(
            id: UUID(), sessionID: sessionId, usedTokens: usage.latestContextTokens,
            entryID: identity.entryID, modelID: identity.modelID, providerID: identity.providerID,
            contextWindow: identity.contextWindow, configurationKey: configurationKey, history: history
        )
        do {
            guard try ContextUsagePersistence.shared.save(record, generation: generation) else { return }
        } catch { logger.error("Failed to save context usage: \(error)") }
        contextUsageState = state
        loadedContextUsage = record
    }

    /// Whether the current model (or any model in the group) supports reasoning/thinking.
    ///
    /// Tri-state handling of `model.supportsReasoning`:
    /// - `true`  → supported
    /// - `false` → not supported
    /// - `nil`   → unknown (e.g. DeepSeek V4 fetched from `/v1/models`, which
    ///            returns no capability metadata). Treat as allowed so users
    ///            can still opt into thinking manually; sending the thinking
    ///            params to a non-reasoning model is generally a no-op on the
    ///            server side, whereas hiding the toggle on a reasoning-capable
    ///            model makes the feature unreachable.
    var currentModelSupportsReasoning: Bool {
        let store = ProviderConfigStore.shared

        // Try session binding first
        if let sid = sessionId, let binding = store.binding(for: sid) {
            return checkBindingSupportsReasoning(binding, store: store)
        }

        // No session yet — resolve from default group
        if let entry = resolveCurrentEntry() {
            return Self.entryAllowsReasoning(entry, store: store)
        }

        // Fallback: if user already set pending thinking, honor it
        return (pendingThinkingLevel ?? .off) != .off
    }

    var availableThinkingLevels: [ThinkingLevel] {
        // [T-thinking-levels-data-driven] Offer one option per DISTINCT wire
        // tier the model declares, instead of every level below a ceiling.
        // The old ladder let four options collapse onto a single
        // `reasoning_effort` — verified on-device 2026-08-01: glm-5.2
        // (declares ["high","max"]) sent "high" for Low/Med/High/XHigh alike,
        // while "max" was declared yet unreachable. See
        // `ModelEntry.selectableThinkingLevels` for the fallback rules.
        guard let entry = resolveCurrentEntry() else {
            return ThinkingLevel.allCases.filter { $0 != .off && $0 <= .xhigh }
        }
        return entry.selectableThinkingLevels
    }

    /// Whether a model entry should expose the thinking toggle.
    ///
    /// Base rule (tri-state, unchanged): `supportsReasoning ?? true` — `true`
    /// and unknown (`nil`) both allow the toggle, only an explicit `false`
    /// hides it.
    ///
    /// OpenAI-compatible providers additionally OVERRIDE an explicit `false`:
    /// their backend usually accepts thinking params even when models.dev
    /// tagged the model non-reasoning, so we let the user opt in. Two groups:
    ///   - `.openAI` / `.openAIResponses` ONLY when they have a `customBaseURL`
    ///     (Ollama / LM Studio / DashScope / self-hosted gateways). Official
    ///     OpenAI (no custom base) keeps the strict `?? true` rule so a model
    ///     genuinely marked `false` there still hides the toggle.
    ///   - `.openRouter` / `.xAI` always — these are inherently third-party /
    ///     aggregator OpenAI-compatible backends (no official-vs-custom split;
    ///     their `customBaseURL` is nil because they use a fixed built-in base),
    ///     and their thinking injection (`reasoning.effort` / OpenAIProvider
    ///     path) is model-id driven, not gated on `supportsReasoning`.
    /// All other provider types (anthropic, gemini, …) keep the strict rule,
    /// so a model genuinely marked `false` there still hides the toggle.
    static func entryAllowsReasoning(_ entry: ModelEntry, store: ProviderConfigStore) -> Bool {
        if entry.model.supportsReasoning != false {
            return true  // true or nil → allowed
        }
        // Explicit false: allow for OpenAI-compatible providers.
        guard let instance = store.instance(for: entry.providerInstanceId) else { return false }
        switch instance.providerType {
        case .openAI, .openAIResponses:
            // Custom/local base only — never official OpenAI.
            return instance.customBaseURL?.isEmpty == false
        case .openRouter, .xAI, .kimiCode:
            return true
        case .anthropic, .gemini, .antigravity, .unsupported:
            return false
        }
    }

    private func checkBindingSupportsReasoning(_ binding: SessionModelBinding, store: ProviderConfigStore) -> Bool {
        switch binding.primarySource {
        case .directEntry(let id, _):
            guard let entry = store.entry(for: id) else { return false }
            return Self.entryAllowsReasoning(entry, store: store)
        case .group(let groupId, let resolvedId):
            // Check resolved model first
            if let entry = store.entry(for: resolvedId),
               Self.entryAllowsReasoning(entry, store: store) {
                return true
            }
            // Check any model in the group
            guard let group = store.group(for: groupId) else { return false }
            return group.memberEntryIds.contains { memberId in
                guard let entry = store.entry(for: memberId) else { return false }
                return Self.entryAllowsReasoning(entry, store: store)
            }
        }
    }

    /// Max output tokens of the current model (from models.dev).
    var currentModelMaxOutputTokens: Int? {
        guard let sid = sessionId,
              let binding = ProviderConfigStore.shared.binding(for: sid) else { return nil }
        let entryId: String? = switch binding.primarySource {
        case .directEntry(let id, _): id
        case .group(_, let resolvedId): resolvedId
        }
        guard let entryId, let entry = ProviderConfigStore.shared.entry(for: entryId) else { return nil }
        return entry.model.maxOutputTokens
    }

    /// Thinking mode info for the current model.
    var currentModelThinkingInfo: (supported: Bool, enabled: Bool, level: String)? {
        guard let sid = sessionId,
              let binding = ProviderConfigStore.shared.binding(for: sid) else { return nil }
        // Resolve entry: for groups, try resolved first, fallback to first member
        let entryId: String? = switch binding.primarySource {
        case .directEntry(let id, _): id
        case .group(_, let resolvedId): resolvedId
        }
        guard let entryId else { return nil }
        // If resolved entry is gone (stale UUID), try first group member
        let entry: ModelEntry?
        if let e = ProviderConfigStore.shared.entry(for: entryId) {
            entry = e
        } else if case .group(let gid, _) = binding.primarySource,
                  let group = ProviderConfigStore.shared.group(for: gid),
                  let firstId = group.memberEntryIds.first {
            entry = ProviderConfigStore.shared.entry(for: firstId)
        } else {
            entry = nil
        }
        guard let entry,
              let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId) else { return nil }
        let model = entry.model
        // Use the same allow-rule as `currentModelSupportsReasoning` so the
        // thinking info card stays consistent with the slash-menu toggle
        // availability: `nil` allowed, and custom-base OpenAI-compatible
        // providers also allowed even when explicitly `false`.
        let supported = Self.entryAllowsReasoning(entry, store: ProviderConfigStore.shared)
        let cfg = ProviderConfigStore.shared.inferenceConfig(for: sid) ?? SessionInferenceConfig()
        let enabled = cfg.thinkingEnabled

        let level: String
        if !enabled {
            level = "—"
        } else {
            let thinkLvl = cfg.thinkingLevel
            switch instance.providerType {
            case .anthropic:
                level = "budget: \(AnthropicAgentProvider.thinkingBudget(for: model, maxTokens: 64000, level: thinkLvl))"
            case .gemini:
                level = thinkLvl.displayName
            case .openAI, .openAIResponses, .openRouter, .xAI, .kimiCode:
                level = OpenAIAgentProvider.reasoningEffort(for: model, level: thinkLvl) ?? "—"
            case .unsupported:
                level = "—"
            case .antigravity:
                let lid = model.id.lowercased()
                if lid.contains("claude") { level = "budget: \(AnthropicAgentProvider.thinkingBudget(for: model, maxTokens: 64000, level: thinkLvl))" }
                else { level = thinkLvl.displayName }
            }
        }
        return (supported, enabled, level)
    }

    /// Average output tokens per second across this session.
    var sessionOutputTokensPerSecond: Double {
        guard sessionStreamDuration > 0 else { return 0 }
        return Double(sessionStreamOutputTokens) / sessionStreamDuration
    }

}
