import Foundation
import NoticerCore
import XCTest
@testable import NoticerAgent

final class ReplayRecordingTests: XCTestCase {
    func testRecordingOmitsImageBytesAndReplayIsStable() async throws {
        let secret = "super-secret-test-key"
        let jpeg = Data("JPEG-BYTES-NOT-ON-DISK".utf8)
        let request = sampleRequest(jpeg: jpeg)
        let first = DetailedModelCompletion(
            verdict: latchVerdict(),
            usage: nil,
            rawCompletion: .object(["note": .string("kept \(secret)")])
        )
        let second = DetailedModelCompletion(
            verdict: ModelVerdict(
                finishReason: .stop,
                tool: .reportNoTransition,
                assessment: SceneAssessment()
            ),
            usage: nil,
            rawCompletion: .object(["note": .string("second")])
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noticer-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = RecordingModelClient(
            upstream: FixedDetailedClient(completions: [first, second]),
            directory: directory,
            redactions: [secret]
        )
        let recordedFirst = try await recorder.complete(request)
        XCTAssertEqual(recordedFirst.tool, .latchNeedHypothesis)
        let recordedSecond = try await recorder.complete(request)
        XCTAssertEqual(recordedSecond.tool, .reportNoTransition)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertFalse(text.contains("JPEG-BYTES-NOT-ON-DISK"))
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("bearer "))
        XCTAssertTrue(text.contains("\"request\""))
        XCTAssertTrue(text.contains("eating-one-handed"))

        let replay = try ReplayModelClient.load(directory: directory)
        let again = try await replay.complete(request)
        let third = try await replay.complete(request)
        XCTAssertEqual(again, third)
        XCTAssertEqual(again.tool, .reportNoTransition)
        XCTAssertEqual(again.finishReason, .stop)

        var other = request
        other.needs[0].id = "water"
        do {
            _ = try await replay.complete(other)
            XCTFail("expected a replay miss")
        } catch ModelClientError.replayMiss {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testDuplicateFingerprintsAreRefused() throws {
        let request = RecordedModelRequest(modelRequest: sampleRequest())
        let fixture = RecordedModelFixture(
            fixtureID: "one",
            normalized: RecordedModelFixture.NormalizedModelTurn(
                finishReason: .stop,
                tool: nil,
                assessment: SceneAssessment()
            ),
            request: request
        )
        var copy = fixture
        copy.fixtureID = "two"
        XCTAssertThrowsError(try ReplayModelClient(fixtures: [fixture, copy])) { error in
            guard case ModelClientError.ambiguousReplay = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testSameRequestFingerprintIgnoresCaptureTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let left = ModelRequest(
            keyframes: [Keyframe(id: "k", capturedAt: now, ageSeconds: 4, episodeID: "e", jpegData: Data([1, 2]))],
            needs: [Need(id: "water", authorText: "water", cueWording: "refill", priority: 1)]
        )
        var right = left
        right.keyframes[0].capturedAt = now.addingTimeInterval(30)
        XCTAssertEqual(ModelRequestFingerprint.make(left), ModelRequestFingerprint.make(right))
        right.keyframes[0].jpegData = Data([1, 3])
        XCTAssertNotEqual(ModelRequestFingerprint.make(left), ModelRequestFingerprint.make(right))
    }
}
