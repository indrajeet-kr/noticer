import XCTest
@testable import NoticerCore

/// The log says why it is quiet: check-in needs hold their whisper
/// while she sleeps, and a dark streak holds calls with one line.
final class QuietReasonTests: EngineTestCase {
    private func asleepVerdict() -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNoTransition,
            assessment: SceneAssessment(partnerAsleep: true)
        )
    }

    private func deadline(of needID: String) -> Date {
        engine.openNeeds.first { $0.needID == needID }!.cueDeadline
    }

    func testPartnerAsleepSuppressesCheckinButNotChores() throws {
        try engine.setNeeds([
            Self.takeBaby(dwell: 30, allowsCheckIn: true),
            Self.need(id: "put-plates-in-sink", priority: 1, dwell: 30),
        ])
        glancePair()
        let first = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: first.id, verdict: latchVerdict("take-baby"))

        advance(SessionLimits.latchMinIntervalSeconds + 1)
        see([mom()], handsEdge: true)
        let second = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: second.id, verdict: latchVerdict("put-plates-in-sink"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby", "put-plates-in-sink"])

        advance(9)
        see([mom()])
        let heartbeat = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: heartbeat.id, verdict: asleepVerdict())

        advance(to: deadline(of: "take-baby"))
        engine.tick()
        XCTAssertEqual(events(.quietPartnerAsleep).map(\.needID), ["take-baby"])

        advance(to: deadline(of: "put-plates-in-sink"))
        engine.tick()
        XCTAssertEqual(events(.cueFired).map(\.needID), ["put-plates-in-sink"])
        XCTAssertEqual(events(.quietPartnerAsleep).count, 1, "one line per need per sleep episode")
    }

    func testDarkStreakLogsOnceAndHoldsCallsUntilItClears() throws {
        see([mom()], sharpness: 0.0)
        advance(5)
        see([mom()], sharpness: 0.0)
        // Two dark frames: dark is not declared yet, the call goes out.
        let early = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: early.id, verdict: noTransition())

        advance(5)
        see([mom()], sharpness: 0.0)
        XCTAssertEqual(events(.frameDark).count, 1)

        advance(5)
        see([mom()], sharpness: 0.0)
        XCTAssertEqual(events(.frameDark).count, 1, "one line per streak")

        advance(5)
        engine.tick()
        XCTAssertNil(engine.pendingModelCall, "no model calls while dark")

        see([mom()], sharpness: 0.5, jpeg: 9)
        advance(5)
        see([mom()], sharpness: 0.5, jpeg: 10)
        XCTAssertNotNil(engine.pendingModelCall, "calls resume once it clears")
    }
}
