import XCTest
@testable import NoticerCore

final class MasteryTests: EngineTestCase {
    func testThreeCatchesRetireTheCue() throws {
        try latch("take-baby")
        try catchIt("take-baby")
        XCTAssertEqual(mastery(of: "take-baby").score, 0.25, accuracy: 1e-9)
        XCTAssertEqual(mastery(of: "take-baby").phase, .coaching)

        try relatch("take-baby")
        try catchIt("take-baby")
        XCTAssertEqual(mastery(of: "take-baby").score, 0.4375, accuracy: 1e-9)
        XCTAssertEqual(mastery(of: "take-baby").phase, .coaching)

        try relatch("take-baby")
        try catchIt("take-baby")
        let retired = mastery(of: "take-baby")
        XCTAssertEqual(retired.score, 0.578125, accuracy: 1e-9)
        XCTAssertEqual(retired.consecutiveSelfNotices, 3)
        XCTAssertEqual(retired.phase, .retired)
        XCTAssertEqual(events(.masteryRetired).map(\.needID), ["take-baby"])
        XCTAssertTrue(engine.cues.isEmpty)
    }

    func testTheNextHeadStartUsesTheNewMasteryAndStopsAtTheCap() throws {
        try latch("take-baby")
        try catchIt("take-baby")
        try relatch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        XCTAssertEqual(open.cueDeadline.timeIntervalSince(open.latchedAt), SessionLimits.headStartCapSeconds)
    }

    func testACueMultipliesMasteryAndAFalseCuePutsItBack() throws {
        let seeded = MasteryState(score: 0.4, consecutiveSelfNotices: 1, consecutiveMisses: 0)
        try engine.setNeeds([Self.takeBaby(mastery: seeded)])
        try latch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        try refresh(before: open.cueDeadline)
        advance(to: open.cueDeadline)
        engine.tick()

        let afterCue = mastery(of: "take-baby")
        XCTAssertEqual(afterCue.score, 0.4 * CueFadeSpec.cueFiredMultiplier, accuracy: 1e-9)
        XCTAssertEqual(afterCue.consecutiveSelfNotices, 0)
        XCTAssertEqual(afterCue.consecutiveMisses, 1)

        engine.dismissFalseCue(try XCTUnwrap(engine.cues.first).id)
        XCTAssertEqual(mastery(of: "take-baby"), seeded)
        XCTAssertEqual(events(.falseCueDismissed).count, 1)
        engine.dismissFalseCue(engine.cues[0].id)
        XCTAssertEqual(events(.falseCueDismissed).count, 1)
    }

    func testQuietMasteryChimesWithNoWords() throws {
        let quiet = MasteryState(score: 0.55, consecutiveSelfNotices: 1, consecutiveMisses: 0)
        XCTAssertEqual(quiet.phase, .quiet)
        try engine.setNeeds([Self.takeBaby(mastery: quiet)])
        try latch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        try refresh(before: open.cueDeadline)
        advance(to: open.cueDeadline)
        engine.tick()
        let cue = try XCTUnwrap(engine.cues.first)
        XCTAssertEqual(cue.kind, .chime)
        XCTAssertEqual(cue.text, "")
        XCTAssertEqual(mastery(of: "take-baby").score, 0.55 * 0.85, accuracy: 1e-9)
        XCTAssertEqual(mastery(of: "take-baby").phase, .coaching)
    }

    func testTwoMissesBringARetiredNeedBackToCoaching() throws {
        let retired = MasteryState(score: 0.578125, consecutiveSelfNotices: 3, consecutiveMisses: 0)
        try engine.setNeeds([Self.takeBaby(mastery: retired)])
        try latch("take-baby")
        engine.noteSameChore("dishwasher")
        let firstDeadline = try XCTUnwrap(engine.openNeeds.first).cueDeadline
        advance(to: firstDeadline)
        engine.tick()
        XCTAssertTrue(engine.cues.isEmpty)
        XCTAssertEqual(events(.retiredMiss).count, 1)
        XCTAssertEqual(mastery(of: "take-baby").score, 0.578125, accuracy: 1e-9)
        XCTAssertEqual(mastery(of: "take-baby").phase, .retired)

        try relatch("take-baby")
        engine.noteSameChore("dishwasher")
        let secondDeadline = try XCTUnwrap(engine.openNeeds.first).cueDeadline
        advance(to: secondDeadline)
        engine.tick()
        XCTAssertTrue(engine.cues.isEmpty)
        let mastery = mastery(of: "take-baby")
        XCTAssertEqual(mastery, .initial)
        XCTAssertEqual(mastery.phase, .coaching)
        XCTAssertEqual(events(.masteryUnretired).map(\.needID), ["take-baby"])
    }

    func testMomResolvingItDoesNotChangeTheStreak() throws {
        try latch("take-baby")
        try catchIt("take-baby")
        try relatch("take-baby")
        try heartbeat(partnerResolved("take-baby"))
        XCTAssertEqual(mastery(of: "take-baby").score, 0.25, accuracy: 1e-9)
        XCTAssertEqual(mastery(of: "take-baby").consecutiveSelfNotices, 1)
    }

    func testSelfNoticeMathFromZero() {
        var state = MasteryState.initial
        state = MasteryMath.applySelfNotice(state)
        state = MasteryMath.applySelfNotice(state)
        state = MasteryMath.applySelfNotice(state)
        XCTAssertEqual(state.score, 1 - pow(0.75, 3), accuracy: 1e-12)
        XCTAssertEqual(state.phase, .retired)
        let cued = MasteryMath.applyCueFired(state)
        XCTAssertEqual(cued.consecutiveSelfNotices, 0)
        XCTAssertEqual(cued.consecutiveMisses, 1)
    }

    private func latch(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
        XCTAssertTrue(engine.openNeedIDs.contains(id))
    }

    private func relatch(_ id: String) throws {
        advance(SessionLimits.relatchCooldownSeconds)
        try latch(id)
    }

    private func heartbeat(_ verdict: ModelVerdict) throws {
        advance(SessionLimits.heartbeatSeconds)
        see([mom()])
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: verdict)
    }

    private func catchIt(_ id: String) throws {
        try heartbeat(intervention(id, action: ActionCodeExamples.wearerHandsReceivingBaby, sustained: true))
        try heartbeat(noTransition(id, sustained: false))
        XCTAssertFalse(engine.openNeedIDs.contains(id))
    }

    private func refresh(before date: Date) throws {
        advance(to: date.addingTimeInterval(-15))
        see([mom()])
        if let call = engine.pendingModelCall {
            engine.handle(callID: call.id, verdict: noTransition("take-baby"))
        }
    }
}
