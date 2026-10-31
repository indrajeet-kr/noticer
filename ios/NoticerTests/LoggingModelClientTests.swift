import Foundation
import NoticerCore
import Synchronization
import XCTest

/// Verdict-line rendering: an omitted field must never read the same as a
/// literal "none"/"null" string the model sent.
final class LoggingModelClientTests: XCTestCase {
    func testOmittedNeedReadsAsDash() {
        let line = LoggingModelClient.describeVerdict(ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNoTransition,
            assessment: SceneAssessment()
        ))
        XCTAssertTrue(line.contains("need=—"), line)
        XCTAssertTrue(line.contains("action=—"), line)
        XCTAssertFalse(line.contains("none"), line)
    }

    func testLiteralNoneStringStaysVisible() {
        let line = LoggingModelClient.describeVerdict(ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNoTransition,
            assessment: SceneAssessment(needID: "none", actionCode: "null")
        ))
        XCTAssertTrue(line.contains("need=none"), line)
        XCTAssertTrue(line.contains("action=null"), line)
    }

    func testDescribeRequestIncludesPurposeAndBytes() {
        let now = Date()
        let request = ModelRequest(
            keyframes: [
                Keyframe(id: "kf-1", capturedAt: now.addingTimeInterval(-2), ageSeconds: 2, episodeID: "ep-1", jpegData: Data(repeating: 0xAA, count: 2048)),
                Keyframe(id: "kf-2", capturedAt: now, ageSeconds: 0, episodeID: "ep-1", jpegData: Data(repeating: 0xBB, count: 2048)),
            ],
            needs: [Need(id: "take-baby", authorText: "take baby", cueWording: "take baby", priority: 0)],
            purpose: .heartbeat
        )
        let line = LoggingModelClient.describeRequest(request)
        XCTAssertTrue(line.contains("purpose=heartbeat"), line)
        XCTAssertTrue(line.contains("bytes=4096"), line)
    }

    func testPayloadTuningDefaults() {
        XCTAssertEqual(LatencyTuning.default.uploadMaxEdge, 448)
        XCTAssertEqual(LatencyTuning.default.jpegQuality, 0.55, accuracy: 0.001)
    }

    func testCancelLogsCancelledNotError() async {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            let recorded = Mutex<[String]>([])
            let client = LoggingModelClient(
                inner: CancelStub(error: error),
                log: { tag, message in
                    recorded.withLock { $0.append("[\(tag)] \(message)") }
                }
            )
            do {
                _ = try await client.complete(ModelRequest(keyframes: [], needs: []))
                XCTFail("expected the cancel to pass through")
            } catch {
                let isCancel = error is CancellationError || (error as? URLError)?.code == .cancelled
                XCTAssertTrue(isCancel, "wrong error: \(error)")
                let lines = recorded.withLock { $0 }
                XCTAssertEqual(lines.count, 2)
                XCTAssertTrue(lines[1].contains("cancelled"), lines[1])
                XCTAssertFalse(lines[1].contains("error:"), lines[1])
            }
        }
    }
}

private struct CancelStub: ModelClient, @unchecked Sendable {
    var error: Error

    func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        throw error
    }
}
