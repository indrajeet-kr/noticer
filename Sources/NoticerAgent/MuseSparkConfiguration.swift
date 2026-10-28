import Foundation

/// Knobs for one Muse Spark chat-completions client.
///
/// `endpoint` may be the API root (`https://api.meta.ai/v1`) or the full
/// chat-completions URL. `postURL()` sends the request to the full path.
/// `reasoningEffort` defaults to `low`. `none` is rejected before any request.
/// `maxTokens` defaults to 1024 because reasoning tokens count toward that cap.
/// Pass nil to omit the field. A set value under `MuseSparkModelClient.minimumMaxTokens` is rejected.
public struct MuseSparkConfiguration: Equatable, Sendable {
    public static let defaultReasoningEffort = "low"
    public static let allowedReasoningEfforts = ["minimal", "low", "medium", "high", "xhigh", "max"]

    public var endpoint: URL
    public var modelID: String
    public var reasoningEffort: String
    public var maxTokens: Int?
    public var requestTimeout: TimeInterval
    public var maxAttempts: Int
    public var retryInitialDelay: TimeInterval
    public var retryMaximumDelay: TimeInterval
    public var developerPrompt: String
    public var costRates: UsageCostRates

    public init(
        endpoint: URL = MuseSparkModelClient.chatCompletionsURL,
        modelID: String = MuseSparkModelClient.modelID,
        reasoningEffort: String = MuseSparkConfiguration.defaultReasoningEffort,
        maxTokens: Int? = MuseSparkModelClient.minimumMaxTokens,
        requestTimeout: TimeInterval = 60,
        maxAttempts: Int = 3,
        retryInitialDelay: TimeInterval = 0.5,
        retryMaximumDelay: TimeInterval = 8,
        developerPrompt: String = DeveloperPrompt.text,
        costRates: UsageCostRates = .museSparkStandard
    ) {
        self.endpoint = endpoint
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.maxTokens = maxTokens
        self.requestTimeout = requestTimeout
        self.maxAttempts = max(1, maxAttempts)
        self.retryInitialDelay = retryInitialDelay
        self.retryMaximumDelay = max(retryInitialDelay, retryMaximumDelay)
        self.developerPrompt = developerPrompt
        self.costRates = costRates
    }

    public func validate() throws {
        let effort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if effort.compare("none", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || !Self.allowedReasoningEfforts.contains(effort) {
            throw ModelClientError.invalidConfiguration(
                "reasoning_effort \"\(effort)\" is not sent. Muse Spark returns HTTP 400 for \"none\". Use one of: \(Self.allowedReasoningEfforts.joined(separator: ", "))."
            )
        }
        if let maxTokens, maxTokens < MuseSparkModelClient.minimumMaxTokens {
            throw ModelClientError.invalidConfiguration(
                "max_tokens is \(maxTokens). Reasoning tokens count toward that cap, so set it to at least \(MuseSparkModelClient.minimumMaxTokens) or leave it unset."
            )
        }
        if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ModelClientError.invalidConfiguration("The model id is empty.")
        }
        _ = try postURL()
    }

    /// Full `.../chat/completions` URL. A base URL gets that path appended.
    public func postURL() throws -> URL {
        guard let scheme = endpoint.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ModelClientError.invalidConfiguration("The chat completions URL needs an https scheme.")
        }
        if scheme == "http" {
            let host = endpoint.host?.lowercased() ?? ""
            let local = host == "localhost" || host == "127.0.0.1"
            if !local {
                throw ModelClientError.invalidConfiguration("The chat completions URL must be https.")
            }
        }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ModelClientError.invalidConfiguration("The chat completions URL could not be read.")
        }
        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.hasSuffix("/chat/completions") {
            path += "/chat/completions"
        }
        components.path = path
        guard let url = components.url else {
            throw ModelClientError.invalidConfiguration("The chat completions URL could not be read.")
        }
        return url
    }

    public static func endpoint(parsing string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw ModelClientError.invalidConfiguration("Could not read a base URL from \(trimmed).")
        }
        return url
    }
}
