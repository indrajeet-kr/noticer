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
        XCTAssertTrue(fired.spoken.isEmpty, "speech lands on the next step, not this one")
        let startedBeforeSpeech = await speaker.startedCount()
        XCTAssertEqual(startedBeforeSpeech, 0)
        let logBeforeSpeech = await pipeline.view().log
        XCTAssertTrue(logBeforeSpeech.contains { $0.kind == .cueFired })

        let speech = Task { try await pipeline.tick() }
        try await waitUntil { await speaker.startedCount() == 1 }
        await speaker.release()
        let spoken = try await speech.value
        XCTAssertEqual(spoken.spoken.map(\.needID), [MVPNeedList.takeBabyID])
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
