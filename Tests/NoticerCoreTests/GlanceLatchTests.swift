import XCTest
@testable import NoticerCore

final class GlanceLatchTests: EngineTestCase {
    func testSlowGlancesLatchWhenTheModelAgrees() throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .latch)
        XCTAssertEqual(call.request.needs.map(\.id), ["take-baby", "refill-water"])
        XCTAssertGreaterThanOrEqual(call.request.keyframes.count, 2)
        let gap = call.request.keyframes.last!.capturedAt.timeIntervalSince(call.request.keyframes.first!.capturedAt)
        XCTAssertGreaterThanOrEqual(gap, SessionLimits.latchMinKeyframeSpacingSeconds)

        engine.handle(callID: call.id, verdict: latchVerdict("take-baby", confidence: 0.01))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertEqual(events(.needLatched).map(\.needID), ["take-baby"])
        let open = try XCTUnwrap(engine.openNeeds.first)
        XCTAssertEqual(open.cueDeadline.timeIntervalSince(open.latchedAt), SessionLimits.defaultHeadStartSeconds)
    }

    func testOneLongLookLatchesOnceTwoKeyframesAreFourSecondsApart() throws {
        see([mom()])
        XCTAssertNil(engine.pendingModelCall)
        advance(4)
        see([mom()])
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict("take-baby", confidence: nil))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testASingleFrameDoesNotLatchOnConfidenceAlone() throws {
        see([mom()])
        XCTAssertNil(engine.pendingModelCall)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict("take-baby", sustained: false, confidence: 0.99))
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.latchRejected).last?.detail, "not-sustained")
    }

    func testUnknownNeedIDIsDropped() throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict("not-on-the-list"))
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.assessmentDropped).last?.detail, "unknown-need")
    }

    func testLatchCallsAreAtLeastTenSecondsApart() throws {
        glancePair()
        let first = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: first.id, verdict: latchVerdict("take-baby"))
        advance(2)
        see([mom()], handsEdge: true)
        let early = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: early.id, verdict: latchVerdict("refill-water"))
        XCTAssertEqual(events(.latchRejected).last?.detail, "latch-interval")
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])

        advance(SessionLimits.latchMinIntervalSeconds)
        see([mom()], handsEdge: true)
        let later = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: later.id, verdict: latchVerdict("refill-water"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby", "refill-water"])
    }

    func testAResolvedNeedCannotRelatchDuringTheCooldown() throws {
        try open("take-baby")
        try sendHeartbeat(partnerResolved("take-baby"))
        XCTAssertTrue(engine.openNeedIDs.isEmpty)

        advance(30)
        glancePair()
        let rejected = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: rejected.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(events(.latchRejected).last?.detail, "cooldown")
        XCTAssertTrue(engine.openNeedIDs.isEmpty)

        advance(SessionLimits.relatchCooldownSeconds)
        glancePair()
        let allowed = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: allowed.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testAnAlreadyOpenNeedDoesNotRestartItsTimer() throws {
        try open("take-baby")
        let deadline = try XCTUnwrap(engine.openNeeds.first).cueDeadline
        advance(SessionLimits.latchMinIntervalSeconds)
        see([mom()], handsEdge: true)
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(events(.latchRejected).last?.detail, "already-open")
        XCTAssertEqual(engine.openNeeds.first?.cueDeadline, deadline)
    }

    private func open(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
        XCTAssertTrue(engine.openNeedIDs.contains(id))
    }

    private func sendHeartbeat(_ verdict: ModelVerdict) throws {
        advance(2)
        see([mom()], handsEdge: true)
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .heartbeat)
        engine.handle(callID: call.id, verdict: verdict)
    }
}
