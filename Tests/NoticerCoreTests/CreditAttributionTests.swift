import XCTest
@testable import NoticerCore

/// Each helpful action credits once, to the right person. Help after a
/// cue earns zero self-notice increment; unprompted means outside any
/// episode; a started action credits only on completion. The debug
/// assert in `handle` (at most one mastery step per verdict) runs on
/// every one of these drives: a double count would crash, not just fail.
final class CreditAttributionTests: EngineTestCase {
    private var signal: String { ActionCodeExamples.wearerHandsReceivingBaby }

    private func resolved(
        _ resolution: Resolution,
        action: String? = nil,
        confidence: Double? = 0.9,
        partnerInView: Bool? = nil
    ) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNeedResolved,
            assessment: SceneAssessment(
                needID: "take-baby",
                sustainedAcrossStrip: false,
                partnerInView: partnerInView,
                resolution: resolution,
                actionCode: action,
                confidence: confidence
            )
        )
    }

    private func intervention(sustained: Bool? = nil, action: String? = nil) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .logWearerIntervention,
            assessment: SceneAssessment(
                needID: "take-baby",
                sustainedAcrossStrip: sustained,
                actionCode: action ?? signal,
                confidence: 0.8
            )
        )
    }

    private func urgentSeededNeeds(mastery: MasteryState) throws {
        var urgent = Self.takeBaby(mastery: mastery, selfNotice: signal)
        urgent.isUrgent = true
        try engine.setNeeds([urgent, Self.refillWater()])
    }

    private func heartbeat() throws -> PendingModelCall {
        advance(SessionLimits.heartbeatSeconds + 1)
        see([mom()])
        return try XCTUnwrap(engine.pendingModelCall)
    }

    private func nextIdleCall() throws -> PendingModelCall {
        advance(SessionLimits.latchMinIntervalSeconds + 1)
        see([mom()], handsEdge: true)
        return try XCTUnwrap(engine.pendingModelCall)
    }

    // MARK: - The double-credit bug

    func testAfterCueResolutionCreditsNothingUnprompted() throws {
        try urgentSeededNeeds(mastery: MasteryState(score: 0.5, consecutiveSelfNotices: 0, consecutiveMisses: 0))
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(events(.cueFired).map(\.needID), ["take-baby"])
        let masteryAfterCue = mastery(of: "take-baby")

        let close = try heartbeat()
        engine.handle(callID: close.id, verdict: resolved(.caughtHimself, action: signal))

        let catches = events(.caughtHimself)
        XCTAssertEqual(catches.count, 1)
        XCTAssertEqual(catches.first?.detail, "after-cue")
        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), masteryAfterCue)
        XCTAssertEqual(
            events(.unpromptedSkipped).map(\.detail),
            ["reason=same-verdict-close"]
        )
        let cueEpisode = events(.cueFired).first?.episodeID
        XCTAssertNotNil(cueEpisode)
        XCTAssertEqual(catches.first?.episodeID, cueEpisode, "the cue and its catch share the episode")
    }

    func testStrictPendingAfterCueCreditsNothing() throws {
        try urgentSeededNeeds(mastery: .initial)
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))
        let masteryAfterCue = mastery(of: "take-baby")

        let arm = try heartbeat()
        engine.handle(callID: arm.id, verdict: intervention())
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, signal)
        let clear = try heartbeat()
        engine.handle(callID: clear.id, verdict: intervention(sustained: false))

        XCTAssertEqual(events(.caughtHimself).map(\.detail), ["after-cue"])
        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), masteryAfterCue)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
    }

    func testLegacyPendingAfterCueCreditsNothing() throws {
        engine = try NeedEngine(
            clock: clock,
            needs: [Self.takeBaby(selfNotice: signal), Self.refillWater()],
            latency: LatencyTuning(strictCredit: false)
        )
        var urgent = Self.takeBaby(selfNotice: signal)
        urgent.isUrgent = true
        try engine.setNeeds([urgent, Self.refillWater()])
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))
        let masteryAfterCue = mastery(of: "take-baby")

        let arm = try heartbeat()
        engine.handle(callID: arm.id, verdict: intervention())
        let clear = try heartbeat()
        engine.handle(callID: clear.id, verdict: intervention(sustained: false))

        XCTAssertEqual(events(.caughtHimself).map(\.detail), ["after-cue"])
        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), masteryAfterCue)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
    }

    // MARK: - Before-cue credit

    func testResolvedBeforeCueStepsOnce() throws {
        try engine.setNeeds([Self.takeBaby(dwell: 30, selfNotice: signal), Self.refillWater()])
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))

        let close = try heartbeat()
        engine.handle(callID: close.id, verdict: resolved(.caughtHimself, action: signal))

        XCTAssertEqual(events(.caughtHimself).map(\.detail), ["before-cue"])
        XCTAssertEqual(mastery(of: "take-baby"), MasteryMath.applySelfNotice(.initial))
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
    }

    func testStrictPendingBeforeCueStepsOnce() throws {
        try engine.setNeeds([Self.takeBaby(dwell: 30, selfNotice: signal), Self.refillWater()])
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))

        let arm = try heartbeat()
        engine.handle(callID: arm.id, verdict: intervention())
        let clear = try heartbeat()
        engine.handle(callID: clear.id, verdict: intervention(sustained: false))

        XCTAssertEqual(events(.caughtHimself).map(\.detail), [signal])
        XCTAssertEqual(mastery(of: "take-baby"), MasteryMath.applySelfNotice(.initial))
    }

    func testLegacyPendingBeforeCueStepsOnce() throws {
        engine = try NeedEngine(
            clock: clock,
            needs: [Self.takeBaby(dwell: 30, selfNotice: signal), Self.refillWater()],
            latency: LatencyTuning(strictCredit: false)
        )
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))

        let arm = try heartbeat()
        engine.handle(callID: arm.id, verdict: intervention())
        let clear = try heartbeat()
        engine.handle(callID: clear.id, verdict: intervention(sustained: false))

        XCTAssertEqual(events(.caughtHimself).map(\.detail), [signal])
        XCTAssertEqual(mastery(of: "take-baby"), MasteryMath.applySelfNotice(.initial))
    }

    // MARK: - Unprompted start and completion

    func testInterventionAloneArmsWithoutCredit() throws {
        try engine.setNeeds([Self.takeBaby(selfNotice: signal), Self.refillWater()])
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(callID: call.id, verdict: intervention())

        XCTAssertEqual(events(.unpromptedStarted).map(\.needID), ["take-baby"])
        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), .initial)
    }

    func testWearerCompletionWithinWindowCreditsExactlyOnce() throws {
        try engine.setNeeds([Self.takeBaby(selfNotice: signal), Self.refillWater()])
        glancePair()
        let start = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: start.id, verdict: intervention())

        let finish = try nextIdleCall()
        engine.handle(callID: finish.id, verdict: resolved(.caughtHimself, action: signal, confidence: 0.8))

        let credits = events(.selfNoticedUnprompted)
        XCTAssertEqual(credits.map(\.needID), ["take-baby"])
        XCTAssertNil(credits.first?.episodeID, "an unprompted completion has no episode")
        XCTAssertEqual(mastery(of: "take-baby"), MasteryMath.applySelfNotice(.initial))
        XCTAssertTrue(engine.cues.isEmpty)
    }

    func testClosedEpisodeThenOwnActionEightMinutesLaterCredits() throws {
        try urgentSeededNeeds(mastery: .initial)
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))
        let close = try heartbeat()
        engine.handle(callID: close.id, verdict: resolved(.caughtHimself, action: signal))
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        let afterEpisode = mastery(of: "take-baby")

        advance(8 * 60)
        glancePair()
        let start = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: start.id, verdict: intervention())
        let finish = try nextIdleCall()
        engine.handle(callID: finish.id, verdict: resolved(.caughtHimself, action: signal, confidence: 0.8))

        XCTAssertEqual(events(.selfNoticedUnprompted).count, 1)
        XCTAssertEqual(mastery(of: "take-baby"), MasteryMath.applySelfNotice(afterEpisode))
    }

    func testPartialResultUntilWindowEndExpiresWithoutCredit() throws {
        try engine.setNeeds([Self.takeBaby(selfNotice: signal), Self.refillWater()])
        glancePair()
        let start = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: start.id, verdict: intervention())

        let partial = try nextIdleCall()
        engine.handle(callID: partial.id, verdict: noTransition())
        advance(EngineTuning.unpromptedCompleteWindowSeconds)
        engine.tick()

        XCTAssertEqual(events(.unpromptedExpired).map(\.detail), ["reason=not-completed"])
        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), .initial)
    }

    // MARK: - Other adult

    func testOtherAdultInsideEpisodeClosesWithoutCredit() throws {
        try engine.setNeeds([Self.takeBaby(dwell: 30, selfNotice: signal), Self.refillWater()])
        let before = mastery(of: "take-baby")
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))

        let close = try heartbeat()
        engine.handle(callID: close.id, verdict: resolved(.resolvedByPartner, partnerInView: false))

        XCTAssertEqual(events(.resolvedByOther).map(\.needID), ["take-baby"])
        XCTAssertTrue(events(.caughtHimself).isEmpty)
        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), before)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
    }

    func testOtherAdultOutsideEpisodeClearsTheStartWithoutCredit() throws {
        try engine.setNeeds([Self.takeBaby(selfNotice: signal), Self.refillWater()])
        glancePair()
        let start = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: start.id, verdict: intervention())

        let hers = try nextIdleCall()
        engine.handle(callID: hers.id, verdict: resolved(.resolvedByPartner, confidence: 0.9))
        XCTAssertEqual(events(.resolvedByOther).map(\.detail), ["no-episode"])

        // The start is gone: a later wearer resolution cannot complete it.
        let late = try nextIdleCall()
        engine.handle(callID: late.id, verdict: resolved(.caughtHimself, action: signal, confidence: 0.9))

        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty)
        XCTAssertEqual(mastery(of: "take-baby"), .initial)
    }
}
