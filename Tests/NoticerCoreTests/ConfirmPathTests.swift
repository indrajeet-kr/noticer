import XCTest
@testable import NoticerCore

/// Brief sightings get a second look: one focused confirm call within
/// 1.5 s for a high-confidence not-sustained hypothesis, and two
/// hypotheses inside 10 s count as sustained.
final class ConfirmPathTests: EngineTestCase {
    func testNotSustainedHighConfidenceSchedulesExactlyOneConfirm() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(latch.purpose, .latch)

        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby", sustained: false, confidence: 0.75))

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.confirmScheduled).map(\.needID), ["take-baby"])
        // Not due yet: nothing issues.
        engine.tick()
        XCTAssertNil(engine.pendingModelCall)

        advance(EngineTuning.confirmDelaySeconds)
        see([mom()], jpeg: 2)
        let confirm = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(confirm.purpose, .confirm)
        XCTAssertEqual(confirm.request.focusNeedID, "take-baby")
        let hypothesisID = latch.request.keyframes.max(by: { $0.capturedAt < $1.capturedAt })?.id
        XCTAssertTrue(confirm.request.keyframes.map(\.id).contains(hypothesisID))

        // Exactly one: later ticks never re-issue while it is in flight.
        advance(5)
        engine.tick()
        XCTAssertEqual(engine.pendingModelCall?.id, confirm.id)
        XCTAssertEqual(events(.confirmScheduled).count, 1)
    }

    func testLowConfidenceSchedulesNoConfirm() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby", sustained: false, confidence: 0.5))

        XCTAssertTrue(events(.confirmScheduled).isEmpty)
        advance(5)
        engine.tick()
        XCTAssertNil(engine.pendingModelCall)
    }

    func testTwoHypothesesWithinTenSecondsLatchAndCue() throws {
        var urgent = Self.takeBaby()
        urgent.isUrgent = true
        try engine.setNeeds([urgent, Self.refillWater()])

        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby", sustained: false, confidence: 0.75))

        advance(EngineTuning.confirmDelaySeconds)
        see([mom()], jpeg: 2)
        let confirm = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(confirm.purpose, .confirm)

        engine.handle(callID: confirm.id, verdict: latchVerdict("take-baby", sustained: false, confidence: 0.8))

        XCTAssertEqual(events(.sustainedByRepeat).map(\.needID), ["take-baby"])
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        // Urgent keeps no head start: the cue fires on the latch.
        XCTAssertEqual(events(.cueFired).map(\.needID), ["take-baby"])
    }

    func testHypothesesFifteenSecondsApartDoNotLatch() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby", sustained: false, confidence: 0.75))

        advance(EngineTuning.confirmDelaySeconds)
        engine.tick()
        let confirm = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: confirm.id, verdict: noTransition())

        advance(13.5)
        see([mom()], handsEdge: true)
        let second = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: second.id, verdict: latchVerdict("take-baby", sustained: false, confidence: 0.75))

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertTrue(events(.sustainedByRepeat).isEmpty)
        XCTAssertEqual(events(.latchRejected).last?.detail, "not-sustained")
    }
}
