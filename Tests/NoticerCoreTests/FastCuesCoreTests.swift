import Foundation
import XCTest
@testable import NoticerCore

final class FastCuesCoreTests: EngineTestCase {

    // MARK: - Change 1: Dedupe & Rate Gates

    func testNoCallWithIdenticalStrip() throws {
        see([mom()], sharpness: 0.02, jpeg: 1)
        advance(5)
        see([mom()], sharpness: 0.03, jpeg: 2)
        let latchCall = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(latchCall.purpose, .latch)
        engine.handle(callID: latchCall.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])

        // Within the same open slot (< 4 s continuousPresenceKeyframeSeconds),
        // a sharper frame swaps openSlot via keepSharper without opening a new slot.
        advance(1)
        see([mom()], sharpness: 0.09, jpeg: 9, handsEdge: true)
        engine.tick()
        XCTAssertNil(engine.pendingModelCall, "keepSharper swap in the same slot must not issue a heartbeat")
        XCTAssertTrue(events(.skip).contains { ($0.detail ?? "").contains("duplicate-strip") })

        // Switch test: legacy mode (`dedupeAllPurposes: false`) treats the sharper swap as new.
        engine = try NeedEngine(
            clock: clock,
            needs: [Self.takeBaby()],
            latency: LatencyTuning(dedupeAllPurposes: false)
        )
        see([mom()], sharpness: 0.02, jpeg: 1)
        advance(5)
        see([mom()], sharpness: 0.03, jpeg: 2)
        let legacyLatch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: legacyLatch.id, verdict: latchVerdict("take-baby"))
        advance(1)
        see([mom()], sharpness: 0.09, jpeg: 9, handsEdge: true)
        XCTAssertNotNil(engine.pendingModelCall)
    }

    func testHeartbeatEventsAppliedPerReply() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(events(.needLatched).map(\.needID), ["take-baby"])

        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 3)
        let hb = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(hb.purpose, .heartbeat)
        let logCountBefore = engine.log.count
        engine.handle(callID: hb.id, verdict: noTransition("take-baby", sustained: true))
        XCTAssertGreaterThan(engine.log.count, logCountBefore)
        XCTAssertEqual(events(.stillOpen).last?.needID, "take-baby")
        XCTAssertNil(engine.pendingModelCall, "no follow-up call fires without a newer strip")
    }

    func testOneReplyNeverTriggersImmediateSecondCallOnSameStrip() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])

        // Advance past latchMinIntervalSeconds so the latch branch would otherwise be eligible,
        // emit one new slot for the heartbeat, then do a keepSharper swap in that same slot.
        advance(SessionLimits.latchMinIntervalSeconds)
        see([mom()], sharpness: 0.02, jpeg: 4)
        advance(0.5)
        see([mom()], sharpness: 0.08, jpeg: 5)
        let hb = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(hb.purpose, .heartbeat)

        engine.handle(callID: hb.id, verdict: noTransition("take-baby", sustained: true))
        XCTAssertNil(
            engine.pendingModelCall,
            "heartbeat reply with unchanged strip (except keepSharper) must not trigger an immediate latch call"
        )
    }

    func testLatchAndHeartbeatShareMinGap() throws {
        engine = try NeedEngine(
            clock: clock,
            needs: [Self.takeBaby(), Self.refillWater()],
            timing: .quick
        )
        see([mom()], jpeg: 1)
        advance(2)
        see([mom()], jpeg: 2)
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))

        // Under quick timing: glanceAbsentSeconds is 1 s, minCallGapSeconds is 2 s.
        // At +1.2 s a new slot opens, but min-gap suppresses the heartbeat.
        advance(1.2)
        see([mom()], jpeg: 3, handsEdge: true)
        XCTAssertNil(engine.pendingModelCall)
        XCTAssertTrue(events(.skip).contains { ($0.detail ?? "").contains("min-gap") })

        // At +2.0 s from the latch call, min-gap clears and the call issues.
        advance(0.8)
        see([mom()], jpeg: 4, handsEdge: true)
        XCTAssertEqual(engine.pendingModelCall?.purpose, .heartbeat)
    }

    // MARK: - Change 2: At Most 2 Calls In Flight & Out-of-Order Stale Drop

    func testStaleReplyDiscardedWhenNewerApplied() throws {
        see([mom()], jpeg: 1)
        advance(5)
        see([mom()], jpeg: 2)
        let first = try XCTUnwrap(engine.pendingModelCalls.first)
        XCTAssertEqual(engine.pendingModelCalls.count, 1)

        // Same slot does not allow a 2nd in-flight call.
        advance(0.5)
        see([mom()], sharpness: 0.09, jpeg: 3)
        XCTAssertEqual(engine.pendingModelCalls.count, 1)

        // A genuinely newer slot past latchMinIntervalSeconds allows a 2nd call in flight (max 2).
        advance(SessionLimits.latchMinIntervalSeconds)
        see([mom()], jpeg: 4)
        XCTAssertEqual(engine.pendingModelCalls.count, 2)
        let second = engine.pendingModelCalls[1]
        XCTAssertGreaterThan(second.issuedAt, first.issuedAt)

        // A 3rd newer slot is capped by maxInFlight = 2.
        advance(SessionLimits.latchMinIntervalSeconds)
        see([mom()], jpeg: 5)
        XCTAssertEqual(engine.pendingModelCalls.count, 2)

        // Newer reply arrives first and is applied.
        engine.handle(callID: second.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])

        // Older reply arrives last and is dropped as stale.
        engine.handle(callID: first.id, verdict: latchVerdict("refill-water"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertEqual(events(.staleReplyDropped).last?.detail, first.id)

        // Switch test: `concurrentInFlight: false` caps pendingModelCalls at 1.
        engine = try NeedEngine(
            clock: clock,
            needs: [Self.takeBaby()],
            latency: LatencyTuning(concurrentInFlight: false)
        )
        see([mom()], jpeg: 1)
        advance(5)
        see([mom()], jpeg: 2)
        XCTAssertEqual(engine.pendingModelCalls.count, 1)
        advance(5)
        see([mom()], jpeg: 3)
        XCTAssertEqual(engine.pendingModelCalls.count, 1)
    }

    // MARK: - Change 3: Smaller Payloads (Strip Keyframe Counts)

    func testSmallerPayloadsSwitchControlsStripKeyframeCount() throws {
        let water = Need(
            id: "water",
            authorText: "Keep water bottle on dining table",
            cueWording: "Maybe set water on the table?",
            visualCondition: "dining table visible with no water bottle",
            handledCondition: "water bottle on the dining table",
            selfNoticeSignal: "wearer_placing_water_bottle_on_table",
            priority: 0
        )
        engine = try NeedEngine(clock: clock, needs: [water])

        // Build 3 spaced keyframes.
        see([mom()], jpeg: 1)
        advance(5)
        see([mom()], jpeg: 2)
        // Drain initial 2-kf scouting call with no transition so we have 3 slots on the next one.
        let initial = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(initial.request.keyframes.count, 2)
        engine.handle(callID: initial.id, verdict: noTransition(nil, sustained: false))

        advance(SessionLimits.latchMinIntervalSeconds)
        see([mom()], jpeg: 3)
        let scouting = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(scouting.purpose, .latch)
        XCTAssertEqual(scouting.request.keyframes.count, 2, "scouting uses 2 keyframes")

        var latchV = latchVerdict("water")
        latchV.assessment.partnerInView = true
        engine.handle(callID: scouting.id, verdict: latchV)

        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 4)
        let hb = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(hb.purpose, .heartbeat)
        XCTAssertEqual(hb.request.keyframes.count, 2, "heartbeat uses 2 keyframes")
        engine.handle(callID: hb.id, verdict: noTransition("water", sustained: true))

        // Switch test: `smallerPayloads: false` sends 3 keyframes on scouting.
        engine = try NeedEngine(
            clock: clock,
            needs: [water],
            latency: LatencyTuning(smallerPayloads: false)
        )
        for step in 0..<3 {
            if step > 0 { advance(5) }
            see([mom()], jpeg: UInt8(step + 1))
            if step == 1, let c = engine.pendingModelCall {
                engine.handle(callID: c.id, verdict: noTransition(nil, sustained: false))
                advance(SessionLimits.latchMinIntervalSeconds)
            }
        }
        let legacyCall = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(legacyCall.request.keyframes.count, 3)
    }

    // MARK: - Change 4: Admission Floor

    func testQuickIdleAdmitsEvery2s() {
        var state = SignalGateState()
        let start = Self.origin
        let planeA = LumaPlane(width: 4, height: 4, samples: Array(repeating: 20, count: 16))
        let planeB = LumaPlane(width: 4, height: 4, samples: [
            20, 220, 20, 220,
            220, 20, 220, 20,
            20, 220, 20, 220,
            220, 20, 220, 20,
        ])
        let planeC = LumaPlane(width: 4, height: 4, samples: [
            30, 210, 30, 210,
            210, 30, 210, 30,
            30, 210, 30, 210,
            210, 30, 210, 30,
        ])

        // t=0: first informative frame admitted immediately.
        let d0 = SignalGate.evaluate(plane: planeB, at: start, needOpen: false, state: &state, timing: .quick)
        XCTAssertTrue(d0.passes)

        // t=2s (during 6s warmup and quick 2s idle interval): sharp frame admitted!
        let d2 = SignalGate.evaluate(
            plane: planeC,
            at: start.addingTimeInterval(2.0),
            needOpen: false,
            state: &state,
            timing: .quick
        )
        XCTAssertTrue(d2.passes)

        // Past the 6s warmup (at t=10s), quick idle still admits every 2s.
        let d10 = SignalGate.evaluate(
            plane: planeB,
            at: start.addingTimeInterval(10.0),
            needOpen: false,
            state: &state,
            timing: .quick
        )
        XCTAssertTrue(d10.passes)

        let d11 = SignalGate.evaluate(
            plane: planeC,
            at: start.addingTimeInterval(11.0),
            needOpen: false,
            state: &state,
            timing: .quick
        )
        XCTAssertFalse(d11.passes, "1s after admit (< 2s quick interval) without rising motion is held")

        let d12 = SignalGate.evaluate(
            plane: planeB,
            at: start.addingTimeInterval(12.0),
            needOpen: false,
            state: &state,
            timing: .quick
        )
        XCTAssertTrue(d12.passes, "2s after admit passes under quick idle interval")

        // Always-admit floor: flat uninformative frame is admitted once 2 * interval (4s) elapses.
        let d16Floor = SignalGate.evaluate(
            plane: planeA,
            at: start.addingTimeInterval(16.0),
            needOpen: false,
            state: &state,
            timing: .quick
        )
        XCTAssertTrue(d16Floor.passes, "always-admit floor admits after 2 * interval even on flat luma")
    }

    func testStandardAdmissionUnchanged() {
        let legacyLatency = LatencyTuning(admissionFloor: false)
        var stateA = SignalGateState()
        var stateB = SignalGateState()
        let plane1 = LumaPlane(width: 4, height: 4, samples: [
            10, 240, 10, 240,
            240, 10, 240, 10,
            10, 240, 10, 240,
            240, 10, 240, 10,
        ])
        let plane2 = LumaPlane(width: 4, height: 4, samples: [
            15, 235, 15, 235,
            235, 15, 235, 15,
            15, 235, 15, 235,
            235, 15, 235, 15,
        ])
        // After the 6s warmup window, standard idle interval is 8s.
        _ = SignalGate.evaluate(plane: plane1, at: Self.origin, needOpen: false, state: &stateA, timing: .standard, latency: .default)
        _ = SignalGate.evaluate(plane: plane1, at: Self.origin, needOpen: false, state: &stateB, timing: .standard, latency: legacyLatency)

        let t8 = Self.origin.addingTimeInterval(8.0)
        let a8 = SignalGate.evaluate(plane: plane2, at: t8, needOpen: false, state: &stateA, timing: .standard, latency: .default)
        let b8 = SignalGate.evaluate(plane: plane2, at: t8, needOpen: false, state: &stateB, timing: .standard, latency: legacyLatency)
        XCTAssertTrue(a8.passes)
        XCTAssertEqual(a8.passes, b8.passes)

        // At t=12s (4s after t=8, past 6s warmup, < 8s standard idle interval), held on both!
        let t12 = Self.origin.addingTimeInterval(12.0)
        let a12 = SignalGate.evaluate(plane: plane1, at: t12, needOpen: false, state: &stateA, timing: .standard, latency: .default)
        let b12 = SignalGate.evaluate(plane: plane1, at: t12, needOpen: false, state: &stateB, timing: .standard, latency: legacyLatency)
        XCTAssertFalse(a12.passes)
        XCTAssertFalse(b12.passes)
    }

    // MARK: - Change 6: Urgent Needs

    func testUrgentNeedCuesWithZeroHeadStart() throws {
        let glass = Need(
            id: "silver-glass-floor",
            authorText: "Take away the silver glass on the floor",
            cueWording: "Could you move that glass from the baby?",
            visualCondition: "silver glass sitting on the floor near baby",
            handledCondition: "floor near baby clear of the silver glass",
            selfNoticeSignal: "wearer_picking_up_glass_from_floor",
            priority: 0,
            isUrgent: true
        )
        engine = try NeedEngine(clock: clock, needs: [glass], timing: .quick)

        // Single keyframe issues a latch call when an urgent need is on the list.
        see([mom()], jpeg: 1)
        let latch = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(latch.request.keyframes.count, 1)

        // Latch with hands occupied: 0s head start, but still respects handsBusy!
        let busyLatch = ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: "silver-glass-floor",
                sustainedAcrossStrip: true,
                wearerHandsOccupied: true,
                partnerInView: true,
                wearerHandsVisible: true,
                confidence: 0.9
            )
        )
        engine.handle(callID: latch.id, verdict: busyLatch)
        XCTAssertEqual(engine.openNeedIDs, ["silver-glass-floor"])
        let open = try XCTUnwrap(engine.openNeeds.first)
        XCTAssertEqual(open.cueDeadline, open.latchedAt, "urgent need has 0s head start")
        XCTAssertTrue(engine.cues.isEmpty, "urgent need still defers while handsBusy is true")

        // Advance past staleEvidenceSeconds (15s quick) so evidence would be stale for non-urgent,
        // then clear handsBusy: cues immediately without requesting a stale-evidence recheck!
        advance(20)
        see([mom()], jpeg: 2)
        let hb = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(
            callID: hb.id,
            verdict: noTransition("silver-glass-floor", sustained: true, handsOccupied: false)
        )
        XCTAssertTrue(events(.recheckRequested).isEmpty, "urgent need skips stale-evidence recheck")
        XCTAssertEqual(engine.cues.map(\.needID), ["silver-glass-floor"])

        // Switch test: `urgentNeedsEnabled: false` restores normal 2-keyframe & head-start rules.
        engine = try NeedEngine(
            clock: clock,
            needs: [glass],
            timing: .quick,
            latency: LatencyTuning(urgentNeedsEnabled: false)
        )
        see([mom()], jpeg: 1)
        XCTAssertNil(engine.pendingModelCall)
        XCTAssertEqual(
            MasteryMath.headStartSeconds(
                for: glass,
                timing: .quick,
                latency: LatencyTuning(urgentNeedsEnabled: false)
            ),
            10
        )
    }

    // MARK: - Change 7 & Standard Invariant

    func testStandardTimingUnchanged() {
        let s = TimingProfile.standard
        XCTAssertEqual(s.latchMinIntervalSeconds, 10)
        XCTAssertEqual(s.latchMinKeyframes, 2)
        XCTAssertEqual(s.latchMinKeyframeSpacingSeconds, 4)
        XCTAssertEqual(s.heartbeatSeconds, 8)
        XCTAssertEqual(s.defaultHeadStartSeconds, 90)
        XCTAssertEqual(s.headStartCapSeconds, 120)
        XCTAssertEqual(s.cueRateLimitSeconds, 180)
        XCTAssertEqual(s.relatchCooldownSeconds, 300)
        XCTAssertEqual(s.staleEvidenceSeconds, 30)
        XCTAssertEqual(s.noPersonKeyframeCloseSeconds, 45)
        XCTAssertEqual(s.glanceAbsentSeconds, 2)
        XCTAssertEqual(s.continuousPresenceKeyframeSeconds, 4)
        XCTAssertEqual(s.keyframeBufferSeconds, 60)
        XCTAssertEqual(s.maxSessionSeconds, 1_800)
        XCTAssertEqual(s.idleAdmitIntervalSeconds, 8)
        XCTAssertEqual(s.minCallGapSeconds, 0)
        XCTAssertEqual(s.postCueNoPersonGraceSeconds, 0)
    }

    func testAdaptiveQuickHeadStartSwitch() {
        let need = Self.takeBaby()
        XCTAssertEqual(MasteryMath.headStartSeconds(for: need, timing: .quick, latency: .default), 10)
        XCTAssertEqual(
            MasteryMath.headStartSeconds(
                for: need,
                timing: .quick,
                latency: LatencyTuning(adaptiveQuickHeadStart: false)
            ),
            20
        )
    }

    // MARK: - Change 8 & 11a: Correct Credit & Out-of-View Hold

    func testWashingDishesSequenceGivesNoCredit() throws {
        let water = Need(
            id: "water",
            authorText: "Keep water bottle on dining table",
            cueWording: "Water on the table helps.",
            visualCondition: "dining table visible with no water bottle",
            handledCondition: "water bottle on the dining table",
            selfNoticeSignal: "wearer_placing_water_bottle_on_table",
            priority: 0
        )
        engine = try NeedEngine(clock: clock, needs: [water])

        // 1. Latch `water` (partner=false).
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        var v1 = latchVerdict("water")
        v1.assessment.partnerInView = false
        engine.handle(callID: latch.id, verdict: v1)
        XCTAssertEqual(engine.openNeedIDs, ["water"])

        // 2. `defer_cue_wearer_busy need=water action=wearer_washing_dishes`.
        advance(SessionLimits.heartbeatSeconds)
        see([], jpeg: 3, sceneActive: true)
        let hb1 = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(
            callID: hb1.id,
            verdict: ModelVerdict(
                finishReason: .toolCalls,
                tool: .deferCueWearerBusy,
                assessment: SceneAssessment(
                    needID: "water",
                    sustainedAcrossStrip: true,
                    wearerHandsOccupied: true,
                    partnerInView: false,
                    wearerHandsVisible: true,
                    actionCode: "wearer_washing_dishes"
                )
            )
        )
        XCTAssertNil(engine.openNeeds.first?.pendingWearerAction)

        // 3. `report_no_transition need="null" sustained=false`.
        advance(SessionLimits.heartbeatSeconds)
        see([], jpeg: 4, sceneActive: true)
        let hb2 = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: hb2.id, verdict: noTransition("null", sustained: false))

        XCTAssertTrue(events(.caughtHimself).isEmpty)
        XCTAssertEqual(mastery(of: "water").score, 0)
        XCTAssertEqual(engine.openNeedIDs, ["water"])
    }

    func testDeferNeverArmsCredit() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))

        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 3)
        let hb = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(
            callID: hb.id,
            verdict: ModelVerdict(
                finishReason: .toolCalls,
                tool: .deferCueWearerBusy,
                assessment: SceneAssessment(
                    needID: "take-baby",
                    sustainedAcrossStrip: true,
                    wearerHandsOccupied: true,
                    wearerHandsVisible: true,
                    actionCode: ActionCodeExamples.wearerHandsReceivingBaby
                )
            )
        )
        XCTAssertNil(engine.openNeeds.first?.pendingWearerAction)
    }

    func testLostSceneIsNotResolution() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))

        // Arm a valid matching intervention.
        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 3)
        let hb1 = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(
            callID: hb1.id,
            verdict: intervention(
                "take-baby",
                action: ActionCodeExamples.wearerHandsReceivingBaby,
                sustained: true
            )
        )
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, ActionCodeExamples.wearerHandsReceivingBaby)

        // Camera turns away: `report_no_transition` with need nil and sustained=false.
        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 4)
        let hb2 = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: hb2.id, verdict: noTransition(nil, sustained: false))

        XCTAssertTrue(events(.caughtHimself).isEmpty, "losing the scene must never credit caughtHimself")
        XCTAssertEqual(mastery(of: "take-baby").score, 0)
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testOutOfViewNullHoldsOpenNeed() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))
        var previousEvidence = try XCTUnwrap(engine.openNeeds.first).evidenceAt

        for turn in 1...3 {
            advance(SessionLimits.heartbeatSeconds)
            see([mom()], jpeg: UInt8(turn + 2))
            let hb = try XCTUnwrap(engine.pendingModelCall)
            engine.handle(callID: hb.id, verdict: noTransition(nil, sustained: nil))
            let open = try XCTUnwrap(engine.openNeeds.first)
            XCTAssertGreaterThan(open.evidenceAt, previousEvidence)
            XCTAssertFalse(open.awaitingRecheck)
            previousEvidence = open.evidenceAt
        }

        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        let outOfViewEvents = events(.stillOpen).filter { $0.detail == "out-of-view" }
        XCTAssertEqual(outOfViewEvents.count, 3)

        // Also verify on `.recheck`: two out-of-view null replies do NOT accumulate two strikes or close the need.
        let open = try XCTUnwrap(engine.openNeeds.first)
        engine.noteSameChore("sink")
        advance(to: open.cueDeadline)
        engine.tick()
        let recheck1 = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(recheck1.purpose, .recheck)
        engine.handle(callID: recheck1.id, verdict: noTransition(nil, sustained: nil))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"], "first out-of-view recheck holds without strike")

        engine.noteSameChore("sink")
        advance(SessionLimits.staleEvidenceSeconds + 1)
        see([mom()], jpeg: 99)
        let recheck2 = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: recheck2.id, verdict: noTransition(nil, sustained: nil))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"], "second out-of-view hold still adds no recheck strike")
    }

    func testPartnerResolutionOnlyViaResolvedTool() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))

        // `resolvedByPartner` on `report_no_transition` or `defer_cue_wearer_busy` is ignored.
        for (idx, wrongTool) in [ToolName.reportNoTransition, .deferCueWearerBusy].enumerated() {
            advance(SessionLimits.heartbeatSeconds)
            see([mom()], jpeg: UInt8(idx + 3))
            let hb = try XCTUnwrap(engine.pendingModelCall)
            engine.handle(callID: hb.id, verdict: partnerResolved("take-baby", tool: wrongTool))
            XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        }

        // `report_need_resolved` with `resolved_by=other_adult` closes cleanly without credit.
        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 10)
        let hbResolved = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(
            callID: hbResolved.id,
            verdict: ModelVerdict(
                finishReason: .toolCalls,
                tool: .reportNeedResolved,
                assessment: SceneAssessment(
                    needID: "take-baby",
                    sustainedAcrossStrip: false,
                    resolution: .resolvedByPartner
                )
            )
        )
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(mastery(of: "take-baby").score, 0)
        XCTAssertEqual(events(.resolvedByPartner).count, 1)
    }

    func testMatchingSignalCredits() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))

        // Unrelated wearer_* code on log_wearer_intervention is rejected!
        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 3)
        let wrong = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: wrong.id, verdict: intervention("take-baby", action: "wearer_washing_dishes", sustained: true))
        XCTAssertNil(engine.openNeeds.first?.pendingWearerAction)
        XCTAssertEqual(events(.actionRejected).last?.detail, "unrelated-wearer-action")

        // Exact `selfNoticeSignal` arms and subsequent clear intervention credits.
        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 4)
        let armCall = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(
            callID: armCall.id,
            verdict: intervention("take-baby", action: ActionCodeExamples.wearerHandsReceivingBaby, sustained: true)
        )
        XCTAssertEqual(engine.openNeeds.first?.pendingWearerAction, ActionCodeExamples.wearerHandsReceivingBaby)

        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 5)
        let clearCall = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(
            callID: clearCall.id,
            verdict: intervention("take-baby", action: ActionCodeExamples.wearerHandsReceivingBaby, sustained: false)
        )
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(mastery(of: "take-baby").score, 0.25)
        XCTAssertEqual(events(.caughtHimself).count, 1)
    }

    // MARK: - Change 9: Polarity, Migration, Resolution, Post-Cue Grace

    func testResolutionSignalNeverUsesVisualCondition() {
        let onlyVisual = Need(
            id: "couch-water",
            authorText: "sitting on couch pass me water",
            cueWording: "Maybe bring her some water?",
            visualCondition: "partner sitting on couch with no water within reach",
            priority: 0
        )
        let signal = NeedEngine<ManualClock>.resolutionSignal(for: onlyVisual)
        XCTAssertTrue(signal.hasPrefix("unspecified"))
        XCTAssertFalse(signal.contains("no water within reach"))

        // Switch test: legacy `polarityResolution: false` included `visualCondition`.
        let legacy = NeedEngine<ManualClock>.resolutionSignal(
            for: onlyVisual,
            latency: LatencyTuning(polarityResolution: false)
        )
        XCTAssertEqual(legacy, "partner sitting on couch with no water within reach")
    }

    func testResolutionFiresWhenHandledVisualObserved() throws {
        let couchWater = Need(
            id: "couch-water",
            authorText: "Bring her water when she's on the couch",
            cueWording: "Grab her a water refill?",
            visualCondition: "partner on couch with no water within reach",
            handledCondition: "glass of water within her reach",
            selfNoticeSignal: "wearer_handing_water_to_partner",
            priority: 0
        )
        engine = try NeedEngine(clock: clock, needs: [couchWater])

        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("couch-water"))
        XCTAssertEqual(engine.openNeedIDs, ["couch-water"])

        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 3)
        let hb = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(hb.request.openNeeds.first?.problemCondition, "partner on couch with no water within reach")
        XCTAssertTrue(hb.request.openNeeds.first?.resolutionSignal.contains("glass of water within her reach") == true)

        engine.handle(
            callID: hb.id,
            verdict: ModelVerdict(
                finishReason: .toolCalls,
                tool: .reportNeedResolved,
                assessment: SceneAssessment(
                    needID: "couch-water",
                    sustainedAcrossStrip: false,
                    partnerInView: true,
                    wearerHandsVisible: true,
                    resolution: .caughtHimself,
                    actionCode: "wearer_handing_water_to_partner"
                )
            )
        )
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.caughtHimself).map(\.needID), ["couch-water"])
        XCTAssertEqual(mastery(of: "couch-water").score, 0.25)
    }

    func testMigrationAddsHandledFieldsToDefaults() {
        let saved = [
            Need(
                id: "water",
                authorText: "Keep water bottle on dining table",
                cueWording: "Water on the table helps.",
                visualCondition: "dining table visible with no water bottle",
                priority: 0
            ),
            Need(
                id: "take-baby",
                authorText: "eating one-handed, take the baby",
                cueWording: "Maybe offer to take the baby?",
                visualCondition: "partner eating while holding the baby",
                priority: 1
            ),
            Need(
                id: "burp",
                authorText: "bring a burp cloth",
                cueWording: "Hand her a burp cloth?",
                priority: 2
            ),
            Need(
                id: "mystery-chore",
                authorText: "adjust the hallway thermostat",
                cueWording: "Check the hallway.",
                priority: 3
            ),
        ]

        let result = NeedPolarityMigration.migrate(saved)
        XCTAssertNotNil(result.needs[0].handledCondition)
        XCTAssertEqual(result.needs[0].selfNoticeSignal, "wearer_placing_water_bottle_on_table")
        XCTAssertNotNil(result.needs[1].handledCondition)
        XCTAssertEqual(result.needs[1].selfNoticeSignal, ActionCodeExamples.wearerHandsReceivingBaby)
        XCTAssertNotNil(result.needs[2].handledCondition)
        XCTAssertEqual(result.needs[2].selfNoticeSignal, "wearer_bringing_burp_cloth")
        XCTAssertNil(result.needs[3].handledCondition)
        XCTAssertEqual(result.needsPolarityReviewIDs, ["mystery-chore"])
    }

    func testOpenNeedContextOnHeartbeat() throws {
        let couchWater = Need(
            id: "couch-water",
            authorText: "Bring her water when she's on the couch",
            cueWording: "Grab her a water refill?",
            visualCondition: "partner on couch with no water within reach",
            handledCondition: "glass of water within her reach",
            selfNoticeSignal: "wearer_handing_water_to_partner",
            priority: 0
        )
        engine = try NeedEngine(clock: clock, needs: [couchWater])
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(latch.request.purpose, .latch)
        engine.handle(callID: latch.id, verdict: latchVerdict("couch-water"))

        advance(SessionLimits.heartbeatSeconds)
        see([mom()], jpeg: 3)
        let hb = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(hb.purpose, .heartbeat)
        XCTAssertEqual(hb.request.purpose, .heartbeat)
        let ctx = try XCTUnwrap(hb.request.openNeeds.first)
        XCTAssertEqual(ctx.needID, "couch-water")
        XCTAssertEqual(ctx.problemCondition, "partner on couch with no water within reach")
        XCTAssertEqual(ctx.resolutionSignal, "glass of water within her reach; wearer_handing_water_to_partner")
    }

    func testPostCueNoPersonGraceSwitch() throws {
        engine = try NeedEngine(clock: clock, needs: [Self.takeBaby()], timing: .quick)
        see([mom()], jpeg: 1)
        advance(2)
        see([mom()], jpeg: 2)
        let latch = try XCTUnwrap(engine.pendingModelCall)
        var v = latchVerdict("take-baby")
        v.assessment.partnerInView = true
        engine.handle(callID: latch.id, verdict: v)

        let open = try XCTUnwrap(engine.openNeeds.first)
        advance(to: open.cueDeadline)
        engine.tick()
        XCTAssertEqual(engine.cues.count, 1)

        // In quick timing, `noPersonKeyframeCloseSeconds` is 20s, but `postCueNoPersonGraceSeconds`
        // keeps a cued need open for 30s after the cue!
        advance(25)
        engine.tick()
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"], "30s post-cue grace protects the cued need at +25s")

        advance(6)
        engine.tick()
        XCTAssertTrue(engine.openNeedIDs.isEmpty, "closes after both 20s no-person and 30s post-cue grace elapse")

        // Switch test: `postCueNoPersonGrace: false` closes at +20s after lastPersonSeen.
        engine = try NeedEngine(
            clock: clock,
            needs: [Self.takeBaby()],
            timing: .quick,
            latency: LatencyTuning(postCueNoPersonGrace: false)
        )
        see([mom()], jpeg: 1)
        advance(2)
        see([mom()], jpeg: 2)
        let gLatch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: gLatch.id, verdict: v)
        advance(10) // cue fires at +10s (10s after lastPersonSeen)
        engine.tick()
        XCTAssertEqual(engine.cues.count, 1)
        advance(11) // 21s after lastPersonSeen (> 20s noPersonKeyframeCloseSeconds), only 11s after cue!
        engine.tick()
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
    }

    // MARK: - Live Glasses Real-World Edge Cases

    func testKeepSharperAtSlotEndDoesNotStarveTwoSecondLatchSpacing() throws {
        // Real glasses send `people: []` with `sceneActive: true`. As the wearer steadies
        // their head at +1.5s, `keepSharper` replaces the 0.0s slot's JPEG and `capturedAt`.
        // When the next slot opens at +2.0s, spacing must still read 2.0s from `slotStartedAt`.
        engine = try NeedEngine(clock: clock, needs: [Self.takeBaby()], timing: .quick)
        see([], sharpness: 0.02, jpeg: 1, sceneActive: true)
        advance(0.8)
        see([], sharpness: 0.04, jpeg: 2, sceneActive: true)
        advance(0.7) // t = 1.5s: sharper frame inside slot 1
        see([], sharpness: 0.08, jpeg: 3, sceneActive: true)
        XCTAssertNil(engine.pendingModelCall)

        advance(0.5) // t = 2.0s: slot 2 opens
        see([], sharpness: 0.05, jpeg: 4, sceneActive: true)
        let latch = try XCTUnwrap(
            engine.pendingModelCall,
            "slot 2 at +2.0s must pair with slot 1 (started at 0.0s) despite keepSharper at +1.5s"
        )
        XCTAssertEqual(latch.request.keyframes.count, 2)
    }

    func testInconclusiveRecheckUnblocksWhenSustainedReturns() throws {
        // If a stale-evidence recheck fires while the wearer glanced away (`sustained = nil`),
        // `inconclusiveHold` pauses the cue, then must clear as soon as a later heartbeat
        // confirms the need is visibly sustained again.
        engine = try NeedEngine(clock: clock, needs: [Self.takeBaby(dwell: 20)], timing: .quick)
        see([mom()], jpeg: 1)
        advance(2)
        see([mom()], jpeg: 2)
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: latchVerdict("take-baby"))

        engine.noteSameChore("sink")
        let open = try XCTUnwrap(engine.openNeeds.first)
        advance(to: open.cueDeadline) // +20s > 15s staleEvidenceSeconds -> triggers recheck
        engine.tick()
        let recheck = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(recheck.purpose, .recheck)

        // Wearer was facing the sink during recheck -> inconclusive (`sustained: nil`).
        engine.handle(callID: recheck.id, verdict: noTransition("null", sustained: nil))
        XCTAssertTrue(engine.cues.isEmpty, "inconclusive recheck holds the cue while facing away")

        // Wearer turns back at +8s and heartbeat sees the unmet need (`sustained: true`) -> cues!
        advance(8)
        see([mom()], jpeg: 3)
        let hb = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: hb.id, verdict: noTransition("take-baby", sustained: true))
        XCTAssertEqual(engine.cues.map(\.needID), ["take-baby"])
    }

    func testEmptyRoomIdleWatchCapsAtSixCallsPerMinute() throws {
        // Real glasses (`people: []`) staring at an empty room for 60s after warmup
        // must stay <= 6 calls/min when no person or activity edge occurs.
        engine = try NeedEngine(clock: clock, needs: [Self.takeBaby()], timing: .quick)
        var gateState = SignalGateState()
        let plane = LumaPlane(width: 8, height: 8, samples: Array(repeating: 120, count: 64))
        for second in 0...66 {
            if second > 0 { advance(1) }
            let now = clock.now()
            let dec = SignalGate.evaluate(
                plane: plane,
                at: now,
                needOpen: false,
                state: &gateState,
                timing: .quick
            )
            let snap = FrameGateSnapshot(
                capturedAt: now,
                people: [],
                wearerHandsVisible: false,
                handGateRisingEdge: false,
                motionScore: dec.motionScore,
                sharpness: 0.04,
                sceneActive: dec.sceneActive,
                activityEdge: dec.activityEdge
            )
            engine.ingest(
                frame: CameraFrame(capturedAt: now, jpegData: Data([UInt8(second % 250)]), width: 8, height: 8),
                gate: snap,
                sharpness: 0.04
            )
            if let call = engine.pendingModelCall {
                engine.handle(
                    callID: call.id,
                    verdict: ModelVerdict(
                        finishReason: .toolCalls,
                        tool: .reportNoTransition,
                        assessment: SceneAssessment(
                            needID: nil,
                            sustainedAcrossStrip: false,
                            wearerHandsOccupied: false,
                            partnerInView: false
                        )
                    )
                )
            }
        }
        let steadyCallsPerMin = engine.callsInLastMinute()
        XCTAssertLessThanOrEqual(steadyCallsPerMin, 6, "empty-room idle watch (\(steadyCallsPerMin)/min) must be <= 6/min")
    }
}
