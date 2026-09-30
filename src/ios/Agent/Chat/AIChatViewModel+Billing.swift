import Foundation

struct SessionCostRequest: Sendable {
    let sessionID: String
    let requestID: String
}

extension AIChatViewModel {
    var showsSessionBilling: Bool { sessionId == nil || sessionCostSummary != nil }

    var deepSeekAccountIdentity: DeepSeekAccountIdentity? {
        guard let entry = resolveCurrentEntry(),
              let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId),
              instance.isEnabled, instance.credentialType == .apiKey,
              !instance.azureMode,
              instance.providerType == .openAI || instance.providerType == .openAIResponses,
              DeepSeekPricing.supports(baseURL: instance.effectiveCustomBaseURL ?? "", modelID: entry.model.id)
        else { return nil }
        return DeepSeekAccountIdentity(providerID: instance.id,
            configRevision: ProviderConfigStore.shared.configRevision,
            authRevision: ProviderConfigStore.shared.authRevision)
    }

    func deepSeekBalanceKey(for identity: DeepSeekAccountIdentity?) -> String? {
        guard let identity, identity == deepSeekAccountIdentity else { return nil }
        return ProviderKeychainHelper.loadAPIKey(instanceId: identity.providerID)
    }

    func beginSessionCostRequest() async -> SessionCostRequest? {
        guard let sessionID = sessionId else { return nil }
        let request = SessionCostRequest(sessionID: sessionID, requestID: UUID().uuidString)
        guard await ChatStore.shared.beginSessionCostRequest(request) else { return nil }
        await refreshSessionCostSummary(sessionID: sessionID)
        return request
    }

    func finishSessionCostRequest(_ request: SessionCostRequest?, usage: DeepSeekRequestUsage?, completed: Bool) async {
        guard let request else { return }
        if completed, let usage, let record = DeepSeekPricing.estimate(
            modelID: usage.modelID, inputTokens: usage.inputTokens, cacheReadTokens: usage.cacheReadTokens,
            outputTokens: usage.outputTokens, requestID: request.requestID,
            startedAt: usage.startedAt, endedAt: Date()) {
            await ChatStore.shared.finishSessionCostRequest(request, record: record)
        }
        await refreshSessionCostSummary(sessionID: request.sessionID)
    }

    func refreshSessionCostSummary(sessionID: String) async {
        let summary = await ChatStore.shared.sessionCostSummary(sessionID: sessionID)
        guard self.sessionId == sessionID else { return }
        sessionCostSummary = summary
    }
}
