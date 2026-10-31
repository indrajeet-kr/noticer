import Foundation
import XCTest

/// Cue history: per-day counts, session-day markers, prior-day lookup, and
/// the fading trend behind the Learning bars.
final class CueHistoryStoreTests: XCTestCase {
    private func day(_ back: Int, from date: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: -back, to: date)!
    }

    func testRecordingCueIncrementsTheDay() {
        let history = CueHistoryStore.recordingCue(in: [:], at: Date())
        XCTAssertEqual(CueHistoryStore.count(on: Date(), in: history), 1)
        let twice = CueHistoryStore.recordingCue(in: history, at: Date())
        XCTAssertEqual(CueHistoryStore.count(on: Date(), in: twice), 2)
    }

    func testCueDaysKeepTheirOwnCounts() {
        var history: [String: Int] = [:]
        history = CueHistoryStore.recordingCue(in: history, at: day(1))
        history = CueHistoryStore.recordingCue(in: history, at: day(1))
        history = CueHistoryStore.recordingCue(in: history, at: day(0))
        XCTAssertEqual(CueHistoryStore.count(on: day(1), in: history), 2)
        XCTAssertEqual(CueHistoryStore.count(on: day(0), in: history), 1)
    }

    func testSessionDayExistsEvenWithZeroCues() {
        let history = CueHistoryStore.recordingSessionDay(in: [:], at: Date())
        XCTAssertTrue(CueHistoryStore.hasSession(on: Date(), in: history))
        XCTAssertEqual(CueHistoryStore.count(on: Date(), in: history), 0)
        XCTAssertFalse(CueHistoryStore.hasSession(on: day(1), in: history))
    }

    func testSessionDayNeverOverwritesCounts() {
        var history = CueHistoryStore.recordingCue(in: [:], at: Date())
        history = CueHistoryStore.recordingSessionDay(in: history, at: Date())
        XCTAssertEqual(CueHistoryStore.count(on: Date(), in: history), 1)
    }

    func testMostRecentPriorDaySkipsEmptyDays() {
        var history: [String: Int] = [:]
        history = CueHistoryStore.recordingCue(in: history, at: day(3))
        history = CueHistoryStore.recordingCue(in: history, at: day(3))
        history = CueHistoryStore.recordingSessionDay(in: history, at: day(0))
        let prior = CueHistoryStore.mostRecentPriorDay(before: day(0), in: history)
        XCTAssertEqual(prior?.count, 2)
        XCTAssertEqual(prior?.date, Calendar.current.startOfDay(for: day(3)))
    }

    func testMostRecentPriorDayIsNilWithoutHistory() {
        XCTAssertNil(CueHistoryStore.mostRecentPriorDay(before: Date(), in: [:]))
    }

    func testFadingWhenDownOverThreeOrMoreDays() {
        var history: [String: Int] = [:]
        // Indexed by days back: today resolved 3 cues, a week ago 7.
        let counts = [3, 3, 4, 5, 5, 6, 7]
        for (back, count) in counts.enumerated() {
            for _ in 0..<count {
                history = CueHistoryStore.recordingCue(in: history, at: day(back))
            }
        }
        XCTAssertTrue(CueHistoryStore.isFading(history: history))
    }

    func testNotFadingWhenFlatOrRising() {
        var flat: [String: Int] = [:]
        for back in 0..<4 {
            flat = CueHistoryStore.recordingCue(in: flat, at: day(back))
            flat = CueHistoryStore.recordingCue(in: flat, at: day(back))
        }
        XCTAssertFalse(CueHistoryStore.isFading(history: flat))

        var rising: [String: Int] = [:]
        for back in 0..<4 {
            for _ in 0...(3 - back) {
                rising = CueHistoryStore.recordingCue(in: rising, at: day(back))
            }
        }
        XCTAssertFalse(CueHistoryStore.isFading(history: rising))
    }

    func testNotFadingWithLessThanThreeDays() {
        var history: [String: Int] = [:]
        history = CueHistoryStore.recordingCue(in: history, at: day(1))
        history = CueHistoryStore.recordingCue(in: history, at: day(0))
        XCTAssertFalse(CueHistoryStore.isFading(history: history))
    }

    func testLastDaysReturnsOldestFirst() {
        var history: [String: Int] = [:]
        history = CueHistoryStore.recordingCue(in: history, at: day(0))
        let days = CueHistoryStore.lastDays(3, ending: day(0), in: history)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days.map(\.count), [0, 0, 1])
        XCTAssertLessThan(days[0].date, days[1].date)
        XCTAssertLessThan(days[1].date, days[2].date)
    }

    func testLastDaysReturnsSevenDistinctDates() {
        let days = CueHistoryStore.lastDays(7, ending: day(0), in: [:])
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(Set(days.map { CueHistoryStore.dayKey(for: $0.date) }).count, 7)
    }

    func testWeeklyBucketsCarryDistinctDatesOldestFirst() {
        let buckets = CueHistoryStore.weeklyBuckets(6, ending: day(0), in: [:])
        XCTAssertEqual(buckets.count, 6)
        XCTAssertEqual(Set(buckets.map { CueHistoryStore.dayKey(for: $0.date) }).count, 6)
        XCTAssertLessThan(buckets.first!.date, buckets.last!.date)
        XCTAssertFalse(buckets.flatMap { [$0.label] }.contains(""))
    }

    func testMonthlyBucketsCarryMonthStarts() {
        let buckets = CueHistoryStore.monthlyBuckets(6, ending: day(0), in: [:])
        XCTAssertEqual(buckets.count, 6)
        for bucket in buckets {
            XCTAssertEqual(Calendar.current.component(.day, from: bucket.date), 1)
        }
        XCTAssertLessThan(buckets.first!.date, buckets.last!.date)
    }

    func testPersistenceRoundTrip() {
        let defaults = UserDefaults(suiteName: "CueHistoryStoreTests")!
        defaults.removePersistentDomain(forName: "CueHistoryStoreTests")
        CueHistoryStore.recordCue(at: Date(), defaults: defaults)
        CueHistoryStore.recordSessionDay(at: day(2), defaults: defaults)
        let loaded = CueHistoryStore.load(defaults: defaults)
        XCTAssertEqual(CueHistoryStore.count(on: Date(), in: loaded), 1)
        XCTAssertTrue(CueHistoryStore.hasSession(on: day(2), in: loaded))
        defaults.removePersistentDomain(forName: "CueHistoryStoreTests")
    }
}
