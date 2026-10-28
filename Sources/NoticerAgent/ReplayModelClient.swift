import Foundation
import NoticerCore

/// Serves saved fixtures by request fingerprint.
///
/// The same request always returns the same verdict, including on a second call.
/// No API key is read and nothing is sent on the network.
/// Fixtures without a `request` fingerprint are refused; ordered tapes stay on `RecordedModelClient`.
public final class ReplayModelClient: ModelClient, Sendable {
    private let byFingerprint: [String: ModelVerdict]

    public init(fixtures: [RecordedModelFixture]) throws {
        var index: [String: ModelVerdict] = [:]
        for fixture in fixtures {
            guard let request = fixture.request else {
                throw ModelClientError.replayMiss(
                    message: "Fixture \(fixture.fixtureID) has no request fingerprint. Ordered tapes stay on RecordedModelClient."
                )
            }
            if index[request.fingerprint] != nil {
                throw ModelClientError.ambiguousReplay(fingerprint: request.fingerprint)
            }
            index[request.fingerprint] = try fixture.makeVerdict()
        }
        byFingerprint = index
    }

    public static func load(directory: URL) throws -> ReplayModelClient {
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        var fixtures: [RecordedModelFixture] = []
        fixtures.reserveCapacity(urls.count)
        for url in urls {
            let data = try Data(contentsOf: url)
            fixtures.append(try decoder.decode(RecordedModelFixture.self, from: data))
        }
        return try ReplayModelClient(fixtures: fixtures)
    }

    public func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        let fingerprint = ModelRequestFingerprint.make(request)
        guard let verdict = byFingerprint[fingerprint] else {
            throw ModelClientError.replayMiss(
                message: "No saved response matches this request. Replay does not call the network."
            )
        }
        return verdict
    }
}
