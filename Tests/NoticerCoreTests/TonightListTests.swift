import Foundation
import XCTest
@testable import NoticerCore

/// Tonight shows the local day, and only needs still on her list. The
/// function has no running flag: the same moments qualify during a session
/// and after it stops.
final class TonightListTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: hour, minute: minute))!
        return calendar.date(byAdding: .day, value: dayOffset, to: base)!
    }

    func testTodayKeepsNeedsStillOnHerList() {
        let now = date(18, 32)
        let moments = [
            (at: date(10, 15), needID: "clean-floor-toys"),
            (at: date(10, 16), needID: "take-baby"),
            (at: date(18, 31), needID: "water"),
            (at: date(18, 31, dayOffset: -1), needID: "water"),
        ]
        let visible = TonightList.select(
            moments,
            at: \.at,
            needID: \.needID,
            activeNeedIDs: ["take-baby", "water", "remove-empty-glasses"],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(visible.map(\.needID), ["take-baby", "water"])
    }

    func testRemovedNeedStaysHiddenWhileRunningAndAfterStop() {
        let now = date(18, 29)
        let moments = [(at: date(10, 15), needID: "clean-floor-toys")]
        let active: Set<String> = ["water", "remove-empty-glasses"]
        let during = TonightList.select(moments, at: \.at, needID: \.needID, activeNeedIDs: active, now: now, calendar: calendar)
        let after = TonightList.select(moments, at: \.at, needID: \.needID, activeNeedIDs: active, now: now, calendar: calendar)
        XCTAssertTrue(during.isEmpty)
        XCTAssertEqual(during.map(\.needID), after.map(\.needID))
    }

    func testCurrentSessionMomentAppearsAsSoonAsItIsRecorded() {
        let now = date(18, 31)
        let before = TonightList.select(
            [(at: date(10, 15), needID: "clean-floor-toys")],
            at: \.at,
            needID: \.needID,
            activeNeedIDs: ["water"],
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(before.isEmpty)
        let after = TonightList.select(
            [
                (at: date(10, 15), needID: "clean-floor-toys"),
                (at: now, needID: "water"),
            ],
            at: \.at,
            needID: \.needID,
            activeNeedIDs: ["water"],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(after.map(\.needID), ["water"])
    }
}
