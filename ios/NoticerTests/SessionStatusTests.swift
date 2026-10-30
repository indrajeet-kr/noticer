import Foundation
import XCTest

/// The glanceable status resolver: idle, calm vs checking listening,
/// head-start countdown math, and recency windows for cues and self-notices.
final class SessionStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testIdleWhenNotRunning() {
        XCTAssertEqual(
            SessionStatusResolver.resolve(
                isRunning: false,
                openNeedName: "Water",
                headStart: (10, 20),
                noticedAt: now,
                lastCue: ("Hi.", now),
                lastSelfNotice: ("Water", now),
                checking: true,
                now: now
            ),
            .idle
        )
    }

    func testListeningCalmVsChecking() {
        let calm = SessionStatusResolver.resolve(
            isRunning: true,
            openNeedName: nil,
            headStart: nil,
            noticedAt: nil,
            lastCue: nil,
            lastSelfNotice: nil,
            checking: false,
            now: now
        )
        XCTAssertEqual(calm, .listening(checking: false))
        XCTAssertEqual(calm.line, "All calm.")

        let checking = SessionStatusResolver.resolve(
            isRunning: true,
            openNeedName: nil,
            headStart: nil,
            noticedAt: nil,
            lastCue: nil,
            lastSelfNotice: nil,
            checking: true,
            now: now
        )
        XCTAssertEqual(checking, .listening(checking: true))
        XCTAssertEqual(checking.line, "Checking the scene…")
        XCTAssertNotEqual(calm.animationKey, checking.animationKey)
    }

    func testHeadStartFractionAndSeconds() {
        let status = SessionStatusResolver.resolve(
            isRunning: true,
            openNeedName: "Water",
            headStart: (10, 20),
            noticedAt: now.addingTimeInterval(-30),
            lastCue: nil,
            lastSelfNotice: nil,
            checking: false,
            now: now
        )
        XCTAssertEqual(status, .headStart(needName: "Water", fraction: 0.5, secondsLeft: 10))
        XCTAssertEqual(status.headStartFraction, 0.5)
    }

    func testCueAndSelfNoticeRecency() {
        let freshCue = SessionStatusResolver.resolve(
            isRunning: true,
            openNeedName: nil,
            headStart: nil,
            noticedAt: nil,
            lastCue: ("Her water's low.", now.addingTimeInterval(-3)),
            lastSelfNotice: nil,
            checking: false,
            now: now
        )
        XCTAssertEqual(freshCue, .cue(whisper: "Her water's low."))

        let staleCue = SessionStatusResolver.resolve(
            isRunning: true,
            openNeedName: nil,
            headStart: nil,
            noticedAt: nil,
            lastCue: ("Her water's low.", now.addingTimeInterval(-10)),
            lastSelfNotice: nil,
            checking: false,
            now: now
        )
        XCTAssertEqual(staleCue, .listening(checking: false))

        let gotIt = SessionStatusResolver.resolve(
            isRunning: true,
            openNeedName: nil,
            headStart: nil,
            noticedAt: nil,
            lastCue: ("Her water's low.", now.addingTimeInterval(-3)),
            lastSelfNotice: ("Water", now.addingTimeInterval(-2)),
            checking: false,
            now: now
        )
        XCTAssertEqual(gotIt, .gotIt(needName: "Water"))
    }

    func testNoticedWithoutHeadStart() {
        let status = SessionStatusResolver.resolve(
            isRunning: true,
            openNeedName: "Water",
            headStart: nil,
            noticedAt: now.addingTimeInterval(-1),
            lastCue: nil,
            lastSelfNotice: nil,
            checking: false,
            now: now
        )
        XCTAssertEqual(status, .noticed(needName: "Water"))
    }

    func testTimeSuffix() {
        XCTAssertEqual(SessionTelemetry.timeSuffix(nil), "")
        XCTAssertTrue(SessionTelemetry.timeSuffix(now).hasPrefix(" · "))
    }
}
