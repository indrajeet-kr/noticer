import XCTest
@testable import NoticerCore

final class VisitorSuppressionTests: EngineTestCase {
    func testASecondAdultMustPersistForThreeFrames() {
        see([mom(), adultVisitor()])
        XCTAssertFalse(engine.visitorUploadPaused)
        see([mom(), adultVisitor()])
        XCTAssertFalse(engine.visitorUploadPaused)
        see([mom(), adultVisitor()])
        XCTAssertTrue(engine.visitorUploadPaused)
        XCTAssertEqual(events(.visitorPaused).count, 1)
        XCTAssertTrue(engine.keyframes().isEmpty)
        XCTAssertNil(engine.pendingModelCall)
        XCTAssertEqual(engine.modelCallsIssued, 0)
    }

    func testABreakInTheRunResetsTheCount() {
        see([mom(), adultVisitor()])
        see([mom(), adultVisitor()])
        see([mom()])
        XCTAssertFalse(engine.visitorUploadPaused)
        see([mom(), adultVisitor()])
        see([mom(), adultVisitor()])
        XCTAssertFalse(engine.visitorUploadPaused)
        see([mom(), adultVisitor()])
        XCTAssertTrue(engine.visitorUploadPaused)
    }

    func testMomHoldingTheBabyDoesNotPause() {
        for _ in 0..<5 {
            see([mom(), baby()])
        }
        XCTAssertFalse(engine.visitorUploadPaused)
        XCTAssertFalse(engine.keyframes().isEmpty)
        XCTAssertTrue(events(.visitorPaused).isEmpty)
    }

    func testALandscapeScreenDoesNotPause() {
        for _ in 0..<4 {
            see([mom(), television()])
        }
        XCTAssertFalse(engine.visitorUploadPaused)
    }

    func testOnePersonNeverPauses() {
        for _ in 0..<5 {
            advance(0.5)
            see([mom()])
        }
        XCTAssertFalse(engine.visitorUploadPaused)
    }

    func testPauseBlocksAModelCallUntilTheVisitorIsGone() throws {
        try latch("take-baby")
        for _ in 0..<3 {
            advance(0.5)
            see([mom(), adultVisitor()])
        }
        XCTAssertTrue(engine.visitorUploadPaused)
        let issued = engine.modelCallsIssued
        advance(SessionLimits.heartbeatSeconds)
        engine.tick()
        XCTAssertNil(engine.pendingModelCall)
        XCTAssertEqual(engine.modelCallsIssued, issued)

        see([mom()])
        XCTAssertFalse(engine.visitorUploadPaused)
        XCTAssertEqual(events(.visitorResumed).count, 1)
    }

    func testAdultSizeBoundaries() {
        XCTAssertTrue(VisitorMonitor.isAdultSized(person(width: 0.20, height: 0.40)))
        XCTAssertFalse(VisitorMonitor.isAdultSized(person(width: 0.20, height: 0.39)))
        XCTAssertFalse(VisitorMonitor.isAdultSized(person(width: 0.19, height: 0.40)))
        XCTAssertFalse(VisitorMonitor.isAdultSized(person(width: 0.10, height: 0.50)))
        XCTAssertFalse(VisitorMonitor.isAdultSized(person(width: 0.50, height: 0.50)))
        XCTAssertFalse(VisitorMonitor.hasTwoAdultSizedPeople([mom(), baby()]))
        XCTAssertTrue(VisitorMonitor.hasTwoAdultSizedPeople([mom(), adultVisitor()]))
        XCTAssertFalse(VisitorMonitor.hasTwoAdultSizedPeople([mom()]))
    }

    private func latch(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
    }
}
