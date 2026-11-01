import Foundation
import XCTest
@testable import NoticerAgent
import NoticerCore

/// The hard-cap gate mirrors the engine's urgent single-frame rule:
/// same accept, same rejections, same order.
final class UrgentEvidenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func strip(newestAge: TimeInterval) -> [Keyframe] {
        [
            Keyframe(
                id: "kf-old",
                capturedAt: now.addingTimeInterval(-9),
                ageSeconds: 9,
                episodeID: "ep",
                jpegData: Data([1])
            ),
            Keyframe(
                id: "kf-new",
                capturedAt: now.addingTimeInterval(-newestAge),
                ageSeconds: 0,
                episodeID: "ep",
                jpegData: Data([2])
            ),
        ]
    }

    private func verdict(
        sustained: Bool? = false,
        evidence: [String]?,
        anchor: AnchorState?,
        confidence: Double?
    ) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: "eating-one-handed",
                sustainedAcrossStrip: sustained,
                partnerStateEvidence: ["eating_one_handed"],
                wearerHandsOccupied: false,
                confidence: confidence,
                evidenceKeyframeIDs: evidence,
                newestAnchorState: anchor
            )
        )
    }

    private func session(urgent: Bool = true, relatchNotBefore: [String: Date] = [:]) -> CapSession {
        CapSession(
            now: now,
            authoredNeedIDs: ["eating-one-handed"],
            urgentNeedIDs: urgent ? ["eating-one-handed"] : [],
            relatchNotBefore: relatchNotBefore
        )
    }

    private func decide(
        _ verdict: ModelVerdict,
        keyframes: [Keyframe],
        session: CapSession? = nil
    ) -> ToolHandlerResult {
        HardCapGate().decide(verdict: verdict, session: session ?? self.session(), keyframes: keyframes)
    }

    private func rejection(_ result: ToolHandlerResult) throws -> ToolRejection {
        guard case .rejected(let rejection) = result.outcome else {
            throw XCTSkip("expected a rejection")
        }
        return rejection
    }

    func testFreshCitedNewestFrameAccepts() {
        let result = decide(
            verdict(evidence: ["kf-new"], anchor: .unmet, confidence: 0.85),
            keyframes: strip(newestAge: 0)
        )
        XCTAssertEqual(result.outcome, .accepted(.latch(needID: "eating-one-handed")))
    }

    func testEmptyEvidenceRejects() throws {
        let result = decide(
            verdict(evidence: [], anchor: .unmet, confidence: 0.95),
            keyframes: strip(newestAge: 0)
        )
        XCTAssertEqual(try rejection(result).code, ToolRejectionCode.urgentNoFreshEvidence)
    }

    func testStaleNewestFrameRejects() throws {
        let result = decide(
            verdict(evidence: ["kf-new"], anchor: .unmet, confidence: 0.9),
            keyframes: strip(newestAge: EngineTuning.urgentFreshFrameMaxAgeSeconds + 0.5)
        )
        XCTAssertEqual(try rejection(result).code, ToolRejectionCode.urgentNoFreshEvidence)
    }

    func testNotVisibleAnchorRejects() throws {
        let result = decide(
            verdict(evidence: ["kf-new"], anchor: .notVisible, confidence: 0.9),
            keyframes: strip(newestAge: 0)
        )
        XCTAssertEqual(try rejection(result).code, ToolRejectionCode.urgentNoFreshEvidence)
    }

    func testCooldownRejectsWithCooldown() throws {
        let session = session(relatchNotBefore: ["eating-one-handed": now.addingTimeInterval(30)])
        let result = decide(
            verdict(evidence: ["kf-new"], anchor: .unmet, confidence: 0.9),
            keyframes: strip(newestAge: 0),
            session: session
        )
        XCTAssertEqual(try rejection(result).code, ToolRejectionCode.relatchCooldown)
    }

    func testNonUrgentRejectsNotSustained() throws {
        let result = decide(
            verdict(evidence: ["kf-new"], anchor: .unmet, confidence: 0.85),
            keyframes: strip(newestAge: 0),
            session: session(urgent: false)
        )
        XCTAssertEqual(try rejection(result).code, ToolRejectionCode.notSustained)
    }
}
