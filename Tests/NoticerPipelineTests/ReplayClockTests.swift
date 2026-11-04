import Foundation
import NoticerPipeline
import XCTest

final class ReplayClockTests: XCTestCase {
    func testPlayheadAdvancesInRealTime() {
        var clock = ReplayClock(duration: 95)
        clock.play(at: 100)
        clock.tick(at: 105)
        XCTAssertEqual(clock.playhead, 5, accuracy: 0.1)
        XCTAssertEqual(clock.fraction, 5.0 / 95.0, accuracy: 0.001)
        XCTAssertFalse(clock.isAtEnd)
    }

    func testPlayheadNeverExceedsDuration() {
        var clock = ReplayClock(duration: 95)
        clock.play(at: 0)
        clock.tick(at: 1_000)
        XCTAssertEqual(clock.playhead, 95, accuracy: 0.001)
        XCTAssertTrue(clock.isAtEnd)
        clock.tick(at: 2_000)
        XCTAssertEqual(clock.playhead, 95, accuracy: 0.001)
    }

    func testPauseFreezesThenResumes() {
        var clock = ReplayClock(duration: 95)
        clock.play(at: 0)
        clock.tick(at: 5)
        clock.seek(to: clock.playhead)
        clock.tick(at: 100)
        XCTAssertEqual(clock.playhead, 5, accuracy: 0.001)
        clock.play(at: 100)
        clock.tick(at: 103)
        XCTAssertEqual(clock.playhead, 8, accuracy: 0.001)
    }

    func testSeekClampsToTheRun() {
        var clock = ReplayClock(duration: 95)
        clock.seek(to: -10)
        XCTAssertEqual(clock.playhead, 0, accuracy: 0.001)
        clock.seek(to: 1_000)
        XCTAssertEqual(clock.playhead, 95, accuracy: 0.001)
        XCTAssertTrue(clock.isAtEnd)
    }

    func testIndexPicksLastFrameAtOrBeforePlayhead() {
        var clock = ReplayClock(duration: 95)
        let times: [TimeInterval] = [0, 2, 4, 6]
        clock.seek(to: 0)
        XCTAssertEqual(clock.index(in: times), 0)
        clock.seek(to: 1.9)
        XCTAssertEqual(clock.index(in: times), 0)
        clock.seek(to: 2)
        XCTAssertEqual(clock.index(in: times), 1)
        clock.seek(to: 5.9)
        XCTAssertEqual(clock.index(in: times), 2)
        clock.seek(to: 6)
        XCTAssertEqual(clock.index(in: times), 3)
        clock.seek(to: 95)
        XCTAssertEqual(clock.index(in: times), 3)
        XCTAssertEqual(clock.index(in: []), 0)
    }

    func testFractionIsZeroWithoutDuration() {
        let clock = ReplayClock()
        XCTAssertEqual(clock.fraction, 0)
        XCTAssertEqual(clock.playhead, 0)
    }

    func testDoubleSpeedAdvancesTwiceAsFast() {
        var clock = ReplayClock(duration: 95, speed: 2)
        clock.play(at: 0)
        clock.tick(at: 5)
        XCTAssertEqual(clock.playhead, 10, accuracy: 0.001)
    }

    func testClampedOffsetStaysInsideTheRun() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            ReplayClock.clampedOffset(at: start.addingTimeInterval(10), start: start, duration: 95),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReplayClock.clampedOffset(at: start.addingTimeInterval(-5), start: start, duration: 95),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReplayClock.clampedOffset(at: start.addingTimeInterval(1_563_544 * 60 + 52), start: start, duration: 95),
            95,
            accuracy: 0.001
        )
    }
}
