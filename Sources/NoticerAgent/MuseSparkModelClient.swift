import Foundation
import NoticerCore
import Synchronization

public enum ModelBackend: String, Codable, Sendable, Equatable {
    case museSpark = "muse_spark"
    case baseten = "baseten"
}

/// Identifiers for the Baseten fallback. There is no client for it.
public enum BasetenSparkOpen {
    public static let inferenceRoot = staticURL("https://inference.baseten.co/v1")
    public static let modelID = "meta-models/muse-spark-open-1026"
}

/// Live Muse Spark chat-completions client.
///
/// `init(apiKey:)` with no transport still throws `notImplemented` after it sees a key.
/// `live(apiKey:)` and `fromEnvironment()` install a transport and perform the call.
/// The API key is taken from the initializer or `META_API_KEY` and is not logged.
/// Baseten throws `backendOutOfScope` before a request is built.
public struct MuseSparkModelClient: DetailedModelClient, Sendable {
    public static let chatCompletionsURL = staticURL("https://api.meta.ai/v1/chat/completions")
    public static let modelID = "muse-spark-1.3"
    public static let apiKeyEnvironmentVariable = "META_API_KEY"
    public static let instructionRole = "developer"
    public static let toolChoice = "auto"
    /// `required` is rejected by the API. Do not send it.
    public static let parallelToolCalls = false
    /// `none` returns HTTP 400. Gate G0 still has to pick one of these.
    public static let reasoningEffortCandidates = ["minimal", "low"]
    /// If `max_tokens` is set, use at least this. Leaving it unset is also allowed.
    public static let minimumMaxTokens = 1024

    public static func encodedRequestByteCount(
        _ request: ModelRequest,
        configuration: MuseSparkConfiguration = MuseSparkConfiguration()
    ) -> Int {
        if let body = try? ChatCompletionRequest.body(request: request, configuration: configuration) {
            return body.count
        }
        return request.keyframes.reduce(0) { $0 + $1.jpegData.count }
    }

    public static func estimatedRequestBytes(_ request: ModelRequest) -> Int {
        let keyframesBytes = request.keyframes.reduce(0) { $0 + $1.jpegData.count }
        let textBytes = ChatCompletionRequest.sceneText(request).utf8.count
        return keyframesBytes + textBytes
    }

    public var backend: ModelBackend
    public let configuration: MuseSparkConfiguration
    private let apiKey: String?
    private let transport: (any HTTPTransport)?
    private let sleeper: any RetrySleeper
    private let jitter: any JitterSource
    private let callBudget: SessionCallBudget?
    private let completionLog = CompletionLog()
    /// Tagged developer-log lines (`MODEL`, ...). Nil keeps the client silent.
    private let log: (@Sendable (String, String) -> Void)?

    /// `apiKey` nil means the key is absent. This initializer does not read the environment.
    /// `transport` nil keeps the Step 0 stub. Use `fromEnvironment()` or `live(apiKey:)` for HTTP.
    public init(
        backend: ModelBackend = .museSpark,
        apiKey: String? = nil,
        configuration: MuseSparkConfiguration = MuseSparkConfiguration(),
        transport: (any HTTPTransport)? = nil,
        sleeper: any RetrySleeper = TaskRetrySleeper(),
        jitter: any JitterSource = SystemJitter(),
        callBudget: SessionCallBudget? = nil,
        log: (@Sendable (String, String) -> Void)? = nil
    ) {
        self.backend = backend
        self.apiKey = apiKey
        self.configuration = configuration
        self.transport = transport
        self.sleeper = sleeper
        self.jitter = jitter
        self.callBudget = callBudget
        self.log = log
    }

    public static func fromEnvironment(
        backend: ModelBackend = .museSpark,
        configuration: MuseSparkConfiguration = MuseSparkConfiguration()
    ) -> MuseSparkModelClient {
        MuseSparkModelClient(
            backend: backend,
            apiKey: ProcessInfo.processInfo.environment[apiKeyEnvironmentVariable],
            configuration: configuration,
            transport: URLSessionHTTPTransport(timeout: configuration.requestTimeout),
            callBudget: backend == .museSpark ? SessionCallBudget() : nil
        )
    }

    public static func live(
        apiKey: String,
        configuration: MuseSparkConfiguration = MuseSparkConfiguration(),
        transport: (any HTTPTransport)? = nil,
        sleeper: any RetrySleeper = TaskRetrySleeper(),
        jitter: any JitterSource = SystemJitter(),
        callBudget: SessionCallBudget? = SessionCallBudget(),
        log: (@Sendable (String, String) -> Void)? = nil
    ) -> MuseSparkModelClient {
        MuseSparkModelClient(
            backend: .museSpark,
            apiKey: apiKey,
            configuration: configuration,
            transport: transport ?? URLSessionHTTPTransport(timeout: configuration.requestTimeout),
            sleeper: sleeper,
            jitter: jitter,
            callBudget: callBudget,
            log: log
        )
    }

    /// True when a transport is installed. The Step 0 initializer leaves this false.
    public var isLive: Bool {
        transport != nil
    }

    public func lastCompletion() -> DetailedModelCompletion? {
        completionLog.last()
    }

    public func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        try await completeDetailed(request).verdict
    }

    public func completeDetailed(_ request: ModelRequest) async throws -> DetailedModelCompletion {
        switch backend {
        case .baseten:
            throw ModelClientError.backendOutOfScope(.baseten)
        case .museSpark:
            guard let apiKey, !apiKey.isEmpty else {
                throw ModelClientError.missingAPIKey(environmentVariable: Self.apiKeyEnvironmentVariable)
            }
            guard let transport else {
                _ = (request, apiKey)
                throw ModelClientError.notImplemented
            }
            try configuration.validate()
            let url = try configuration.postURL()
            let body = try ChatCompletionRequest.body(request: request, configuration: configuration)
            try callBudget?.reserve()
            let response = try await perform(url: url, body: body, apiKey: apiKey, transport: transport)
            let knownIDs = Set(request.keyframes.map(\.id))
            let detailed = try ChatCompletionResponse.parse(
                data: response.body,
                rates: configuration.costRates,
                knownKeyframeIDs: knownIDs,
                onUnknownEvidenceID: { [log] id, needID in
                    log?("MODEL", "evidence-id-unknown id=\(id) need=\(needID ?? "—")")
                }
            )
            completionLog.store(detailed)
            return detailed
        }
    }

    private func perform(
        url: URL,
        body: Data,
        apiKey: String,
        transport: any HTTPTransport
    ) async throws -> HTTPResponse {
        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: body
        )
        var transportFailure: String?
        for attempt in 0..<configuration.maxAttempts {
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let redacted = SecretRedaction.clip(
                    SecretRedaction.redact(String(describing: error), secrets: [apiKey])
                )
                transportFailure = redacted
                let canRetry = ChatCompletionRetry.isTransientTransport(error)
                    && attempt + 1 < configuration.maxAttempts
                if canRetry {
                    try await sleeper.sleep(seconds: ChatCompletionRetry.delay(
                        attempt: attempt,
                        initial: configuration.retryInitialDelay,
                        maximum: configuration.retryMaximumDelay,
                        jitter: jitter.seconds(),
                        retryAfter: nil
                    ))
                    continue
                }
                throw ModelClientError.serviceUnavailable(status: 0, message: redacted)
            }

            if (200..<300).contains(response.statusCode) {
                return response
            }
            let canRetry = ChatCompletionRetry.shouldRetry(status: response.statusCode)
                && attempt + 1 < configuration.maxAttempts
            if canRetry {
                try await sleeper.sleep(seconds: ChatCompletionRetry.delay(
                    attempt: attempt,
                    initial: configuration.retryInitialDelay,
                    maximum: configuration.retryMaximumDelay,
                    jitter: jitter.seconds(),
                    retryAfter: ChatCompletionRetry.retryAfterSeconds(headers: response.headers)
                ))
                continue
            }
            throw httpError(response, apiKey: apiKey)
        }
        throw ModelClientError.serviceUnavailable(
            status: 0,
            message: transportFailure ?? "The model request failed."
        )
    }

    private func httpError(_ response: HTTPResponse, apiKey: String) -> ModelClientError {
        let parsed = APIErrorParser.parse(response.body)
        let message = SecretRedaction.redact(parsed.message, secrets: [apiKey])
        if parsed.code == "model_not_found" || response.statusCode == 404 {
            let text = message.isEmpty ? "The model was not found." : message
            return .modelNotFound(message: text)
        }
        if response.statusCode == 429 {
            return .rateLimited(message: message)
        }
        if (500...599).contains(response.statusCode) {
            return .serviceUnavailable(status: response.statusCode, message: message)
        }
        let text = message.isEmpty ? "The model API rejected the request." : message
        return .requestRejected(status: response.statusCode, code: parsed.code, message: text)
    }
}

private final class CompletionLog: Sendable {
    private let stored = Mutex<DetailedModelCompletion?>(nil)

    func store(_ value: DetailedModelCompletion) {
        stored.withLock { $0 = value }
    }

    func last() -> DetailedModelCompletion? {
        stored.withLock { $0 }
    }
}

private func staticURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
        preconditionFailure("Bad static URL \(string)")
    }
    return url
}
