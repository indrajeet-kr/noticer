import Foundation
import NoticerCore
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
}
