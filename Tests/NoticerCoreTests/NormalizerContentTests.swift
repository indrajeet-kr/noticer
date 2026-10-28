import XCTest
@testable import NoticerCore

final class NormalizerContentTests: XCTestCase {
    private let liveProse = "Watching for one-handed eating — latching that need."

    func testToolCallsWinWhenContentIsAlsoPresent() throws {
        let verdict = try ModelTurnNormalizer.verdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: "eating-one-handed",
                sustainedAcrossStrip: true,
                partnerStateEvidence: ["eating_one_handed"]
            ),
            content: liveProse
        )
        XCTAssertEqual(verdict.finishReason, .toolCalls)
        XCTAssertEqual(verdict.tool, .latchNeedHypothesis)
        XCTAssertEqual(verdict.assessment.needID, "eating-one-handed")
        XCTAssertEqual(verdict.assessment.sustainedAcrossStrip, true)
    }

    func testStopStillIgnoresProseWhenContentIsPresent() throws {
        let verdict = try ModelTurnNormalizer.verdict(
            finishReason: .stop,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(needID: "take-baby"),
            content: liveProse
        )
        XCTAssertEqual(verdict.finishReason, .stop)
        XCTAssertEqual(verdict.tool, .reportNoTransition)
        XCTAssertNil(verdict.extensionReason)
    }

    func testToolCallsWithoutAToolStillFailWhenContentIsPresent() {
        XCTAssertThrowsError(
            try ModelTurnNormalizer.verdict(
                finishReason: .toolCalls,
                tool: nil,
                content: liveProse
            )
        ) { error in
            XCTAssertEqual(error as? ModelContractError, .toolCallsMissingTool)
        }
    }
}
