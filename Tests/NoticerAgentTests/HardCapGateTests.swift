import Foundation
import NoticerCore
import XCTest
@testable import NoticerAgent

final class HardCapGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testLatchAcceptsAListedSustainedStripAndIgnoresConfidence() {
        let result = HardCapGate().decide(
            verdict: latchVerdict(confidence: 0.01),
            session: authoredSession(now: now),
            keyframes: spacedKeyframes()
        )
        guard case .accepted(.latch(let needID)) = result.outcome else {
            return XCTFail("expected a latch, got \(result.outcome)")
        }
        XCTAssertEqual(needID, "eating-one-handed")
    }

    func testLatchRejections() {
        let gate = HardCapGate()
        let frames = spacedKeyframes()

        XCTAssertEqual(
            code(gate.decide(verdict: latchVerdict(needID: "missing"), session: authoredSession(now: now), keyframes: frames)),
            ToolRejectionCode.notOnList
        )
        XCTAssertEqual(
            code(gate.decide(verdict: latchVerdict(sustained: false), session: authoredSession(now: now), keyframes: frames)),
            ToolRejectionCode.notSustained
        )
        XCTAssertEqual(
            code(gate.decide(verdict: latchVerdict(), session: authoredSession(now: now), keyframes: [frames[0]])),
            ToolRejectionCode.keyframeCount
        )
        let close = [
            Keyframe(id: "a", capturedAt: now, ageSeconds: 3, episodeID: "e", jpegData: Data([1])),
            Keyframe(id: "b", capturedAt: now, ageSeconds: 0, episodeID: "e", jpegData: Data([2])),
        ]
        XCTAssertEqual(
            code(gate.decide(verdict: latchVerdict(), session: authoredSession(now: now), keyframes: close)),
            ToolRejectionCode.keyframeSpacing
        )
        XCTAssertEqual(
            code(gate.decide(
                verdict: latchVerdict(),
                session: authoredSession(now: now, open: ["eating-one-handed"]),
                keyframes: frames
            )),
            ToolRejectionCode.alreadyOpen
        )
        XCTAssertEqual(
            code(gate.decide(
                verdict: latchVerdict(),
                session: authoredSession(now: now, open: ["water", "other"]),
                keyframes: frames
            )),
            ToolRejectionCode.maxOpenNeeds
        )
        XCTAssertEqual(
            code(gate.decide(
                verdict: latchVerdict(),
                session: authoredSession(now: now, lastLatchAt: now.addingTimeInterval(-5)),
                keyframes: frames
            )),
            ToolRejectionCode.latchInterval
        )
        XCTAssertEqual(
            code(gate.decide(
                verdict: latchVerdict(),
                session: authoredSession(
                    now: now,
                    relatchNotBefore: ["eating-one-handed": now.addingTimeInterval(10)]
                ),
                keyframes: frames
            )),
            ToolRejectionCode.relatchCooldown
        )
        XCTAssertEqual(
            code(gate.decide(
                verdict: latchVerdict(),
                session: authoredSession(now: now, calls: SessionLimits.maxModelCallsPerSession),
                keyframes: frames
            )),
            ToolRejectionCode.callBudget
        )
    }

    func testResolvedByPartnerRidesOnLatchAndOnNoTransition() {
        let latch = HardCapGate().decide(
            verdict: latchVerdict(resolution: .resolvedByPartner, actionCode: ActionCodeExamples.waterGlassPresent),
            session: authoredSession(now: now),
            keyframes: spacedKeyframes()
        )
        guard case .accepted(.latch) = latch.outcome else {
            return XCTFail("expected the latch to stand, got \(latch.outcome)")
        }
        XCTAssertEqual(latch.verdict.assessment.resolution, .resolvedByPartner)
        XCTAssertEqual(latch.verdict.assessment.actionCode, ActionCodeExamples.waterGlassPresent)

        let quiet = ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNoTransition,
            assessment: SceneAssessment(needID: "water", resolution: .resolvedByPartner)
        )
        let result = HardCapGate().decide(verdict: quiet, session: authoredSession(now: now))
        guard case .accepted(.noTransition) = result.outcome else {
            return XCTFail("expected a no-op")
        }
        XCTAssertEqual(result.verdict.assessment.resolution, .resolvedByPartner)
    }

    func testDeferHoldsUntilTheHardCapThenTheCueFires() {
        let start = now
        let window = HeadStartWindow(startedAt: start, endsAt: start.addingTimeInterval(90))
        let session = authoredSession(
            now: start.addingTimeInterval(90),
            open: ["eating-one-handed"],
            headStarts: ["eating-one-handed": window]
        )
        let verdict = ModelVerdict(
            finishReason: .toolCalls,
            tool: .deferCueWearerBusy,
            assessment: SceneAssessment(needID: "eating-one-handed", wearerHandsOccupied: true)
        )
        let held = HardCapGate().decide(verdict: verdict, session: session)
        guard case .accepted(.deferCue(let needID, let hardCapAt)) = held.outcome else {
            return XCTFail("expected a defer, got \(held.outcome)")
        }
        XCTAssertEqual(needID, "eating-one-handed")
        XCTAssertEqual(hardCapAt, start.addingTimeInterval(SessionLimits.headStartCapSeconds))

        var atCap = session
        atCap.now = hardCapAt
        XCTAssertEqual(
            code(HardCapGate().decide(verdict: verdict, session: atCap)),
            ToolRejectionCode.hardCapFiresCue
        )

        let freeHands = ModelVerdict(
            finishReason: .toolCalls,
            tool: .deferCueWearerBusy,
            assessment: SceneAssessment(needID: "eating-one-handed", wearerHandsOccupied: false)
        )
        XCTAssertEqual(
            code(HardCapGate().decide(verdict: freeHands, session: session)),
            ToolRejectionCode.handsNotOccupied
        )
    }

    func testWearerActionIsAnOpenPrefixAndThePassiveExampleIsRejected() {
        let gate = HardCapGate()
        let session = authoredSession(now: now)
        let accepted = gate.decide(
            verdict: ModelVerdict(
                finishReason: .toolCalls,
                tool: .logWearerIntervention,
                assessment: SceneAssessment(
                    needID: "eating-one-handed",
                    resolution: .resolvedByPartner,
                    actionCode: "wearer_bringing_a_glass"
                )
            ),
            session: session
        )
        guard case .accepted(.wearerIntervention(let needID, let actionCode)) = accepted.outcome else {
            return XCTFail("expected the open wearer action, got \(accepted.outcome)")
        }
        XCTAssertEqual(needID, "eating-one-handed")
        XCTAssertEqual(actionCode, "wearer_bringing_a_glass")
        XCTAssertEqual(accepted.verdict.assessment.resolution, .resolvedByPartner)

        let known = gate.decide(
            verdict: ModelVerdict(
                finishReason: .toolCalls,
                tool: .logWearerIntervention,
                assessment: SceneAssessment(
                    needID: "water",
                    actionCode: ActionCodeExamples.wearerHandsReceivingBaby
                )
            ),
            session: session
        )
        guard case .accepted(.wearerIntervention(_, let knownCode)) = known.outcome else {
            return XCTFail("expected the named wearer action")
        }
        XCTAssertEqual(knownCode, ActionCodeExamples.wearerHandsReceivingBaby)

        let passive = gate.decide(
            verdict: ModelVerdict(
                finishReason: .toolCalls,
                tool: .logWearerIntervention,
                assessment: SceneAssessment(
                    needID: "water",
                    resolution: .resolvedByPartner,
                    actionCode: ActionCodeExamples.waterGlassPresent
                )
            ),
            session: session
        )
        XCTAssertEqual(code(passive), ToolRejectionCode.notWearerAction)
        XCTAssertEqual(passive.verdict.assessment.resolution, .resolvedByPartner)

        let unknown = gate.decide(
            verdict: ModelVerdict(
                finishReason: .toolCalls,
                tool: .logWearerIntervention,
                assessment: SceneAssessment(needID: "water", actionCode: "not_a_known_code")
            ),
            session: session
        )
        XCTAssertEqual(code(unknown), ToolRejectionCode.notWearerAction)
    }

    func testHeadStartExtensionClipsAtTheCapAndDoesNotInventAStep() {
        let start = now
        let window = HeadStartWindow(startedAt: start, endsAt: start.addingTimeInterval(110))
        let session = authoredSession(
            now: start.addingTimeInterval(20),
            open: ["eating-one-handed"],
            headStarts: ["eating-one-handed": window]
        )
        let verdict = ModelVerdict(
            finishReason: .toolCalls,
            tool: .requestHeadStartExtension,
            assessment: SceneAssessment(needID: "eating-one-handed"),
            extensionReason: "hot pan"
        )
        XCTAssertEqual(
            code(HardCapGate().decide(verdict: verdict, session: session)),
            ToolRejectionCode.extensionStepNotConfigured
        )

        let granted = HardCapGate(extensionStepSeconds: 15).decide(verdict: verdict, session: session)
        guard case .accepted(.headStartExtension(_, let seconds, let resulting)) = granted.outcome else {
            return XCTFail("expected a clipped grant, got \(granted.outcome)")
        }
        XCTAssertEqual(seconds, 10)
        XCTAssertEqual(resulting, 120)

        var full = session
        full.headStarts["eating-one-handed"] = HeadStartWindow(
            startedAt: start,
            endsAt: start.addingTimeInterval(SessionLimits.headStartCapSeconds)
        )
        XCTAssertEqual(
            code(HardCapGate(extensionStepSeconds: 15).decide(verdict: verdict, session: full)),
            ToolRejectionCode.headStartCap
        )
    }

    func testCueRateLimitUsesTheSharedThreeMinuteCap() {
        XCTAssertFalse(HardCapGate.isCueRateLimited(lastCueAt: nil, now: now))
        XCTAssertTrue(HardCapGate.isCueRateLimited(lastCueAt: now.addingTimeInterval(-179), now: now))
        XCTAssertFalse(HardCapGate.isCueRateLimited(
            lastCueAt: now.addingTimeInterval(-SessionLimits.cueRateLimitSeconds),
            now: now
        ))
    }

    private func code(_ result: ToolHandlerResult) -> String? {
        guard case .rejected(let rejection) = result.outcome else {
            return nil
        }
        return rejection.code
    }
}
