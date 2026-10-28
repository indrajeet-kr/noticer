import XCTest
@testable import NoticerCore

final class KeyframeSelectionTests: EngineTestCase {
    func testOneShortGlanceKeepsASingleKeyframe() {
        see([mom()], jpeg: 1)
        advance(0.5)
        see([mom()], jpeg: 2)
        advance(0.5)
        see([mom()], jpeg: 3)
        let frames = engine.keyframes()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].episodeID, "episode-1")
        XCTAssertEqual(frames[0].ageSeconds, 0)
        XCTAssertNil(engine.pendingModelCall)
    }

    func testTheSharpestFrameInAGlanceReplacesTheSlot() {
        see([mom()], sharpness: 1, jpeg: 1)
        advance(0.5)
        see([mom()], sharpness: 9, jpeg: 9)
        advance(0.5)
        see([mom()], sharpness: 3, jpeg: 3)
        let frames = engine.keyframes()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].jpegData, Data([9]))
        XCTAssertEqual(frames[0].sharpness, 9)
        XCTAssertEqual(frames[0].capturedAt, Self.origin.addingTimeInterval(0.5))
    }

    func testANilSharpnessDoesNotReplaceAMeasuredFrame() {
        see([mom()], sharpness: 2, jpeg: 2)
        advance(0.5)
        see([mom()], sharpness: nil, jpeg: 1)
        XCTAssertEqual(engine.keyframes().first?.jpegData, Data([2]))
    }

    func testAbsenceUnderTwoSecondsStaysOneGlance() {
        see([mom()])
        advance(1.9)
        see([mom()])
        let frames = engine.keyframes()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(Set(frames.map(\.episodeID)), ["episode-1"])
    }

    func testAbsenceOfTwoSecondsStartsANewGlance() {
        see([mom()])
        advance(SessionLimits.glanceAbsentSeconds)
        see([mom()])
        let frames = engine.keyframes()
        XCTAssertEqual(frames.map(\.episodeID), ["episode-1", "episode-2"])
        XCTAssertNil(engine.pendingModelCall, "2 s is a new glance but not yet latch spacing")
    }

    func testOneLongLookEmitsAKeyframeEveryFourSeconds() {
        see([mom()])
        var elapsed = 0.0
        while elapsed < 12 {
            advance(0.5)
            elapsed += 0.5
            see([mom()])
        }
        let frames = engine.keyframes()
        XCTAssertEqual(frames.map { $0.capturedAt.timeIntervalSince(Self.origin) }, [0, 4, 8, 12])
        XCTAssertEqual(frames.map(\.ageSeconds), [12, 8, 4, 0])
        XCTAssertEqual(Set(frames.map(\.episodeID)), ["episode-1"])
        XCTAssertEqual(engine.pendingModelCall?.purpose, .latch)
    }

    func testSlowGlancesThirtyFiveSecondsApartBothStayInTheBuffer() {
        see([mom()])
        advance(35)
        see([mom()])
        let frames = engine.keyframes()
        XCTAssertEqual(frames.map(\.episodeID), ["episode-1", "episode-2"])
        XCTAssertEqual(frames.map(\.ageSeconds), [35, 0])
        XCTAssertEqual(engine.pendingModelCall?.purpose, .latch)
    }

    func testSpacingJustUnderFourSecondsDoesNotRequestALatch() {
        see([mom()])
        advance(3.9)
        see([mom()])
        XCTAssertEqual(engine.keyframes().count, 2)
        XCTAssertNil(engine.pendingModelCall)
    }

    func testSpacingOfFourSecondsRequestsALatch() {
        see([mom()])
        advance(4)
        see([mom()])
        XCTAssertEqual(engine.pendingModelCall?.purpose, .latch)
        let strip = engine.pendingModelCall?.request.keyframes ?? []
        XCTAssertGreaterThanOrEqual(strip.count, 2)
        XCTAssertEqual(strip.last?.ageSeconds, 0)
    }

    func testHistoryDropsKeyframesOlderThanSixtySeconds() {
        see([mom()])
        advance(35)
        see([mom()])
        advance(26)
        engine.tick()
        XCTAssertEqual(engine.keyframes().map { $0.capturedAt.timeIntervalSince(Self.origin) }, [35])

        see([mom()], jpeg: 7)
        advance(60)
        engine.tick()
        XCTAssertEqual(engine.keyframes().count, 1)
        advance(0.01)
        engine.tick()
        XCTAssertTrue(engine.keyframes().isEmpty)
    }

    func testAKeyframeAtExactlySixtySecondsIsKept() {
        see([mom()])
        advance(SessionLimits.keyframeBufferSeconds)
        engine.tick()
        XCTAssertEqual(engine.keyframes().count, 1)
    }
}
