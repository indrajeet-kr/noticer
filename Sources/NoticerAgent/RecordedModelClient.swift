import Foundation
import NoticerCore
import Synchronization

public enum ModelClientError: Error, Equatable, Sendable {
    case missingAPIKey(environmentVariable: String)
    case notImplemented
    /// Baseten is a named slot only. No request is built or sent.
    case backendOutOfScope(ModelBackend)
    case recordingExhausted
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
