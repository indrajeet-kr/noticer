import XCTest
@testable import NoticerCore

/// A cued need stays open so a resolution can still credit it. The model
/// reports handled/still-open against the open list instead of answering
/// `unknown` or re-latching into a cooldown.
final class ResolutionTests: EngineTestCase {
    func testOpenNeedResolvedByWearerBeforeCueCreditsSelfNotice() throws {
        try latch("take-baby")
        let old = mastery(of: "take-baby")
        try heartbeat(resolved("take-baby", resolution: .caughtHimself))

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.caughtHimself).last?.detail, "before-cue")
        let expected = old.score + CueFadeSpec.selfNoticeStep * (1 - old.score)
        XCTAssertEqual(mastery(of: "take-baby").score, expected, accuracy: 1e-9)
        XCTAssertEqual(mastery(of: "take-baby").consecutiveSelfNotices, 1)
    }

    func testResolvedAfterCueRecordsGotItWithoutDoubleCredit() throws {
        try latchAndCue("take-baby")
        XCTAssertEqual(engine.cues.count, 1)
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        let afterCue = mastery(of: "take-baby")

        try heartbeat(resolved("take-baby", resolution: .caughtHimself))

        XCTAssertEqual(events(.caughtHimself).last?.detail, "after-cue")
        XCTAssertEqual(mastery(of: "take-baby"), afterCue)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
    }

    func testNullNeedNoTransitionWhileOpenRefreshesEvidence() throws {
        try latch("take-baby")
        let latchedAt = try XCTUnwrap(engine.openNeeds.first).latchedAt
        let staleAt = try XCTUnwrap(engine.openNeeds.first).evidenceAt

        advance(SessionLimits.heartbeatSeconds)
        see([], sceneActive: true)
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .heartbeat)
        engine.handle(callID: call.id, verdict: noTransition("null", sustained: nil))

        XCTAssertTrue(events(.assessmentDropped).isEmpty)
        XCTAssertEqual(events(.stillOpen).last?.detail, "no-change")
        XCTAssertEqual(events(.stillOpen).last?.needID, "take-baby")
        let refreshed = try XCTUnwrap(engine.openNeeds.first).evidenceAt
        XCTAssertGreaterThan(refreshed, staleAt)

        // The old stale time passes with fresh evidence and no recheck.
        advance(to: latchedAt.addingTimeInterval(SessionLimits.staleEvidenceSeconds + 1))
        engine.tick()
        XCTAssertLessThan(
            clock.now().timeIntervalSince(refreshed),
            SessionLimits.staleEvidenceSeconds
        )
        XCTAssertTrue(events(.recheckRequested).isEmpty)
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testResolvedByOtherAdultGivesNoCredit() throws {
        try latch("take-baby")
        try heartbeat(resolved("take-baby", resolution: .resolvedByPartner))

        XCTAssertEqual(events(.resolvedByPartner).map(\.needID), ["take-baby"])
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), .initial)
    }

    func testResolvedByOtherAdultAfterCueGivesNoCredit() throws {
        try latchAndCue("take-baby")
        let afterCue = mastery(of: "take-baby")
        try heartbeat(resolved("take-baby", resolution: .resolvedByPartner))

        XCTAssertEqual(events(.resolvedByPartner).map(\.needID), ["take-baby"])
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), afterCue)
    }

    func testRelatchWhileOpenAfterCueIsAlreadyOpenNotCooldown() throws {
        try latchAndCue("take-baby")
        advance(SessionLimits.latchMinIntervalSeconds)
        see([mom()])
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict("take-baby"))

        XCTAssertEqual(events(.latchRejected).last?.detail, "already-open")
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testPostCueTimeoutClosesWithCooldown() throws {
        try latchAndCue("take-baby")
        let firedAt = try XCTUnwrap(engine.cues.first).createdAt

        advance(to: firedAt.addingTimeInterval(EngineTuning.postCueResolveSeconds - 1))
        engine.noteSameChore("dishwasher")
        engine.tick()
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])

        advance(to: firedAt.addingTimeInterval(EngineTuning.postCueResolveSeconds))
        engine.tick()
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.closedUnknown).last?.detail, "post-cue-timeout")

        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(events(.latchRejected).last?.detail, "cooldown")
    }

    func testStillOpenAmbiguousWithTwoOpenNeeds() throws {
        try latch("take-baby")
        advance(SessionLimits.latchMinIntervalSeconds)
        try latch("refill-water")
        let firstEvidence = try XCTUnwrap(engine.openNeeds.first { $0.needID == "take-baby" }).evidenceAt

        advance(SessionLimits.heartbeatSeconds)
        see([], sceneActive: true)
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: noTransition())

        XCTAssertEqual(events(.stillOpen).last?.detail, "ambiguous")
        XCTAssertNil(events(.stillOpen).last?.needID)
        XCTAssertTrue(events(.assessmentDropped).isEmpty)
        XCTAssertEqual(engine.openNeedIDs.count, 2)
        XCTAssertEqual(
            try XCTUnwrap(engine.openNeeds.first { $0.needID == "take-baby" }).evidenceAt,
            firstEvidence
        )
    }

    func testUnclearResolutionKeepsTheNeedOpen() throws {
        try latch("take-baby")
        try heartbeat(resolved("take-baby", resolution: .unknown))

        XCTAssertEqual(events(.stillOpen).last?.detail, "unclear")
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertEqual(mastery(of: "take-baby"), .initial)
    }

    private func latch(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
    }

    private func heartbeat(_ verdict: ModelVerdict) throws {
        advance(SessionLimits.heartbeatSeconds)
        see([mom()])
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .heartbeat)
        engine.handle(callID: call.id, verdict: verdict)
    }

    private func resolved(_ id: String, resolution: Resolution) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNeedResolved,
            assessment: SceneAssessment(needID: id, resolution: resolution)
        )
    }

    /// Latch, ride the head start to the deadline, sustain the recheck, and
    /// let the cue fire. The need stays open.
    private func latchAndCue(_ id: String) throws {
        try latch(id)
        engine.noteSameChore("dishwasher")
        let deadline = try XCTUnwrap(engine.openNeeds.first).cueDeadline
        advance(to: deadline)
        engine.tick()
        let recheck = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(recheck.purpose, .recheck)
        engine.handle(callID: recheck.id, verdict: noTransition(id, sustained: true))
    }
}
