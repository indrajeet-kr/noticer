import Foundation
import NoticerCore
import Synchronization

public enum ModelClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingAPIKey(environmentVariable: String)
    case notImplemented
    /// Baseten is a named slot only. No request is built or sent.
    case backendOutOfScope(ModelBackend)
    case recordingExhausted
    case invalidConfiguration(String)
    case modelNotFound(message: String)
    case requestRejected(status: Int, code: String?, message: String)
    case serviceUnavailable(status: Int, message: String)
    case rateLimited(message: String)
    /// `finish_reason` was `length`. `usage` is present when the body still carried one.
    case responseTruncated(message: String, usage: ModelUsage?)
    case malformedResponse(String)
    /// `parallel_tool_calls` is false. More than one call has no contract.
    case multipleToolCalls(count: Int)
    case callBudgetExhausted(limit: Int)
    case replayMiss(message: String)
    case ambiguousReplay(fingerprint: String)
    case recordingFailed(String)

    public var description: String {
        switch self {
        case .missingAPIKey(let name):
            return "Missing API key. Set \(name). It is never written to the repo."
        case .notImplemented:
            return "notImplemented"
        case .backendOutOfScope(let backend):
            return "Backend \(backend.rawValue) is out of scope. No request was sent."
        case .recordingExhausted:
            return "The recorded tape has no more responses."
        case .invalidConfiguration(let message):
            return message
        case .modelNotFound(let message):
            return "model_not_found: \(message)"
        case .requestRejected(let status, let code, let message):
            let suffix = code.map { " (\($0))" } ?? ""
            return "HTTP \(status)\(suffix): \(message)"
        case .serviceUnavailable(let status, let message):
            return "HTTP \(status): \(message)"
        case .rateLimited(let message):
            return "HTTP 429: \(message)"
        case .responseTruncated(let message, _):
            return message
        case .malformedResponse(let message):
            return message
        case .multipleToolCalls(let count):
            return "The model returned \(count) tool calls. parallel_tool_calls is false, so this turn has no contract."
        case .callBudgetExhausted(let limit):
            return "The session call budget of \(limit) is used up. No further model request is sent."
        case .replayMiss(let message):
            return message
        case .ambiguousReplay:
            return "Two saved responses match the same request."
        case .recordingFailed(let message):
            return message
        }
    }
}

/// Plays verdicts in order and ignores the request contents.
/// Matching a request to a particular recording is later agent-track work.
public final class RecordedModelClient: ModelClient, Sendable {
    private let remaining: Mutex<[ModelVerdict]>

    public init(verdicts: [ModelVerdict]) {
        remaining = Mutex(verdicts)
    }

    public convenience init(fixtures: [RecordedModelFixture]) throws {
        self.init(verdicts: try fixtures.map { try $0.makeVerdict() })
    }

    public static func load(contentsOf urls: [URL]) throws -> RecordedModelClient {
        let decoder = JSONDecoder()
        var fixtures: [RecordedModelFixture] = []
        fixtures.reserveCapacity(urls.count)
        for url in urls {
            let data = try Data(contentsOf: url)
            fixtures.append(try decoder.decode(RecordedModelFixture.self, from: data))
        }
        return try RecordedModelClient(fixtures: fixtures)
    }

    public func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        try remaining.withLock { verdicts in
            guard !verdicts.isEmpty else {
                throw ModelClientError.recordingExhausted
            }
            return verdicts.removeFirst()
        }
    }
}
