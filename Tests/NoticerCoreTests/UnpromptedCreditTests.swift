import XCTest
@testable import NoticerCore

/// Credit for help he gives on his own, in two steps: an intervention
/// with no open episode only arms the start, and the credit lands when a
/// verdict inside 60 s shows the need's full handled state. Completion
/// applies the self-notice step, speaks nothing, and debounces to one
/// per need per 10 minutes.
final class UnpromptedCreditTests: EngineTestCase {
    private var signal: String { ActionCodeExamples.wearerHandsReceivingBaby }

    private func setupSignalledNeeds() throws {
        try engine.setNeeds([Self.takeBaby(selfNotice: signal), Self.refillWater()])
    }

    private func wearerAction(_ tool: ToolName, confidence: Double? = 0.8, action: String? = nil) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: tool,
            assessment: SceneAssessment(
                needID: "take-baby",
                sustainedAcrossStrip: tool == .reportNeedResolved ? false : nil,
                actionCode: action ?? signal,
                confidence: confidence
            )
        )
    }

    private func nextLatchCall() throws -> PendingModelCall {
        advance(SessionLimits.latchMinIntervalSeconds + 1)
        see([mom()], handsEdge: true)
        return try XCTUnwrap(engine.pendingModelCall)
    }

    private func startAction() throws {
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: wearerAction(.logWearerIntervention))
    }

    private func completeAction() throws {
        let call = try nextLatchCall()
        engine.handle(callID: call.id, verdict: wearerAction(.reportNeedResolved))
    }

    func testInterventionAloneArmsWithoutCredit() throws {
        try setupSignalledNeeds()
        glancePair()

        try startAction()

        XCTAssertEqual(events(.unpromptedStarted).map(\.needID), ["take-baby"])
        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), .initial)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertTrue(engine.cues.isEmpty)
    }

    func testResolvedWithinWindowCompletesExactlyOnce() throws {
        try setupSignalledNeeds()
        glancePair()
        let before = mastery(of: "take-baby")

        try startAction()
        try completeAction()

        XCTAssertEqual(events(.selfNoticedUnprompted).map(\.needID), ["take-baby"])
        XCTAssertEqual(mastery(of: "take-baby"), MasteryMath.applySelfNotice(before))
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertTrue(engine.cues.isEmpty)
    }

    func testSecondCompletionWithinTenMinutesIsIgnored() throws {
        try setupSignalledNeeds()
        glancePair()

        try startAction()
        try completeAction()
        let credited = mastery(of: "take-baby")

        try startActionOnFreshCall()
        try completeAction()

        XCTAssertEqual(events(.selfNoticedUnprompted).count, 1)
        XCTAssertEqual(mastery(of: "take-baby"), credited)
    }

    private func startActionOnFreshCall() throws {
        let call = try nextLatchCall()
        engine.handle(callID: call.id, verdict: wearerAction(.logWearerIntervention))
    }

    func testCompletionAfterTenMinutesCreditsAgain() throws {
        try setupSignalledNeeds()
        glancePair()

        try startAction()
        try completeAction()

        advance(EngineTuning.unpromptedDebounceSeconds)
        glancePair()
        try startAction()
        try completeAction()

        XCTAssertEqual(events(.selfNoticedUnprompted).count, 2)
    }

    func testLowConfidenceDoesNotCredit() throws {
        try setupSignalledNeeds()
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(callID: call.id, verdict: wearerAction(.logWearerIntervention, confidence: 0.6))

        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), .initial)
    }

    func testUnrelatedActionDoesNotCredit() throws {
        try setupSignalledNeeds()
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(callID: call.id, verdict: wearerAction(.logWearerIntervention, action: "wearer_doing_dishes"))

        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), .initial)
    }

    func testOpenNeedKeepsTheExistingCreditPath() throws {
        try setupSignalledNeeds()
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])

        let heartbeat = try nextLatchCall()
        engine.handle(callID: heartbeat.id, verdict: wearerAction(.logWearerIntervention))

        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, signal)
    }
}
