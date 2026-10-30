import Foundation
import NoticerCore
import XCTest
@testable import NoticerAgent

final class QuickTimingGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testQuickCueRateLimitIsThirtySeconds() {
        XCTAssertTrue(HardCapGate.isCueRateLimited(
            lastCueAt: now.addingTimeInterval(-29),
            now: now,
            timing: .quick
        ))
        XCTAssertFalse(HardCapGate.isCueRateLimited(
            lastCueAt: now.addingTimeInterval(-30),
            now: now,
            timing: .quick
        ))
        XCTAssertTrue(HardCapGate.isCueRateLimited(
            lastCueAt: now.addingTimeInterval(-179),
            now: now
        ))
    }

    func testQuickHeadStartCapIsFortySeconds() {
        let start = now
        let window = HeadStartWindow(startedAt: start, endsAt: start.addingTimeInterval(20))
        let session = authoredSession(
            now: start.addingTimeInterval(20),
            open: ["eating-one-handed"],
            headStarts: ["eating-one-handed": window]
        )
        let verdict = ModelVerdict(
            finishReason: .toolCalls,
            tool: .deferCueWearerBusy,
            assessment: SceneAssessment(needID: "eating-one-handed", wearerHandsOccupied: true)
        )
        let held = HardCapGate(timing: .quick).decide(verdict: verdict, session: session)
        guard case .accepted(.deferCue(_, let hardCapAt)) = held.outcome else {
            return XCTFail("expected a defer, got \(held.outcome)")
        }
        XCTAssertEqual(hardCapAt, start.addingTimeInterval(40))

        var atCap = session
        atCap.now = hardCapAt
        guard case .rejected(let rejection) = HardCapGate(timing: .quick).decide(verdict: verdict, session: atCap).outcome else {
            return XCTFail("expected the cap to fire the cue")
        }
        XCTAssertEqual(rejection.code, ToolRejectionCode.hardCapFiresCue)
    }

    func testQuickLatchAcceptsKeyframesTwoSecondsApart() {
        let frames = [
            Keyframe(id: "a", capturedAt: now, ageSeconds: 2, episodeID: "e", jpegData: Data([1])),
            Keyframe(id: "b", capturedAt: now, ageSeconds: 0, episodeID: "e", jpegData: Data([2])),
        ]
        let result = HardCapGate(timing: .quick).decide(
            verdict: latchVerdict(),
            session: authoredSession(now: now),
            keyframes: frames
        )
        guard case .accepted(.latch(let needID)) = result.outcome else {
            return XCTFail("expected a latch, got \(result.outcome)")
        }
        XCTAssertEqual(needID, "eating-one-handed")
    }
}
