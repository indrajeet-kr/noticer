import Foundation
import NoticerCore
import NoticerPipeline
import XCTest

final class InFlightCallTests: XCTestCase {
    func testASecondIngestDoesNotStartAnotherSparkCall() async throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SessionClock.manual(startingAt: origin)
        let client = HoldingClient()
        let pipeline = try SessionPipeline(
            clock: clock,
            needs: [MVPNeedList.takeBaby],
            model: client,
            speaker: RecordingCueSpeaker()
        )

        func frame(at time: Date, marker: UInt8) -> CameraFrame {
            CameraFrame(capturedAt: time, jpegData: Data([marker]), width: 8, height: 8)
        }
        func gate(at time: Date) -> FrameGateSnapshot {
            ScriptedSignalGate.snapshot(at: time, people: ScriptedSignalGate.mom, handsRising: false)
        }

        clock.advance(to: origin)
        _ = try await pipeline.ingest(frame: frame(at: origin, marker: 1), gate: gate(at: origin))
        let started = await client.startedCount()
        XCTAssertEqual(started, 0)

        let second = origin.addingTimeInterval(5)
        clock.advance(to: second)
        let firstStep = Task {
            try await pipeline.ingest(frame: frame(at: second, marker: 2), gate: gate(at: second))
        }
        try await waitUntil { await client.startedCount() == 1 }

        let third = origin.addingTimeInterval(6)
        clock.advance(to: third)
        let overlapped = try await pipeline.ingest(frame: frame(at: third, marker: 3), gate: gate(at: third))
        let during = await client.startedCount()
        XCTAssertEqual(during, 1, "a second ingest waits; it does not start another call")
        XCTAssertNil(overlapped.modelError)

        await client.releaseOne()
        let finishedFirst = try await firstStep.value
        XCTAssertNil(finishedFirst.modelError)
        let afterFirst = await client.startedCount()
        XCTAssertEqual(afterFirst, 1)

        let fourth = origin.addingTimeInterval(20)
        clock.advance(to: fourth)
        let next = Task {
            try await pipeline.ingest(frame: frame(at: fourth, marker: 4), gate: gate(at: fourth))
        }
        try await waitUntil { await client.startedCount() == 2 }
        await client.releaseOne()
        _ = try await next.value
    }

    func testReplyEventsPublishBeforeSlowSpeechFinishes() async throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SessionClock.manual(startingAt: origin)
        let client = ScriptedModelClient(verdicts: [
            latchVerdict(),
            ModelVerdict(
                finishReason: .toolCalls,
                tool: .reportNoTransition,
                assessment: SceneAssessment(needID: MVPNeedList.takeBabyID, sustainedAcrossStrip: true)
            ),
        ])
        let speaker = GateSpeaker()
        let pipeline = try SessionPipeline(
            clock: clock,
            needs: [MVPNeedList.takeBaby],
            model: client,
            speaker: speaker
        )

        clock.advance(to: origin)
        _ = try await pipeline.ingest(frame: frame(at: origin, marker: 1), gate: gate(at: origin))
        let latchedAt = origin.addingTimeInterval(5)
        clock.advance(to: latchedAt)
        _ = try await pipeline.ingest(frame: frame(at: latchedAt, marker: 2), gate: gate(at: latchedAt))
        let open = await pipeline.view().openNeeds.map(\.needID)
        XCTAssertEqual(open, [MVPNeedList.takeBabyID])

        clock.advance(to: latchedAt.addingTimeInterval(90))
        let fired = try await pipeline.ingest(
            frame: frame(at: clock.now(), marker: 3),
            gate: gate(at: clock.now())
        )
        XCTAssertEqual(fired.spoken.map(\.needID), [MVPNeedList.takeBabyID], "cue starts speaking on the same step without blocking step return")
        let logBeforeSpeechFinishes = await pipeline.view().log
        XCTAssertTrue(logBeforeSpeechFinishes.contains { $0.kind == .cueFired })
        let finishedBeforeRelease = await speaker.spokenCues()
        XCTAssertTrue(finishedBeforeRelease.isEmpty, "reply events publish before slow speech finishes")

        try await waitUntil { await speaker.startedCount() == 1 }
        await speaker.release()
        await pipeline.waitForSpeech()
        let cues = await speaker.spokenCues().map(\.needID)
        XCTAssertEqual(cues, [MVPNeedList.takeBabyID])
    }

    func testCancelledCallYieldsCancelNotModelError() async throws {
        for failure in [ThrowingClient.Failure.urlCancelled, .cancellation] {
            let origin = Date(timeIntervalSince1970: 1_700_000_000)
            let clock = SessionClock.manual(startingAt: origin)
            let pipeline = try SessionPipeline(
                clock: clock,
                needs: [MVPNeedList.takeBaby],
                model: ThrowingClient(failure: failure),
                speaker: RecordingCueSpeaker()
            )
            clock.advance(to: origin)
            _ = try await pipeline.ingest(frame: frame(at: origin, marker: 1), gate: gate(at: origin))
            clock.advance(to: origin.addingTimeInterval(5))
            do {
                _ = try await pipeline.ingest(
                    frame: frame(at: clock.now(), marker: 2),
                    gate: gate(at: clock.now())
                )
                XCTFail("expected a cancel for \(failure)")
            } catch is CancellationError {
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }
    }

    func testCancelStillLoggedAsCancel() async throws {
        for failure in [ThrowingClient.Failure.urlCancelled, .cancellation] {
            let origin = Date(timeIntervalSince1970: 1_700_000_000)
            let clock = SessionClock.manual(startingAt: origin)
            let client = CapturingCancelClient(inner: ThrowingClient(failure: failure))
            let pipeline = try SessionPipeline(
                clock: clock,
                needs: [MVPNeedList.takeBaby],
                model: client,
                speaker: RecordingCueSpeaker()
            )
            clock.advance(to: origin)
            _ = try await pipeline.ingest(frame: frame(at: origin, marker: 1), gate: gate(at: origin))
            clock.advance(to: origin.addingTimeInterval(5))
            do {
                _ = try await pipeline.ingest(
                    frame: frame(at: clock.now(), marker: 2),
                    gate: gate(at: clock.now())
                )
                XCTFail("expected CancellationError")
            } catch is CancellationError {
                let tags = await client.tags()
                XCTAssertEqual(tags, ["call", "cancelled"])
            }
        }
    }

    func testStepPublishedBeforeFollowUpCall() async throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SessionClock.manual(startingAt: origin)
        let client = ScriptedModelClient(verdicts: [
            latchVerdict(),
            ModelVerdict(
                finishReason: .toolCalls,
                tool: .reportNoTransition,
                assessment: SceneAssessment(needID: MVPNeedList.takeBabyID, sustainedAcrossStrip: true)
            ),
        ])
        let pipeline = try SessionPipeline(
            clock: clock,
            needs: [MVPNeedList.takeBaby],
            model: client,
            speaker: RecordingCueSpeaker(),
            timing: .quick
        )

        // Urgent/recheck follow-up scenario: latch at t=2s, then jump straight to cueDeadline (t=12s)
        // where stale evidence wasn't hit yet, or jump to t=20s where recheck is requested.
        clock.advance(to: origin)
        _ = try await pipeline.ingest(frame: frame(at: origin, marker: 1), gate: gate(at: origin))
        let latchTime = origin.addingTimeInterval(2)
        clock.advance(to: latchTime)
        let step1 = try await pipeline.ingest(frame: frame(at: latchTime, marker: 2), gate: gate(at: latchTime))
        XCTAssertEqual(step1.decisions.count, 1, "one reply publishes one step immediately")
        let viewAfterStep1 = await pipeline.view()
        XCTAssertEqual(viewAfterStep1.openNeeds.map(\.needID), [MVPNeedList.takeBabyID])
        XCTAssertEqual(viewAfterStep1.modelCalls, 1)

        // Switch test: `oneReplyPerStep: false` loops pending calls in the same step when eligible.
        let urgentNeed = Need(
            id: "take-baby",
            authorText: "Take the baby",
            cueWording: "Maybe take the baby?",
            dwellSeconds: 0,
            priority: 0
        )
        let multiStepClient = ScriptedModelClient(verdicts: [
            latchVerdict(),
            ModelVerdict(
                finishReason: .toolCalls,
                tool: .reportNoTransition,
                assessment: SceneAssessment(needID: "take-baby", sustainedAcrossStrip: true)
            ),
        ])
        let legacyClock = SessionClock.manual(startingAt: origin)
        let legacyPipeline = try SessionPipeline(
            clock: legacyClock,
            needs: [urgentNeed],
            model: multiStepClient,
            speaker: RecordingCueSpeaker(),
            latency: LatencyTuning(oneReplyPerStep: false, dedupeAllPurposes: false)
        )
        legacyClock.advance(to: origin)
        _ = try await legacyPipeline.ingest(frame: frame(at: origin, marker: 1), gate: gate(at: origin))
        let t5 = origin.addingTimeInterval(5)
        legacyClock.advance(to: t5)
        var risingGate = gate(at: t5)
        risingGate.handGateRisingEdge = true
        let legacyStep = try await legacyPipeline.ingest(frame: frame(at: t5, marker: 2), gate: risingGate)
        XCTAssertGreaterThanOrEqual(legacyStep.decisions.count, 1)
    }

    func testPreparedSpeechUsedAndSpokenSameStep() async throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SessionClock.manual(startingAt: origin)
        let speaker = OrderRecordingSpeaker()
        let urgent = Need(
            id: "silver-glass-floor",
            authorText: "Take away the silver glass on the floor",
            cueWording: "Could you move that glass from the baby?",
            visualCondition: "silver glass on floor near baby",
            handledCondition: "floor clear of silver glass",
            selfNoticeSignal: "wearer_picking_up_glass",
            priority: 0,
            isUrgent: true
        )
        let client = ScriptedModelClient(verdicts: [
            ModelVerdict(
                finishReason: .toolCalls,
                tool: .latchNeedHypothesis,
                assessment: SceneAssessment(
                    needID: "silver-glass-floor",
                    sustainedAcrossStrip: true,
                    wearerHandsOccupied: false,
                    partnerInView: true
                )
            )
        ])
        let pipeline = try SessionPipeline(
            clock: clock,
            needs: [urgent],
            model: client,
            speaker: speaker,
            timing: .quick
        )

        clock.advance(to: origin)
        let step = try await pipeline.ingest(frame: frame(at: origin, marker: 1), gate: gate(at: origin))
        await pipeline.waitForSpeech()

        XCTAssertEqual(step.spoken.map(\.needID), ["silver-glass-floor"], "spoken on the same step with no extra tick")
        let events = await speaker.events()
        XCTAssertEqual(events, ["prepare:1", "speak:silver-glass-floor"])
        XCTAssertTrue(step.timingLines.contains { $0.contains("call=call-1 purpose=latch") })
        XCTAssertTrue(step.timingLines.contains { $0.contains("need=silver-glass-floor visible→latch=") })

        // Switch tests: `instantSpeech: false` defers speech to the next step; `timingTelemetry: false` omits timingLines.
        let deferredClock = SessionClock.manual(startingAt: origin)
        let deferredSpeaker = OrderRecordingSpeaker()
        let deferredClient = ScriptedModelClient(verdicts: [
            ModelVerdict(
                finishReason: .toolCalls,
                tool: .latchNeedHypothesis,
                assessment: SceneAssessment(
                    needID: "silver-glass-floor",
                    sustainedAcrossStrip: true,
                    wearerHandsOccupied: false,
                    partnerInView: true
                )
            )
        ])
        let deferredPipeline = try SessionPipeline(
            clock: deferredClock,
            needs: [urgent],
            model: deferredClient,
            speaker: deferredSpeaker,
            timing: .quick,
            latency: LatencyTuning(instantSpeech: false, timingTelemetry: false)
        )
        deferredClock.advance(to: origin)
        let firstStep = try await deferredPipeline.ingest(frame: frame(at: origin, marker: 1), gate: gate(at: origin))
        XCTAssertTrue(firstStep.spoken.isEmpty, "instantSpeech=false defers speech past model-turn step")
        XCTAssertTrue(firstStep.timingLines.isEmpty, "timingTelemetry=false emits no timing lines")
        let secondStep = try await deferredPipeline.tick()
        XCTAssertEqual(secondStep.spoken.map(\.needID), ["silver-glass-floor"])
    }

    private func latchVerdict() -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: MVPNeedList.takeBabyID,
                sustainedAcrossStrip: true,
                partnerStateEvidence: ["eating_one_handed"],
                wearerHandsOccupied: false
            )
        )
    }

    private func frame(at time: Date, marker: UInt8) -> CameraFrame {
        CameraFrame(capturedAt: time, jpegData: Data([marker]), width: 8, height: 8)
    }

    private func gate(at time: Date) -> FrameGateSnapshot {
        ScriptedSignalGate.snapshot(at: time, people: ScriptedSignalGate.mom, handsRising: false)
    }

    private func waitUntil(_ ready: @escaping () async -> Bool) async throws {
        for _ in 0..<50 {
            if await ready() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for the in-flight call")
    }

    func testOutOfOrderFrameIgnored() async throws {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SessionClock.manual(startingAt: origin)
        let pipeline = try SessionPipeline(
            clock: clock,
            needs: [MVPNeedList.takeBaby],
            model: ScriptedModelClient(responses: []),
            speaker: RecordingCueSpeaker(),
            timing: .quick
        )
        let t2 = origin.addingTimeInterval(2)
        let t1 = origin.addingTimeInterval(1)

        _ = try await pipeline.ingest(frame: frame(at: t2, marker: 2), gate: gate(at: t2))
        let revAfterT2 = await pipeline.bufferRevision
        XCTAssertGreaterThan(revAfterT2, 0)

        _ = try await pipeline.ingest(frame: frame(at: t1, marker: 1), gate: gate(at: t1))
        let revAfterT1 = await pipeline.bufferRevision
        XCTAssertEqual(revAfterT1, revAfterT2, "out-of-order frame must not advance buffer revision")
    }
}

private struct ThrowingClient: ModelClient, Sendable {
    enum Failure: Sendable {
        case urlCancelled
        case cancellation
    }

    var failure: Failure

    func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        switch failure {
        case .urlCancelled:
            throw URLError(.cancelled)
        case .cancellation:
            throw CancellationError()
        }
    }
}

private actor GateSpeaker: CueSpeaker {
    private var started = 0
    private var spoken: [Cue] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func startedCount() -> Int { started }

    func speak(_ cue: Cue) async throws {
        started += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        spoken.append(cue)
    }

    func stop() async {}

    func spokenCues() -> [Cue] { spoken }

    func release() {
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor HoldingClient: ModelClient {
    private var started = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func startedCount() -> Int { started }

    func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        started += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        return ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNoTransition,
            assessment: SceneAssessment(needID: MVPNeedList.takeBabyID, partnerInView: true)
        )
    }

    func releaseOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

private actor OrderRecordingSpeaker: CueSpeaker {
    private var log: [String] = []

    func prepare(needs: [Need]) async {
        log.append("prepare:\(needs.count)")
    }

    func speak(_ cue: Cue) async throws {
        log.append("speak:\(cue.needID)")
    }

    func stop() async {}

    func events() -> [String] { log }
}

private actor CapturingCancelClient: ModelClient {
    private let inner: any ModelClient
    private var recorded: [String] = []

    init(inner: any ModelClient) {
        self.inner = inner
    }

    func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        recorded.append("call")
        do {
            let verdict = try await inner.complete(request)
            recorded.append("ok")
            return verdict
        } catch is CancellationError {
            recorded.append("cancelled")
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            recorded.append("cancelled")
            throw error
        } catch {
            recorded.append("error")
            throw error
        }
    }

    func tags() -> [String] { recorded }
}
