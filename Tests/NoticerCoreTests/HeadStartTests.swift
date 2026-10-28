import XCTest
@testable import NoticerCore

final class HeadStartTests: EngineTestCase {
    func testDefaultHeadStartCuesAtNinetySecondsWhileSheIsStillInView() throws {
        try latch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        XCTAssertEqual(open.cueDeadline.timeIntervalSince(open.latchedAt), 90)
        XCTAssertEqual(open.hardCapAt.timeIntervalSince(open.latchedAt), 120)

        try refreshSighting(secondsBefore: open.cueDeadline, lead: 20)
        advance(to: open.cueDeadline)
        engine.tick()

        let cue = try XCTUnwrap(engine.cues.first)
        XCTAssertEqual(cue.needID, "take-baby")
        XCTAssertEqual(cue.kind, .whisper)
        XCTAssertEqual(cue.text, Self.takeBaby().cueWording)
        XCTAssertEqual(cue.createdAt, open.cueDeadline)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertTrue(events(.recheckRequested).isEmpty)
    }

    func testDwellSecondsOverrideTheBaseHeadStartWhenMomSetsThem() throws {
        try engine.setNeeds([Self.takeBaby(dwell: 45)])
        try latch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        XCTAssertEqual(open.cueDeadline.timeIntervalSince(open.latchedAt), 45)
        XCTAssertEqual(open.hardCapAt.timeIntervalSince(open.latchedAt), 120)
    }

    func testANilDwellKeepsTheNinetySecondBase() throws {
        try engine.setNeeds([Self.takeBaby(dwell: nil)])
        try latch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        XCTAssertEqual(open.cueDeadline.timeIntervalSince(open.latchedAt), 90)
    }

    func testMasteryLengthensTheHeadStartAndTheCapHoldsItAtOneTwenty() throws {
        let practiced = MasteryState(score: 0.25, consecutiveSelfNotices: 1, consecutiveMisses: 0)
        try engine.setNeeds([Self.takeBaby(mastery: practiced)])
        try latch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        // 90 * (1 + 2 * 0.25) = 135, then the cap.
        XCTAssertEqual(open.cueDeadline.timeIntervalSince(open.latchedAt), 120)
    }

    func testDwellAndMasteryStillStopAtTheCap() throws {
        let practiced = MasteryState(score: 0.5, consecutiveSelfNotices: 0, consecutiveMisses: 0)
        try engine.setNeeds([Self.takeBaby(dwell: 60, mastery: practiced)])
        try latch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        // 60 * (1 + 2 * 0.5) = 120.
        XCTAssertEqual(open.cueDeadline.timeIntervalSince(open.latchedAt), 120)
    }

    func testEachExtensionAddsFifteenSecondsUntilTheCap() throws {
        try latch("take-baby")
        try grantExtension("take-baby")
        XCTAssertEqual(try deadlineOffset(), 105)
        try grantExtension("take-baby")
        XCTAssertEqual(try deadlineOffset(), 120)
        try grantExtension("take-baby")
        XCTAssertEqual(try deadlineOffset(), 120)
        XCTAssertEqual(events(.headStartExtended).count, 2)
        XCTAssertEqual(events(.headStartExtensionDenied).last?.detail, "at-cap")
    }

    func testBusyHandsDeferTheCueUntilTheHardCapFiresIt() throws {
        try latch("take-baby")
        try markBusy("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)

        try refreshSighting(secondsBefore: open.cueDeadline, lead: 15)
        advance(to: open.cueDeadline)
        engine.tick()
        XCTAssertTrue(engine.cues.isEmpty)
        XCTAssertEqual(events(.cueDeferredHandsBusy).map(\.needID), ["take-baby"])

        try refreshSighting(secondsBefore: open.hardCapAt, lead: 15)
        advance(to: open.hardCapAt.addingTimeInterval(-1))
        engine.tick()
        XCTAssertTrue(engine.cues.isEmpty)

        advance(to: open.hardCapAt)
        engine.tick()
        let cue = try XCTUnwrap(engine.cues.first)
        XCTAssertEqual(cue.createdAt, open.hardCapAt)
        XCTAssertEqual(cue.kind, .whisper)
    }

    func testFreeHandsCueAsSoonAsTheDeferralLifts() throws {
        try latch("take-baby")
        try markBusy("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        try refreshSighting(secondsBefore: open.cueDeadline, lead: 15)

        let freed = open.cueDeadline.addingTimeInterval(8)
        advance(to: freed)
        see([mom()], handsEdge: true)
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: noTransition("take-baby", handsOccupied: false))

        let cue = try XCTUnwrap(engine.cues.first)
        XCTAssertEqual(cue.createdAt, freed)
        XCTAssertEqual(cue.needID, "take-baby")
    }

    private func latch(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
        XCTAssertTrue(engine.openNeedIDs.contains(id))
    }

    private func grantExtension(_ id: String) throws {
        see([mom()], handsEdge: true)
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .heartbeat)
        engine.handle(callID: call.id, verdict: extensionRequest(id))
    }

    private func markBusy(_ id: String) throws {
        see([mom()], handsEdge: true)
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: deferral(id))
        XCTAssertEqual(engine.openNeeds.first?.handsBusy, true)
    }

    private func deadlineOffset() throws -> TimeInterval {
        let open = try XCTUnwrap(engine.openNeeds.first)
        return open.cueDeadline.timeIntervalSince(open.latchedAt)
    }

    /// Puts mom back in frame shortly before `date` so the 45 s close and the
    /// 30 s stale-evidence rule are not what the timer test is measuring.
    private func refreshSighting(secondsBefore date: Date, lead: TimeInterval) throws {
        advance(to: date.addingTimeInterval(-lead))
        see([mom()])
        if let call = engine.pendingModelCall {
            engine.handle(callID: call.id, verdict: noTransition("take-baby"))
        }
    }
}
