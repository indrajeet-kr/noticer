import XCTest
@testable import NoticerCore

/// Credit for help he gives on his own: a wearer action for a listed
/// need that is not open applies the self-notice step and records the
/// Tonight entry, speaks nothing, and debounces to one per 10 minutes.
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

    func testInterventionWithNoOpenNeedCreditsAndSpeaksNothing() throws {
        try setupSignalledNeeds()
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        let before = mastery(of: "take-baby")

        engine.handle(callID: call.id, verdict: wearerAction(.logWearerIntervention))

        XCTAssertEqual(events(.selfNoticedUnprompted).map(\.needID), ["take-baby"])
        XCTAssertEqual(mastery(of: "take-baby"), MasteryMath.applySelfNotice(before))
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertTrue(engine.cues.isEmpty)
    }

    func testResolvedAfterActionCreditsToo() throws {
        try setupSignalledNeeds()
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        let before = mastery(of: "take-baby")

        engine.handle(callID: call.id, verdict: wearerAction(.reportNeedResolved))

        XCTAssertEqual(events(.selfNoticedUnprompted).map(\.needID), ["take-baby"])
        XCTAssertEqual(mastery(of: "take-baby"), MasteryMath.applySelfNotice(before))
        XCTAssertTrue(engine.cues.isEmpty)
    }

    func testSecondActionWithinTenMinutesIsIgnored() throws {
        try setupSignalledNeeds()
        glancePair()
        let first = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: first.id, verdict: wearerAction(.logWearerIntervention))
        let credited = mastery(of: "take-baby")

        let second = try nextLatchCall()
        engine.handle(callID: second.id, verdict: wearerAction(.logWearerIntervention))

        XCTAssertEqual(events(.selfNoticedUnprompted).count, 1)
        XCTAssertEqual(mastery(of: "take-baby"), credited)
    }

    func testActionAfterTenMinutesCreditsAgain() throws {
        try setupSignalledNeeds()
        glancePair()
        let first = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: first.id, verdict: wearerAction(.logWearerIntervention))

        advance(EngineTuning.unpromptedDebounceSeconds)
        glancePair()
        let second = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: second.id, verdict: wearerAction(.logWearerIntervention))

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
