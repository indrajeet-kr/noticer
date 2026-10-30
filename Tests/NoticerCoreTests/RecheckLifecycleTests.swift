import XCTest
@testable import NoticerCore

/// Recheck lifecycle: one flaky no-transition must not kill a latch, a
/// recheck-clear must not trigger the full relatch cooldown, and a
/// heartbeat must not re-read an unchanged strip.
final class RecheckLifecycleTests: EngineTestCase {
    func testFirstRecheckNoTransitionKeepsNeedOpenAndAsksAgain() throws {
        try latch("take-baby")
        engine.noteSameChore("dishwasher")
        let deadline = try XCTUnwrap(engine.openNeeds.first).cueDeadline
        advance(to: deadline)
        engine.tick()
        let first = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(first.purpose, .recheck)

        engine.handle(callID: first.id, verdict: noTransition("take-baby", sustained: false))

        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertEqual(events(.closedUnknown).count, 0)
        XCTAssertTrue(try XCTUnwrap(engine.openNeeds.first).awaitingRecheck)
        XCTAssertEqual(events(.recheckRequested).last?.detail, "confirming")
        let second = try XCTUnwrap(engine.pendingModelCall, "one flaky frame re-issues, it does not close")
        XCTAssertEqual(second.purpose, .recheck)
    }

    func testSecondRecheckNoTransitionClosesWithShortCooldown() throws {
        try latch("take-baby")
        engine.noteSameChore("dishwasher")
        let deadline = try XCTUnwrap(engine.openNeeds.first).cueDeadline
        advance(to: deadline)
        engine.tick()
        let first = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: first.id, verdict: noTransition("take-baby", sustained: false))
        let second = try XCTUnwrap(engine.pendingModelCall)
        let clearedAt = clock.now()
        engine.handle(callID: second.id, verdict: noTransition("take-baby", sustained: false))

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.closedUnknown).last?.detail, "recheck-cleared")

        // Inside the grace window the relatch is still refused.
        advance(4)
        see([mom()])
        advance(4)
        see([mom()])
        engine.tick()
        let early = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: early.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(events(.latchRejected).last?.detail, "cooldown")
        XCTAssertTrue(engine.openNeedIDs.isEmpty)

        // Past the grace window — far short of the full cooldown — the
        // same need latches again.
        XCTAssertLessThan(clock.now().timeIntervalSince(clearedAt), SessionLimits.relatchCooldownSeconds)
        advance(EngineTuning.recheckRelatchGraceSeconds + 1)
        see([mom()])
        engine.tick()
        let late = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: late.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testSustainedVerdictResetsRecheckStrikesAndCues() throws {
        try latch("take-baby")
        engine.noteSameChore("dishwasher")
        let deadline = try XCTUnwrap(engine.openNeeds.first).cueDeadline
        advance(to: deadline)
        engine.tick()
        let first = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: first.id, verdict: noTransition("take-baby", sustained: false))
        let second = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(callID: second.id, verdict: noTransition("take-baby", sustained: true))

        XCTAssertEqual(engine.cues.count, 1)
        XCTAssertEqual(events(.closedUnknown).filter { $0.detail == "recheck-cleared" }.count, 0)
    }

    func testHeartbeatSkipsWhenStripHasNotChanged() throws {
        try latch("take-baby")
        engine.noteSameChore("dishwasher")

        // Due, but the latch call already read these exact pixels.
        advance(SessionLimits.heartbeatSeconds + 1)
        engine.tick()
        XCTAssertNil(engine.pendingModelCall)

        // New pixels re-arm the heartbeat.
        see([mom()])
        let beat = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(beat.purpose, .heartbeat)
        engine.handle(callID: beat.id, verdict: noTransition("take-baby", sustained: true))

        // Due again on a frozen strip: still no call.
        advance(SessionLimits.heartbeatSeconds + 1)
        engine.tick()
        XCTAssertNil(engine.pendingModelCall)
        XCTAssertEqual(engine.modelCallsIssued, 2)
    }

    func testCallIssuedEventNamesPurposeAndStripSize() throws {
        glancePair()
        XCTAssertEqual(events(.callIssued).map(\.detail), ["latch kf=2"])
    }

    private func latch(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
    }
}
