import Foundation
import NoticerCore

public enum ModelBackend: String, Codable, Sendable, Equatable {
    case museSpark = "muse_spark"
    case baseten = "baseten"
}

/// Identifiers for the Baseten fallback. There is no client for it in Step 0.
public enum BasetenSparkOpen {
    public static let inferenceRoot = staticURL("https://inference.baseten.co/v1")
    public static let modelID = "meta-models/muse-spark-open-1026"
}

/// Live Muse Spark client stub.
///
/// Holds the endpoint and the call shape the agent track will send.
/// `complete` does not open a connection. The API key is taken from the
/// initializer and is never logged or written down by this type.
public struct MuseSparkModelClient: ModelClient, Sendable {
    public static let chatCompletionsURL = staticURL("https://api.meta.ai/v1/chat/completions")
    public static let modelID = "muse-spark-1.3"
    public static let apiKeyEnvironmentVariable = "META_API_KEY"
    public static let toolChoice = "auto"
    /// `required` is rejected by the API. Do not send it.
    public static let parallelToolCalls = false
    /// `none` returns HTTP 400. Gate G0 still has to pick one of these.
    public static let reasoningEffortCandidates = ["minimal", "low"]
    /// If `max_tokens` is set, use at least this. Leaving it unset is also allowed.
    public static let minimumMaxTokens = 1024

    public var backend: ModelBackend
    private let apiKey: String?

    /// `apiKey` nil means the key is absent. This initializer does not read the environment.
    /// Use `fromEnvironment()` when the process is allowed to.
    public init(backend: ModelBackend = .museSpark, apiKey: String? = nil) {
        self.backend = backend
        self.apiKey = apiKey
    }

    public static func fromEnvironment(backend: ModelBackend = .museSpark) -> MuseSparkModelClient {
        MuseSparkModelClient(
            backend: backend,
            apiKey: ProcessInfo.processInfo.environment[apiKeyEnvironmentVariable]
        )
    }

    public func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        switch backend {
        case .baseten:
            throw ModelClientError.backendOutOfScope(.baseten)
        case .museSpark:
            guard let apiKey, !apiKey.isEmpty else {
                throw ModelClientError.missingAPIKey(environmentVariable: Self.apiKeyEnvironmentVariable)
            }
            // The key is checked and then dropped. The HTTP call is agent-track work.
            _ = (request, apiKey)
            throw ModelClientError.notImplemented
        }
    }
}

private func staticURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
        preconditionFailure("Bad static URL \(string)")
    }
    return url
}
