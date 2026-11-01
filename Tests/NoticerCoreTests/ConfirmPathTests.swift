import XCTest
@testable import NoticerCore

/// Brief sightings get a second look: a focused confirm call once one is
/// due and a new frame exists, and two latch hypotheses inside 10 s count
/// as sustained. Confirm replies need new evidence; they never repeat-latch.
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

        // Due, with a fresh glance: the source frame plus one new frame.
        advance(EngineTuning.confirmDelaySeconds + 1)
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

    func testTwoLatchHypothesesWithinTenSecondsLatchViaRepeat() throws {
        // Non-urgent: confirm replies take the evidence path now, so the
        // repeat rule fires across two latch calls (quick timing fits two
        // inside the 10 s window). Low confidence keeps confirms out of it.
        engine = try NeedEngine(clock: clock, needs: [Self.takeBaby(), Self.refillWater()], timing: .quick)
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby", sustained: false, confidence: 0.5))
        XCTAssertTrue(events(.confirmScheduled).isEmpty)

        advance(4.5)
        see([mom()], jpeg: 2, handsEdge: true)
        let second = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(second.purpose, .latch)
        engine.handle(callID: second.id, verdict: latchVerdict("take-baby", sustained: false, confidence: 0.5))

        XCTAssertEqual(events(.sustainedByRepeat).map(\.needID), ["take-baby"])
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertTrue(engine.cues.isEmpty, "a non-urgent repeat latch keeps its head start")
    }

    func testHypothesesFifteenSecondsApartDoNotLatch() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby", sustained: false, confidence: 0.75))

        advance(EngineTuning.confirmDelaySeconds + 1)
        see([mom()], jpeg: 2)
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
