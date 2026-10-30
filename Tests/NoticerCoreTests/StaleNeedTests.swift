import XCTest
@testable import NoticerCore

final class StaleNeedTests: EngineTestCase {
    func testNoPersonForFortyFiveSecondsClosesAsUnknownWithoutMovingMastery() throws {
        let seeded = MasteryState(score: 0.4, consecutiveSelfNotices: 1, consecutiveMisses: 0)
        try engine.setNeeds([Self.takeBaby(mastery: seeded)])
        try latch("take-baby")
        let seen = clock.now()

        advance(to: seen.addingTimeInterval(44))
        engine.tick()
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])

        advance(to: seen.addingTimeInterval(SessionLimits.noPersonKeyframeCloseSeconds))
        engine.tick()
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertTrue(engine.cues.isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), seeded)
        XCTAssertEqual(events(.closedUnknown).last?.detail, "no-person")
    }

    func testSameChoreKeepsTheNeedOpenAndRechecksBeforeTheCue() throws {
        try latch("take-baby")
        engine.noteSameChore("dishwasher")
        let open = try XCTUnwrap(engine.openNeeds.first)
        XCTAssertEqual(open.choreID, "dishwasher")

        advance(to: open.latchedAt.addingTimeInterval(50))
        engine.tick()
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"], "back turned, still at the dishwasher")

        advance(to: open.cueDeadline)
        engine.tick()
        XCTAssertTrue(engine.cues.isEmpty)
        let recheck = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(recheck.purpose, .recheck)
        XCTAssertEqual(events(.recheckRequested).map(\.needID), ["take-baby"])

        engine.handle(callID: recheck.id, verdict: noTransition("take-baby", sustained: true))
        let cue = try XCTUnwrap(engine.cues.first)
        XCTAssertEqual(cue.kind, .whisper)
        XCTAssertEqual(cue.text, Self.takeBaby().cueWording)
        XCTAssertTrue(events(.cueFired).contains { $0.detail == CueKind.whisper.rawValue })
    }

    func testAnInconclusiveRecheckUsesCheckInOnlyWhenMomAllowsIt() throws {
        try engine.setNeeds([Self.takeBaby(allowsCheckIn: true)])
        try latch("take-baby")
        engine.noteSameChore("dishwasher")
        let deadline = try XCTUnwrap(engine.openNeeds.first).cueDeadline
        advance(to: deadline)
        engine.tick()
        let recheck = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: recheck.id, verdict: noTransition("take-baby"))

        let cue = try XCTUnwrap(engine.cues.first)
        XCTAssertEqual(cue.kind, .checkIn)
        XCTAssertEqual(cue.text, Self.takeBaby().cueWording)
    }

    func testAnInconclusiveRecheckDoesNotWhisperWhenCheckInIsOff() throws {
        try latch("take-baby")
        engine.noteSameChore("dishwasher")
        let deadline = try XCTUnwrap(engine.openNeeds.first).cueDeadline
        advance(to: deadline)
        engine.tick()
        let recheck = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: recheck.id, verdict: noTransition("take-baby"))

        XCTAssertTrue(engine.cues.isEmpty)
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        let calls = engine.modelCallsIssued
        engine.tick()
        XCTAssertEqual(engine.modelCallsIssued, calls, "one re-check, not a loop")
        XCTAssertTrue(engine.cues.isEmpty)
    }

    func testARecheckThatSaysMomHandledItDoesNotCueOrChangeMastery() throws {
        let seeded = MasteryState(score: 0.4, consecutiveSelfNotices: 1, consecutiveMisses: 0)
        try engine.setNeeds([Self.takeBaby(mastery: seeded)])
        try latch("take-baby")
        engine.noteSameChore("dishwasher")
        let deadline = try XCTUnwrap(engine.openNeeds.first).cueDeadline
        advance(to: deadline)
        engine.tick()
        let recheck = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: recheck.id, verdict: partnerResolved("take-baby", tool: .deferCueWearerBusy))
        XCTAssertTrue(engine.cues.isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), seeded)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
    }

    func testAFreshSightingCuesWithoutARecheck() throws {
        try latch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        advance(to: open.cueDeadline.addingTimeInterval(-10))
        see([mom()])
        if let call = engine.pendingModelCall {
            engine.handle(callID: call.id, verdict: noTransition("take-baby"))
        }
        advance(to: open.cueDeadline)
        engine.tick()
        XCTAssertEqual(engine.cues.first?.kind, .whisper)
        XCTAssertTrue(events(.recheckRequested).isEmpty)
    }

    func testTheSameChoreWindowExpires() throws {
        try latch("take-baby")
        engine.noteSameChore("dishwasher")
        let marked = clock.now()
        advance(to: marked.addingTimeInterval(EngineTuning.sameChoreWindowSeconds))
        engine.tick()
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])

        advance(to: marked.addingTimeInterval(EngineTuning.sameChoreWindowSeconds + 1))
        engine.tick()
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.closedUnknown).last?.detail, "no-person")
    }

    func testAbsentLatchSurvivesTheNoPersonWindowAndCues() throws {
        // A person seen a minute ago arms the no-person clock, then the room
        // goes empty: the absent latch must survive and still cue.
        glancePair()
        let seen = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: seen.id, verdict: ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNoTransition,
            assessment: SceneAssessment(partnerInView: true)
        ))
        advance(60)

        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        var latch = latchVerdict("take-baby")
        latch.assessment.partnerInView = false
        engine.handle(callID: call.id, verdict: latch)
        engine.tick()
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"], "an absent latch never dies instantly")

        advance(60)
        engine.tick()
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"], "absence does not close what holds without her")

        let open = try XCTUnwrap(engine.openNeeds.first)
        advance(to: open.cueDeadline)
        engine.tick()
        let recheck = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(recheck.purpose, .recheck)
        engine.handle(callID: recheck.id, verdict: noTransition("take-baby", sustained: true))
        XCTAssertEqual(engine.cues.first?.kind, .whisper)
        XCTAssertTrue(events(.closedUnknown).filter { $0.detail == "no-person" }.isEmpty)
    }

    private func latch(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
    }
}
