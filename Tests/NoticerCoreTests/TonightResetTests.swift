import Foundation
import XCTest
@testable import NoticerCore

/// Tonight resets per evening (noon to noon), on launch and on start.
/// A 00:25 entry is the previous night once the clock passes noon.
final class TonightResetTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: hour, minute: minute))!
        return calendar.date(byAdding: .day, value: dayOffset, to: base)!
    }

    func testEveningStartsAtNoon() {
        XCTAssertEqual(
            TonightReset.eveningStart(now: date(22, 28), calendar: calendar),
            date(12, 0)
        )
        XCTAssertEqual(
            TonightReset.eveningStart(now: date(10, 0, dayOffset: 1), calendar: calendar),
            date(12, 0)
        )
        XCTAssertEqual(
            TonightReset.eveningStart(now: date(12, 0), calendar: calendar),
            date(12, 0),
            "noon itself opens the new evening"
        )
    }

    func testResetDropsThePreviousNight() {
        let moments = [date(0, 25), date(18, 31)]
        let reset = TonightReset.reset(moments, at: { $0 }, now: date(22, 28), calendar: calendar)
        XCTAssertEqual(reset.kept, [date(18, 31)])
        XCTAssertEqual(reset.dropped, 1)
    }

    func testMorningAfterKeepsLastNight() {
        let moments = [date(18, 31), date(23, 50)]
        let reset = TonightReset.reset(moments, at: { $0 }, now: date(10, 0, dayOffset: 1), calendar: calendar)
        XCTAssertEqual(reset.kept.count, 2)
        XCTAssertEqual(reset.dropped, 0)
    }

    func testEntryExactlyAtNoonStays() {
        let moments = [date(12, 0)]
        let reset = TonightReset.reset(moments, at: { $0 }, now: date(22, 28), calendar: calendar)
        XCTAssertEqual(reset.kept.count, 1)
        XCTAssertEqual(reset.dropped, 0)
    }
}
