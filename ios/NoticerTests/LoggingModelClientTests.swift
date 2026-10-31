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
