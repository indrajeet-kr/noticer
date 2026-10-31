import XCTest
@testable import NoticerCore

final class QuickTimingTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private var clock: ManualClock!
    private var engine: NeedEngine<ManualClock>!

    override func setUpWithError() throws {
        try super.setUpWithError()
        clock = ManualClock(now: origin)
        engine = try NeedEngine(
            clock: clock,
            needs: [EngineTestCase.takeBaby(), EngineTestCase.refillWater()],
            timing: .quick
        )
    }

    func testStandardProfileKeepsTodaysLimits() {
        let timing = TimingProfile.standard
        XCTAssertEqual(timing.latchMinIntervalSeconds, SessionLimits.latchMinIntervalSeconds)
        XCTAssertEqual(timing.latchMinKeyframes, SessionLimits.latchMinKeyframes)
        XCTAssertEqual(timing.latchMinKeyframeSpacingSeconds, SessionLimits.latchMinKeyframeSpacingSeconds)
        XCTAssertEqual(timing.heartbeatSeconds, SessionLimits.heartbeatSeconds)
        XCTAssertEqual(timing.defaultHeadStartSeconds, SessionLimits.defaultHeadStartSeconds)
        XCTAssertEqual(timing.headStartCapSeconds, SessionLimits.headStartCapSeconds)
        XCTAssertEqual(timing.cueRateLimitSeconds, SessionLimits.cueRateLimitSeconds)
        XCTAssertEqual(timing.relatchCooldownSeconds, SessionLimits.relatchCooldownSeconds)
        XCTAssertEqual(timing.staleEvidenceSeconds, SessionLimits.staleEvidenceSeconds)
        XCTAssertEqual(timing.noPersonKeyframeCloseSeconds, SessionLimits.noPersonKeyframeCloseSeconds)
        XCTAssertEqual(timing.glanceAbsentSeconds, SessionLimits.glanceAbsentSeconds)
        XCTAssertEqual(timing.continuousPresenceKeyframeSeconds, SessionLimits.continuousPresenceKeyframeSeconds)
        XCTAssertEqual(timing.keyframeBufferSeconds, SessionLimits.keyframeBufferSeconds)
        XCTAssertEqual(timing.maxSessionSeconds, SessionLimits.maxSessionSeconds)
        XCTAssertEqual(timing.name, "standard")
    }

    func testQuickProfileUsesTheShortWaits() {
        let timing = TimingProfile.quick
        XCTAssertEqual(timing.latchMinIntervalSeconds, 4)
        XCTAssertEqual(timing.latchMinKeyframes, 2)
        XCTAssertEqual(timing.latchMinKeyframeSpacingSeconds, 2)
        XCTAssertEqual(timing.heartbeatSeconds, 8)
        XCTAssertEqual(timing.defaultHeadStartSeconds, 20)
        XCTAssertEqual(timing.headStartCapSeconds, 40)
        XCTAssertEqual(timing.cueRateLimitSeconds, 30)
        XCTAssertEqual(timing.relatchCooldownSeconds, 60)
        XCTAssertEqual(timing.staleEvidenceSeconds, 15)
        XCTAssertEqual(timing.noPersonKeyframeCloseSeconds, 20)
        XCTAssertEqual(timing.glanceAbsentSeconds, 1)
        XCTAssertEqual(timing.continuousPresenceKeyframeSeconds, 2)
        XCTAssertEqual(timing.keyframeBufferSeconds, SessionLimits.keyframeBufferSeconds)
        XCTAssertEqual(timing.maxSessionSeconds, SessionLimits.maxSessionSeconds)
        XCTAssertEqual(CueFadeSpec.headStartMasteryCoefficient, 2)
        XCTAssertEqual(SessionLimits.maxModelCallsPerSession, 300)
    }

    func testAVisibleNeedLatchesWithinSixSeconds() throws {
        see([mom()])
        XCTAssertNil(engine.pendingModelCall)
        advance(2)
        see([mom()])
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .latch)
        XCTAssertLessThanOrEqual(clock.now().timeIntervalSince(origin), 6)
        engine.handle(callID: call.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testTheCueWaitsUntilTheTwentySecondHeadStart() throws {
        try latch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        XCTAssertEqual(open.cueDeadline.timeIntervalSince(open.latchedAt), 20)

        try refresh(before: open.cueDeadline, lead: 10)
        advance(to: open.cueDeadline.addingTimeInterval(-1))
        engine.tick()
        XCTAssertTrue(engine.cues.isEmpty)

        advance(to: open.cueDeadline)
        engine.tick()
        let cue = try XCTUnwrap(engine.cues.first)
        XCTAssertEqual(cue.needID, "take-baby")
        XCTAssertEqual(cue.createdAt, open.cueDeadline)
        XCTAssertEqual(cue.createdAt.timeIntervalSince(open.latchedAt), 20)
    }

    func testMasteryStretchesTheHeadStartToTheFortySecondCap() throws {
        let practiced = MasteryState(score: 1, consecutiveSelfNotices: 0, consecutiveMisses: 0)
        try engine.setNeeds([EngineTestCase.takeBaby(mastery: practiced)])
        try latch("take-baby")
        let open = try XCTUnwrap(engine.openNeeds.first)
        // 20 * (1 + 2 * 1) = 60, then the 40 s cap.
        XCTAssertEqual(open.cueDeadline.timeIntervalSince(open.latchedAt), 40)
        XCTAssertEqual(open.hardCapAt.timeIntervalSince(open.latchedAt), 40)
    }

    func testTheSecondCueWaitsOutTheThirtySecondRateLimit() throws {
        try engine.setNeeds([
            EngineTestCase.need(id: "water", priority: 5),
            EngineTestCase.need(id: "baby", priority: 0, dwell: 14),
        ])
        try latch("water")
        advance(4)
        try latch("baby")
        let baby = try XCTUnwrap(engine.openNeeds.first { $0.needID == "baby" })
        let water = try XCTUnwrap(engine.openNeeds.first { $0.needID == "water" })
        XCTAssertEqual(baby.cueDeadline, water.cueDeadline)

        try refresh(before: water.cueDeadline, lead: 10)
        advance(to: water.cueDeadline)
        engine.tick()
        XCTAssertEqual(engine.cues.map(\.needID), ["baby"])
        XCTAssertEqual(engine.openNeedIDs, ["water", "baby"], "the cued need stays open for a resolution")

        let babyCue = try XCTUnwrap(engine.cues.first)
        engine.noteSameChore("sink")
        advance(to: babyCue.createdAt.addingTimeInterval(18))
        see([mom()])
        if let call = engine.pendingModelCall {
            engine.handle(callID: call.id, verdict: noTransition("water"))
        }
        engine.noteSameChore("sink")

        advance(to: babyCue.createdAt.addingTimeInterval(29))
        engine.tick()
        XCTAssertEqual(engine.cues.map(\.needID), ["baby"])

        advance(to: babyCue.createdAt.addingTimeInterval(30))
        engine.tick()
        XCTAssertEqual(engine.cues.map(\.needID), ["baby", "water"])
        let waterCue = try XCTUnwrap(engine.cues.last)
        XCTAssertEqual(waterCue.createdAt.timeIntervalSince(babyCue.createdAt), 30, accuracy: 0.001)
    }

    private func mom() -> ObservedPerson {
        ObservedPerson(
            boundingBox: NormalizedRect(x: 0.1, y: 0.1, width: 0.30, height: 0.70),
            aspectRatio: 0.30 / 0.70
        )
    }

    private func advance(_ seconds: TimeInterval) {
        clock.advance(by: seconds)
    }

    private func advance(to date: Date) {
        let delta = date.timeIntervalSince(clock.now())
        if delta > 0 { clock.advance(by: delta) }
    }

    private func see(_ people: [ObservedPerson]) {
        let now = clock.now()
        let frame = CameraFrame(capturedAt: now, jpegData: Data([1]), width: 8, height: 8)
        let gate = FrameGateSnapshot(
            capturedAt: now,
            people: people,
            wearerHandsVisible: false,
            handGateRisingEdge: false,
            sharpness: nil,
            sceneActive: false,
            activityEdge: false
        )
        engine.ingest(frame: frame, gate: gate)
    }

    /// Two person frames 2 s apart. That is enough to latch under quick timing.
    private func glancePair() {
        see([mom()])
        advance(2)
        see([mom()])
    }

    private func latch(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
        XCTAssertTrue(engine.openNeedIDs.contains(id))
    }

    private func refresh(before date: Date, lead: TimeInterval) throws {
        advance(to: date.addingTimeInterval(-lead))
        see([mom()])
        if let call = engine.pendingModelCall {
            engine.handle(callID: call.id, verdict: noTransition())
        }
    }

    private func latchVerdict(_ id: String) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: id,
                sustainedAcrossStrip: true,
                partnerStateEvidence: ["eating_one_handed"],
                wearerHandsOccupied: false,
                confidence: 0.2
            )
        )
    }

    private func noTransition(_ id: String? = nil) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNoTransition,
            assessment: SceneAssessment(needID: id, sustainedAcrossStrip: true)
        )
    }
}
