import XCTest
@testable import NoticerCore

/// A seen wearer action survives out-of-view frames: only a visibly
/// still-open verdict, a 30 s TTL, or the episode close clears it.
/// Every arm, keep, and clear leaves a log line.
final class PendingActionTests: EngineTestCase {
    private var signal: String { "wearer_closing_trash_lid" }

    private func trashCan() -> Need {
        Need(
            id: "trash-can-lid",
            authorText: "Close the lid of trash can and move it to the corner",
            cueWording: "Lid's open?",
            visualCondition: "lid visibly open, OR can visibly outside the designated corner",
            handledCondition: "lid closed AND can in the designated corner",
            unknownCondition: "placement cannot be judged when the corner is out of view",
            selfNoticeSignal: signal,
            priority: 0
        )
    }

    private func nextLatchCall() throws -> PendingModelCall {
        advance(SessionLimits.latchMinIntervalSeconds + 1)
        see([mom()], handsEdge: true)
        return try XCTUnwrap(engine.pendingModelCall)
    }

    private func partLatchVerdict(_ id: String) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: id,
                sustainedAcrossStrip: true,
                partnerStateEvidence: ["lid_open"],
                wearerHandsOccupied: false,
                confidence: 0.2
            )
        )
    }

    func testOutOfViewKeepsPendingActionUntilResolve() throws {
        var urgent = trashCan()
        urgent.isUrgent = true
        try engine.setNeeds([urgent, Self.refillWater()])
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: partLatchVerdict("trash-can-lid"))
        XCTAssertEqual(events(.cueFired).map(\.needID), ["trash-can-lid"])
        let masteryAfterCue = mastery(of: "trash-can-lid")

        // His action is seen and armed.
        let arm = try nextLatchCall()
        engine.handle(
            callID: arm.id,
            verdict: intervention("trash-can-lid", action: signal, sustained: true)
        )
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, signal)
        XCTAssertEqual(events(.actionArmed).map(\.needID), ["trash-can-lid"])
        XCTAssertEqual(events(.actionArmed).map(\.detail), [signal])

        // Out of view: the pending action survives.
        let oov = try nextLatchCall()
        engine.handle(callID: oov.id, verdict: noTransition("trash-can-lid", sustained: nil))
        XCTAssertEqual(events(.actionKept).map(\.detail), ["out-of-view"])
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, signal)
        XCTAssertEqual(engine.openNeedIDs, ["trash-can-lid"])

        // The handled state resolves through the kept action. She is in
        // view, so recent-intervention memory can't credit this: only the
        // pending action can, and only because it survived.
        let resolveCall = try nextLatchCall()
        engine.handle(
            callID: resolveCall.id,
            verdict: ModelVerdict(
                finishReason: .toolCalls,
                tool: .reportNeedResolved,
                assessment: SceneAssessment(
                    needID: "trash-can-lid",
                    sustainedAcrossStrip: false,
                    partnerStateEvidence: ["lid_handled", "placement_handled"],
                    partnerInView: true,
                    confidence: 0.85
                )
            )
        )
        XCTAssertEqual(events(.caughtHimself).count, 1, "one wearer credit")
        XCTAssertEqual(events(.caughtHimself).map(\.detail), ["after-cue"])
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(mastery(of: "trash-can-lid"), masteryAfterCue)
        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(events(.actionCleared).map(\.detail), ["reason=closed"])
    }

    func testVisiblyStillOpenClearsPendingAction() throws {
        try engine.setNeeds([trashCan(), Self.refillWater()])
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: partLatchVerdict("trash-can-lid"))

        let arm = try nextLatchCall()
        engine.handle(callID: arm.id, verdict: intervention("trash-can-lid", action: signal))
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, signal)

        let stillThere = try nextLatchCall()
        engine.handle(callID: stillThere.id, verdict: noTransition("trash-can-lid", sustained: true))
        XCTAssertEqual(events(.actionCleared).map(\.detail), ["reason=visible-still-open"])
        XCTAssertNil(engine.openNeeds.first?.pendingWearerAction)
        XCTAssertEqual(engine.openNeedIDs, ["trash-can-lid"])
        XCTAssertTrue(events(.caughtHimself).isEmpty)
    }

    func testPendingActionExpiresAfterThirtySeconds() throws {
        try engine.setNeeds([trashCan(), Self.refillWater()])
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: partLatchVerdict("trash-can-lid"))

        let arm = try nextLatchCall()
        engine.handle(callID: arm.id, verdict: intervention("trash-can-lid", action: signal))

        for index in 0..<3 {
            let oov = try nextLatchCall()
            // The middle verdict omits the need id; it still keeps the action.
            let verdict = index == 1
                ? noTransition(nil, sustained: nil)
                : noTransition("trash-can-lid", sustained: nil)
            engine.handle(callID: oov.id, verdict: verdict)
        }
        XCTAssertEqual(events(.actionKept).map(\.detail), ["out-of-view", "out-of-view"])
        XCTAssertEqual(events(.actionCleared).map(\.detail), ["reason=ttl"])
        XCTAssertNil(engine.openNeeds.first?.pendingWearerAction)
        XCTAssertEqual(engine.openNeedIDs, ["trash-can-lid"])
    }

    func testPartialCompoundStaysOpenAfterArmedAction() throws {
        try engine.setNeeds([trashCan(), Self.refillWater()])
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: partLatchVerdict("trash-can-lid"))

        let arm = try nextLatchCall()
        engine.handle(callID: arm.id, verdict: intervention("trash-can-lid", action: signal))

        let partial = try nextLatchCall()
        engine.handle(
            callID: partial.id,
            verdict: ModelVerdict(
                finishReason: .toolCalls,
                tool: .logWearerIntervention,
                assessment: SceneAssessment(
                    needID: "trash-can-lid",
                    sustainedAcrossStrip: false,
                    partnerStateEvidence: ["lid_handled", "placement_unknown"],
                    actionCode: signal,
                    confidence: 0.8
                )
            )
        )
        XCTAssertEqual(events(.stillOpen).last?.detail, "partial")
        XCTAssertEqual(engine.openNeedIDs, ["trash-can-lid"])
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, signal)
        XCTAssertEqual(mastery(of: "trash-can-lid"), .initial)
        XCTAssertTrue(events(.caughtHimself).isEmpty)
    }

    func testLegacyOutOfViewKeepsPendingAction() throws {
        engine = try NeedEngine(
            clock: clock,
            needs: [trashCan(), Self.refillWater()],
            latency: LatencyTuning(strictCredit: false)
        )
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: partLatchVerdict("trash-can-lid"))

        let arm = try nextLatchCall()
        engine.handle(callID: arm.id, verdict: intervention("trash-can-lid", action: signal))
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, signal)

        let oov = try nextLatchCall()
        engine.handle(callID: oov.id, verdict: noTransition("trash-can-lid", sustained: nil))
        XCTAssertEqual(events(.actionKept).map(\.detail), ["out-of-view"])
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, signal)
        XCTAssertEqual(engine.openNeedIDs, ["trash-can-lid"])
    }
}
