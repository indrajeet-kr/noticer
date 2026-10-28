import Foundation

/// Published Standard-mode Muse Spark rates, per token.
/// Contributor-mode prices are not used. The default model id is the standard one.
public struct UsageCostRates: Equatable, Sendable {
    public var uncachedInputUSDPerToken: Double
    public var cachedInputUSDPerToken: Double
    public var outputUSDPerToken: Double

    public init(
        uncachedInputUSDPerToken: Double,
        cachedInputUSDPerToken: Double,
        outputUSDPerToken: Double
    ) {
        self.uncachedInputUSDPerToken = uncachedInputUSDPerToken
        self.cachedInputUSDPerToken = cachedInputUSDPerToken
        self.outputUSDPerToken = outputUSDPerToken
    }

    /// $1.25 / $0.15 / $4.25 per million tokens. Reasoning tokens are output tokens.
    public static let museSparkStandard = UsageCostRates(
        uncachedInputUSDPerToken: 1.25 / 1_000_000,
        cachedInputUSDPerToken: 0.15 / 1_000_000,
        outputUSDPerToken: 4.25 / 1_000_000
    )
}

/// Token counts from a completion `usage` object, plus a dollar figure read from those counts.
///
/// The chat-completions schema has no dollar field. When a payload does include
/// `cost`, `cost_usd`, or `total_cost`, that number is `reportedCostUSD` and wins.
/// Otherwise `costUSD` is the estimate from the token counts and `UsageCostRates`.
public struct ModelUsage: Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var reasoningTokens: Int
    public var cachedPromptTokens: Int
    public var reportedCostUSD: Double?
    public var estimatedCostUSD: Double

    public var costUSD: Double {
        reportedCostUSD ?? estimatedCostUSD
    }

    public init(
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        reasoningTokens: Int,
        cachedPromptTokens: Int,
        reportedCostUSD: Double?,
        estimatedCostUSD: Double
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.reasoningTokens = reasoningTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.reportedCostUSD = reportedCostUSD
        self.estimatedCostUSD = estimatedCostUSD
    }

    public static func read(usage: JSONValue?, rates: UsageCostRates) -> ModelUsage? {
        guard case .object(let object)? = usage else {
            return nil
        }
        let prompt = int(object["prompt_tokens"])
        let completion = int(object["completion_tokens"])
        let total = int(object["total_tokens"])
        let reasoning = int(object["completion_tokens_details"], nested: "reasoning_tokens")
        var cached = int(object["prompt_tokens_details"], nested: "cached_tokens")
        if cached > prompt {
            cached = prompt
        }
        let uncached = max(0, prompt - cached)
        let estimated = Double(uncached) * rates.uncachedInputUSDPerToken
            + Double(cached) * rates.cachedInputUSDPerToken
            + Double(completion) * rates.outputUSDPerToken
        return ModelUsage(
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: total,
            reasoningTokens: reasoning,
            cachedPromptTokens: cached,
            reportedCostUSD: reportedCost(object),
            estimatedCostUSD: estimated
        )
    }

    private static func reportedCost(_ object: [String: JSONValue]) -> Double? {
        for key in ["cost", "cost_usd", "total_cost"] {
            if case .number(let value)? = object[key] {
                return value
            }
        }
        return nil
    }

    private static func int(_ value: JSONValue?) -> Int {
        guard case .number(let number)? = value else {
            return 0
        }
        return Int(number.rounded())
    }

    private static func int(_ value: JSONValue?, nested key: String) -> Int {
        guard case .object(let object)? = value else {
            return 0
        }
        return int(object[key])
    }
}
