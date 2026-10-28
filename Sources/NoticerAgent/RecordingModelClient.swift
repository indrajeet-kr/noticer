import Foundation
import NoticerCore
import Synchronization

public protocol DetailedModelClient: ModelClient {
    func completeDetailed(_ request: ModelRequest) async throws -> DetailedModelCompletion
}

/// Writes each turn to `directory` as a `RecordedModelFixture`.
///
/// The file name is the request fingerprint, so the same request overwrites one fixture.
/// JPEG bytes are not written. Pass `redactions` (the API key) so a leaked secret is stripped.
public final class RecordingModelClient: ModelClient, Sendable {
    private let upstream: any DetailedModelClient
    private let directory: URL
    private let redactions: [String]
    private let gate = Mutex<Int>(0)

    public init(upstream: any DetailedModelClient, directory: URL, redactions: [String] = []) {
        self.upstream = upstream
        self.directory = directory
        self.redactions = redactions
    }

    public func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        let detailed = try await upstream.completeDetailed(request)
        do {
            try write(request: request, detailed: detailed)
        } catch let error as ModelClientError {
            throw error
        } catch {
            throw ModelClientError.recordingFailed(String(describing: error))
        }
        return detailed.verdict
    }

    private func write(request: ModelRequest, detailed: DetailedModelCompletion) throws {
        let recordedRequest = RecordedModelRequest(modelRequest: request)
        let fixtureID = ModelRequestFingerprint.fileID(for: request)
        let tool: ToolName? = detailed.verdict.finishReason == .stop ? nil : detailed.verdict.tool
        let fixture = RecordedModelFixture(
            fixtureID: fixtureID,
            normalized: RecordedModelFixture.NormalizedModelTurn(
                finishReason: detailed.verdict.finishReason,
                tool: tool,
                assessment: detailed.verdict.assessment,
                extensionReason: detailed.verdict.extensionReason
            ),
            rawCompletion: detailed.rawCompletion,
            request: recordedRequest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(fixture)
        if var text = String(data: data, encoding: .utf8) {
            text = SecretRedaction.redact(text, secrets: redactions)
            data = Data(text.utf8)
        }
        let url = directory.appendingPathComponent(fixtureID + ".json")
        try gate.withLock { _ in
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
}
