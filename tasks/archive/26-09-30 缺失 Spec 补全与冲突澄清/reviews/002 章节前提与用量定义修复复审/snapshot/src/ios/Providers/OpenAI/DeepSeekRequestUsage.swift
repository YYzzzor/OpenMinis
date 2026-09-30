import Foundation
import CoreFoundation

/// 保留服务器最后一次报告的完整计费用量；缺失字段不能当作零。
struct DeepSeekRequestUsage: Sendable {
    let modelID: String
    let inputTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let startedAt: Date

    static func parse(_ usage: [String: Any], modelID: String, baseURL: String,
                      startedAt: Date, responsesAPI: Bool = false) -> Self? {
        guard DeepSeekPricing.supports(baseURL: baseURL, modelID: modelID) else { return nil }
        let inputKey = responsesAPI ? "input_tokens" : "prompt_tokens"
        let outputKey = responsesAPI ? "output_tokens" : "completion_tokens"
        let details = usage[responsesAPI ? "input_tokens_details" : "prompt_tokens_details"] as? [String: Any]
        guard let input = count(usage[inputKey]), let output = count(usage[outputKey]),
              let cached = count(details?["cached_tokens"] ?? usage["prompt_cache_hit_tokens"]),
              cached <= input else { return nil }
        if let miss = usage["prompt_cache_miss_tokens"], count(miss) != input - cached { return nil }
        return Self(modelID: modelID, inputTokens: input - cached, cacheReadTokens: cached,
                    outputTokens: output, startedAt: startedAt)
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = value as? Int, integer >= 0,
              number.decimalValue == Decimal(integer) else { return nil }
        return integer
    }
}
