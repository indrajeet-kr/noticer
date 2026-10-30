import XCTest
@testable import NoticerCore

final class SignalGateTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testIdenticalFramesHaveNoMotionAndAFlatFrameIsNotSharp() {
        let flat = plane(fill: 40)
        let reading = SignalGate.measure(current: flat, previous: flat)
        XCTAssertEqual(reading.motionScore, 0, accuracy: 0.000_001)
        XCTAssertEqual(reading.sharpness, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(SignalGate.laplacianVariance(checkerboard()), SignalGateTuning.flatSharpness)
    }

    func testAFullSwingIsMotionOfOne() {
        let black = plane(fill: 0)
        let white = plane(fill: 255)
        XCTAssertEqual(SignalGate.motionScore(current: white, previous: black), 1, accuracy: 0.000_001)
    }

    func testIdleAdmitsAGlanceAndASlowSampleButNotEveryChangedFrame() {
        var state = SignalGateState()
        let still = checkerboard()
        let first = SignalGate.evaluate(plane: still, at: origin, needOpen: false, state: &state)
        XCTAssertTrue(first.sceneActive)
        XCTAssertFalse(first.activityEdge)

        let held = SignalGate.evaluate(plane: still, at: origin.addingTimeInterval(1), needOpen: false, state: &state)
        XCTAssertFalse(held.passes)

        let jumped = SignalGate.evaluate(
            plane: plane(fill: 220),
            at: origin.addingTimeInterval(SignalGateTuning.activityEdgeMinInterval),
            needOpen: false,
            state: &state
        )
        XCTAssertGreaterThan(jumped.motionScore, SignalGateTuning.activityEdgeMotion)
        XCTAssertTrue(jumped.sceneActive)
        XCTAssertFalse(jumped.activityEdge)

        let continued = SignalGate.evaluate(
            plane: plane(fill: 40),
            at: origin.addingTimeInterval(SignalGateTuning.activityEdgeMinInterval + 1),
            needOpen: false,
            state: &state
        )
        XCTAssertGreaterThan(continued.motionScore, SignalGateTuning.motionThreshold)
        XCTAssertFalse(continued.sceneActive, "idle sustained motion waits for the slow sample")

        let sampled = SignalGate.evaluate(
            plane: still,
            at: origin.addingTimeInterval(SignalGateTuning.activityEdgeMinInterval + SignalGateTuning.idleAdmitInterval),
            needOpen: false,
            state: &state
        )
        XCTAssertTrue(sampled.sceneActive)
    }

    func testAnOpenNeedAdmitsChangesAndOneActivityEdge() {
        var state = SignalGateState()
        let quiet = checkerboard()
        _ = SignalGate.evaluate(plane: quiet, at: origin, needOpen: true, state: &state)
        _ = SignalGate.evaluate(plane: quiet, at: origin.addingTimeInterval(0.5), needOpen: true, state: &state)

        let jump = SignalGate.evaluate(
            plane: plane(fill: 230),
            at: origin.addingTimeInterval(SignalGateTuning.activityEdgeMinInterval),
            needOpen: true,
            state: &state
        )
        XCTAssertTrue(jump.sceneActive)
        XCTAssertTrue(jump.activityEdge)

        let again = SignalGate.evaluate(
            plane: plane(fill: 20),
            at: origin.addingTimeInterval(SignalGateTuning.activityEdgeMinInterval + 1),
            needOpen: true,
            state: &state
        )
        XCTAssertTrue(again.sceneActive)
        XCTAssertFalse(again.activityEdge, "the next edge waits out the minimum gap")

        let due = SignalGate.evaluate(
            plane: quiet,
            at: origin.addingTimeInterval(SignalGateTuning.activityEdgeMinInterval + SignalGateTuning.openAdmitInterval),
            needOpen: true,
            state: &state
        )
        XCTAssertTrue(due.sceneActive)
        XCTAssertLessThan(SignalGateTuning.openAdmitInterval, SignalGateTuning.idleAdmitInterval)
        XCTAssertLessThan(SignalGateTuning.openAdmitInterval, SessionLimits.heartbeatSeconds)
    }

    func testAMissingPlaneIsHeldAndDoesNotWipeThePreviousFrame() {
        var state = SignalGateState()
        let first = SignalGate.evaluate(plane: checkerboard(), at: origin, needOpen: false, state: &state)
        XCTAssertTrue(first.passes)
        let missing = SignalGate.evaluate(plane: nil, at: origin.addingTimeInterval(1), needOpen: false, state: &state)
        XCTAssertFalse(missing.passes)
        XCTAssertEqual(missing.motionScore, 0)
        let stillThere = SignalGate.evaluate(
            plane: checkerboard(),
            at: origin.addingTimeInterval(2),
            needOpen: false,
            state: &state
        )
        XCTAssertEqual(stillThere.motionScore, 0, accuracy: 0.000_001)
    }

    func testSceneActivityAdmitsALatchWithoutAPersonRect() throws {
        let clock = ManualClock(now: origin)
        var engine = try NeedEngine(clock: clock, needs: [EngineTestCase.takeBaby()])
        func admit(at time: Date, marker: UInt8) {
            let delta = time.timeIntervalSince(clock.now())
            if delta > 0 { clock.advance(by: delta) }
            let frame = CameraFrame(capturedAt: time, jpegData: Data([marker]), width: 8, height: 8)
            let gate = FrameGateSnapshot(
                capturedAt: time,
                people: [],
                wearerHandsVisible: false,
                handGateRisingEdge: false,
                motionScore: 0.4,
                sharpness: 0.02,
                sceneActive: true
            )
            engine.ingest(frame: frame, gate: gate, sharpness: 0.02)
        }
        admit(at: origin, marker: 1)
        XCTAssertNil(engine.pendingModelCall)
        admit(at: origin.addingTimeInterval(5), marker: 2)
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .latch)
        XCTAssertGreaterThanOrEqual(call.request.keyframes.count, 2)
        XCTAssertEqual(engine.keyframes().map(\.jpegData), [Data([1]), Data([2])])
    }

    private func plane(fill: UInt8, width: Int = 16, height: Int = 16) -> LumaPlane {
        LumaPlane(width: width, height: height, samples: [UInt8](repeating: fill, count: width * height))
    }

    private func checkerboard() -> LumaPlane {
        let width = 16
        let height = 16
        var samples = [UInt8]()
        samples.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                samples.append((x + y).isMultiple(of: 2) ? 0 : 255)
            }
        }
        return LumaPlane(width: width, height: height, samples: samples)
    }
}

final class SparkPresenceTests: EngineTestCase {
    func testMotionKeyframesDoNotResetTheNoPersonClock() throws {
        try latch("take-baby")
        let seen = clock.now()
        advance(20)
        see([], sceneActive: true, activityEdge: false)
        advance(to: seen.addingTimeInterval(SessionLimits.noPersonKeyframeCloseSeconds))
        engine.tick()
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.closedUnknown).last?.detail, "no-person")
    }

    func testPartnerInViewFromSparkRefreshesTheNoPersonClock() throws {
        try latch("take-baby")
        let seen = clock.now()
        advance(40)
        see([], sceneActive: true)
        engine.tick()
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .heartbeat)
        engine.handle(callID: call.id, verdict: report(partnerInView: true))
        advance(44)
        engine.tick()
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        advance(1)
        engine.tick()
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertGreaterThan(seen.timeIntervalSince1970, 0)
    }

    func testPartnerAbsentDoesNotRefreshTheClock() throws {
        try latch("take-baby")
        let seen = clock.now()
        advance(40)
        see([], sceneActive: true)
        engine.tick()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: report(partnerInView: false))
        advance(to: seen.addingTimeInterval(SessionLimits.noPersonKeyframeCloseSeconds))
        engine.tick()
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
    }

    func testAnActivityEdgeHeartbeatsBeforeTheIdleInterval() throws {
        try latch("take-baby")
        advance(2)
        see([], sceneActive: true, activityEdge: true)
        let call = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(call.purpose, .heartbeat)
        XCTAssertLessThan(2, SessionLimits.heartbeatSeconds)
    }

    private func latch(_ id: String) throws {
        glancePair()
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict(id))
        XCTAssertEqual(engine.openNeedIDs, [id])
    }

    private func report(partnerInView: Bool) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNoTransition,
            assessment: SceneAssessment(
                needID: "take-baby",
                sustainedAcrossStrip: true,
                partnerInView: partnerInView,
                wearerHandsVisible: false
            )
        )
    }
}
