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
