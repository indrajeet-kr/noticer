import XCTest
@testable import NoticerCore

final class HardCapTests: EngineTestCase {
    func testAtMostTwoNeedsStayOpenAndABetterOnePreemptsTheWorst() throws {
        try engine.setNeeds([
            Self.need(id: "water", priority: 2),
            Self.need(id: "snack", priority: 3),
            Self.need(id: "later", priority: 4),
            Self.need(id: "baby", priority: 0),
        ])
        try latch("water")
        advance(SessionLimits.latchMinIntervalSeconds)
        try latch("snack")
        XCTAssertEqual(engine.openNeedIDs, ["water", "snack"])

        advance(SessionLimits.latchMinIntervalSeconds)
        try offer("later")
        XCTAssertEqual(events(.latchRejected).last?.detail, "max-open")
        XCTAssertEqual(Set(engine.openNeedIDs), ["water", "snack"])

        advance(SessionLimits.latchMinIntervalSeconds)
        try latch("baby")
        XCTAssertEqual(Set(engine.openNeedIDs), ["water", "baby"])
        XCTAssertEqual(events(.closedUnknown).last?.detail, "preempted")
        XCTAssertEqual(events(.closedUnknown).last?.needID, "snack")
    }

    func testMomPriorityDecidesWhichDueCuePlaysAndTheRateLimitHoldsTheOther() throws {
        try engine.setNeeds([
            Self.need(id: "water", priority: 5),
            // Water latches 15 s earlier and uses the 90 s base, so 75 s
            // lands both deadlines on the same instant.
            Self.need(id: "baby", priority: 1, dwell: 75),
        ])
        try latch("water")
        let waterDeadline = try XCTUnwrap(engine.openNeeds.first { $0.needID == "water" }).cueDeadline
        advance(SessionLimits.latchMinIntervalSeconds)
        try latch("baby")
        let baby = try XCTUnwrap(engine.openNeeds.first { $0.needID == "baby" })
        XCTAssertEqual(baby.cueDeadline, waterDeadline)

        try refresh(before: waterDeadline)
        advance(to: waterDeadline)
        engine.tick()
        XCTAssertEqual(engine.cues.map(\.needID), ["baby"])
        XCTAssertEqual(engine.openNeedIDs, ["water"])
        XCTAssertEqual(events(.cueDeferredRateLimit).map(\.needID), ["water"])

        engine.noteSameChore("sink")
        advance(100)
        engine.tick()
        XCTAssertEqual(engine.cues.map(\.needID), ["baby"])
        XCTAssertEqual(engine.openNeedIDs, ["water"])

        // Refresh the chore mark so the 120 s window still covers the moment
        // the 3-minute rate limit lifts, 180 s after the baby cue.
        engine.noteSameChore("sink")
        advance(80)
        engine.tick()
        XCTAssertEqual(engine.cues.map(\.needID), ["baby", "water"])
    }

    func testTheSessionCapStopsCuesAndCalls() throws {
        advance(SessionLimits.maxSessionSeconds - 50)
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict("take-baby"))
        let open = try XCTUnwrap(engine.openNeeds.first)
        XCTAssertGreaterThan(open.cueDeadline, Self.origin.addingTimeInterval(SessionLimits.maxSessionSeconds))

        advance(to: Self.origin.addingTimeInterval(SessionLimits.maxSessionSeconds))
        engine.tick()
        see([mom()], handsEdge: true)
        XCTAssertTrue(engine.cues.isEmpty)
        XCTAssertNil(engine.pendingModelCall)
        XCTAssertFalse(events(.sessionEnded).isEmpty)

        advance(to: open.cueDeadline)
        engine.tick()
        XCTAssertTrue(engine.cues.isEmpty)
    }

    func testTheModelCallBudgetIsThreeHundred() throws {
        try latch("take-baby")
        XCTAssertEqual(engine.modelCallsIssued, 1)
        var frame = 0
        while engine.modelCallsIssued < SessionLimits.maxModelCallsPerSession {
            // Same glance, new pixels each turn: the heartbeat fires without
            // advancing the clock past the head-start deadline.
            see([mom()], sharpness: Double(frame), jpeg: UInt8(frame % 2), handsEdge: true)
            frame += 1
            let call = try XCTUnwrap(engine.pendingModelCall)
            engine.handle(callID: call.id, verdict: noTransition("take-baby"))
        }
        XCTAssertEqual(engine.modelCallsIssued, 300)
        see([mom()], handsEdge: true)
        XCTAssertNil(engine.pendingModelCall)
        XCTAssertFalse(events(.callBudgetExhausted).isEmpty)
    }

    func testAStaleReplyIsDropped() throws {
        glancePair()
        let stale = try XCTUnwrap(engine.pendingModelCall)
        advance(EngineTuning.inFlightStaleSeconds)
        see([mom()])
        let fresh = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertNotEqual(stale.id, fresh.id)

        engine.handle(callID: stale.id, verdict: latchVerdict("take-baby"))
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.staleReplyDropped).last?.detail, stale.id)

        engine.handle(callID: fresh.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testHeartbeatsRunEveryEightSecondsWhileANeedIsOpen() throws {
        try latch("take-baby")
        advance(SessionLimits.heartbeatSeconds - 1)
        engine.tick()
        XCTAssertNil(engine.pendingModelCall)
        advance(1)
        see([mom()])
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .heartbeat)
        XCTAssertEqual(call.request.needs.count, 2)
    }

    /// A second need is offered on a heartbeat once one need is already open.
    /// The tool is still `latch_need_hypothesis`; the phone decides.
    private func offer(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
    }

    private func latch(_ id: String) throws {
        try offer(id)
        XCTAssertTrue(engine.openNeedIDs.contains(id))
    }

    private func refresh(before date: Date) throws {
        advance(to: date.addingTimeInterval(-15))
        see([mom()])
        if let call = engine.pendingModelCall {
            engine.handle(callID: call.id, verdict: noTransition())
        }
    }
}
