import XCTest
@testable import NoticerCore

final class CaughtHimselfTests: EngineTestCase {
    func testHisActionThenAClearNeedCreditsTheCatch() throws {
        try latch("take-baby")
        try arm("take-baby", action: ActionCodeExamples.wearerHandsReceivingBaby)
        XCTAssertEqual(mastery(of: "take-baby").score, 0)
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, ActionCodeExamples.wearerHandsReceivingBaby)

        try confirmCleared("take-baby")
        let mastery = mastery(of: "take-baby")
        XCTAssertEqual(mastery.score, 0.25)
        XCTAssertEqual(mastery.consecutiveSelfNotices, 1)
        XCTAssertEqual(mastery.consecutiveMisses, 0)
        XCTAssertEqual(mastery.phase, .coaching)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertTrue(engine.cues.isEmpty)
        XCTAssertEqual(events(.caughtHimself).last?.detail, ActionCodeExamples.wearerHandsReceivingBaby)
    }

    func testOneCallThatSeesBothTheActionAndTheClearDoesNotCreditYet() throws {
        try latch("take-baby")
        try heartbeat(intervention(
            "take-baby",
            action: ActionCodeExamples.wearerHandsReceivingBaby,
            sustained: false
        ))
        XCTAssertEqual(mastery(of: "take-baby").score, 0)
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, ActionCodeExamples.wearerHandsReceivingBaby)
        XCTAssertTrue(engine.cues.isEmpty)

        try confirmCleared("take-baby")
        XCTAssertEqual(mastery(of: "take-baby").score, 0.25)
    }

    func testAPassiveGlassDoesNotCountAsHimNoticing() throws {
        try latch("take-baby")
        try heartbeat(intervention("take-baby", action: ActionCodeExamples.waterGlassPresent))
        XCTAssertEqual(events(.actionRejected).last?.detail, ActionCodeExamples.waterGlassPresent)
        XCTAssertNil(engine.openNeeds.first?.pendingWearerAction)

        try heartbeat(noTransition("take-baby", sustained: false))
        XCTAssertEqual(mastery(of: "take-baby").score, 0)
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertTrue(events(.caughtHimself).isEmpty)
    }

    func testCaughtHimselfWithoutAPriorWearerActionIsDropped() throws {
        try latch("take-baby")
        try heartbeat(noTransition("take-baby", resolution: .caughtHimself))
        XCTAssertEqual(events(.actionRejected).last?.detail, "unconfirmed")
        XCTAssertEqual(mastery(of: "take-baby").score, 0)
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testCaughtHimselfWhileTheNeedIsStillSustainedDoesNotCredit() throws {
        try latch("take-baby")
        try arm("take-baby", action: ActionCodeExamples.wearerCarryingWaterTowardPartner)
        try heartbeat(noTransition("take-baby", sustained: true, resolution: .caughtHimself))
        XCTAssertEqual(mastery(of: "take-baby").score, 0)
        XCTAssertNil(engine.openNeeds.first?.pendingWearerAction)
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testAnOpenWearerActionStringCanArmTheCatch() throws {
        try latch("take-baby")
        try arm("take-baby", action: "wearer_folded_the_blanket")
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, "wearer_folded_the_blanket")
    }

    func testTheCompiledSelfNoticeSignalCountsWithoutTheWearerPrefix() throws {
        try engine.setNeeds([Self.takeBaby(selfNotice: "custom_signal")])
        try latch("take-baby")
        try arm("take-baby", action: "custom_signal")
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, "custom_signal")
        try confirmCleared("take-baby")
        XCTAssertEqual(mastery(of: "take-baby").score, 0.25)
    }

    func testMomResolvingItLeavesMasteryAlone() throws {
        let seeded = MasteryState(score: 0.4, consecutiveSelfNotices: 1, consecutiveMisses: 0)
        try engine.setNeeds([Self.takeBaby(mastery: seeded)])
        try latch("take-baby")
        try heartbeat(partnerResolved("take-baby"))
        XCTAssertEqual(mastery(of: "take-baby"), seeded)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertTrue(engine.cues.isEmpty)
        XCTAssertEqual(events(.resolvedByPartner).last?.detail, ToolName.reportNoTransition.rawValue)
    }

    func testPartnerResolutionOnAnyToolBeatsAPendingCatch() throws {
        let seeded = MasteryState(score: 0.4, consecutiveSelfNotices: 1, consecutiveMisses: 0)
        try engine.setNeeds([Self.takeBaby(mastery: seeded)])
        try latch("take-baby")
        try arm("take-baby", action: ActionCodeExamples.wearerHandsReceivingBaby)
        try heartbeat(partnerResolved("take-baby", tool: .deferCueWearerBusy))
        XCTAssertEqual(mastery(of: "take-baby"), seeded)
        XCTAssertTrue(events(.caughtHimself).isEmpty)
        XCTAssertEqual(events(.resolvedByPartner).last?.detail, ToolName.deferCueWearerBusy.rawValue)
    }

    func testAnUnknownResolutionStringIsIgnored() throws {
        try latch("take-baby")
        try heartbeat(noTransition("take-baby", resolution: Resolution(rawValue: "she_handled_it")))
        XCTAssertEqual(events(.assessmentDropped).last?.detail, "unknown-resolution")
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertEqual(mastery(of: "take-baby").score, 0)
    }

    private func latch(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
    }

    private func heartbeat(_ verdict: ModelVerdict) throws {
        advance(SessionLimits.heartbeatSeconds)
        engine.tick()
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .heartbeat)
        engine.handle(callID: call.id, verdict: verdict)
    }

    private func arm(_ id: String, action: String) throws {
        try heartbeat(intervention(id, action: action, sustained: true))
    }

    private func confirmCleared(_ id: String) throws {
        try heartbeat(noTransition(id, sustained: false))
    }
}
