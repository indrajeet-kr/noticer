import Foundation
import XCTest

/// Screen copy with exact expectations: timing words, list header, wins lines.
final class WordingTests: XCTestCase {
    func testHeadStartSeconds() {
        XCTAssertEqual(
            TimingWords.headStartSentence(seconds: 40).main,
            "He gets about 40 seconds to notice first"
        )
        XCTAssertNil(
            TimingWords.headStartSentence(seconds: 40).detail,
            "under a minute the main sentence already states the seconds"
        )
    }

    func testHeadStartMinuteAndHalf() {
        XCTAssertEqual(
            TimingWords.headStartSentence(seconds: 90).main,
            "He gets about a minute and a half to notice first"
        )
        XCTAssertEqual(TimingWords.headStartSentence(seconds: 90).detail, "90 seconds")
    }

    func testHeadStartMinutes() {
        XCTAssertEqual(
            TimingWords.headStartSentence(seconds: 60).main,
            "He gets about a minute to notice first"
        )
        XCTAssertEqual(TimingWords.headStartSentence(seconds: 60).detail, "60 seconds")
        XCTAssertEqual(
            TimingWords.headStartSentence(seconds: 120).main,
            "He gets about 2 minutes to notice first"
        )
        XCTAssertEqual(TimingWords.headStartSentence(seconds: 120).detail, "120 seconds")
    }

    func testDayPartLine() {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = 30
        parts.hour = 20
        let evening = Calendar.current.date(from: parts)!
        XCTAssertEqual(DayPart.line(for: evening), "Friday evening")
        parts.hour = 9
        XCTAssertEqual(DayPart.line(for: Calendar.current.date(from: parts)!), "Friday morning")
        parts.hour = 14
        XCTAssertEqual(DayPart.line(for: Calendar.current.date(from: parts)!), "Friday afternoon")
    }

    func testListHeaderCounts() {
        XCTAssertEqual(ListHeader.title(count: 0), "Nothing shared yet")
        XCTAssertEqual(ListHeader.title(count: 1), "1 thing she's shared")
        XCTAssertEqual(ListHeader.title(count: 3), "3 things she's shared")
    }

    func testWinsSentenceWithTrend() {
        XCTAssertEqual(
            WinsSummary.sentence(selfNotices: 3, cues: 2, priorCues: 5),
            "He caught 3 things on his own tonight. 2 cues, down from 5."
        )
    }

    func testWinsSentenceWithoutPrior() {
        XCTAssertEqual(
            WinsSummary.sentence(selfNotices: 1, cues: 0, priorCues: nil),
            "He caught 1 thing on his own tonight."
        )
    }

    func testWinsSentenceQuietNight() {
        XCTAssertEqual(WinsSummary.sentence(selfNotices: 0, cues: 0, priorCues: nil), "A quiet night together.")
    }

    func testCueWeekSentence() {
        XCTAssertEqual(CueWeekSentence.text(tonight: 3, prior: 7), "3 cues tonight, down from 7.")
        XCTAssertEqual(CueWeekSentence.text(tonight: 1, prior: nil), "1 cue tonight.")
        XCTAssertEqual(CueWeekSentence.text(tonight: 2, prior: 2), "2 cues tonight.")
        XCTAssertEqual(CueWeekSentence.text(tonight: 0, prior: 5), "No cues tonight.")
    }

    func testWinsHeadlines() {
        XCTAssertEqual(WinsSummary.headline(selfNotices: 0, hasWins: false), "A gentle start, together")
        XCTAssertEqual(WinsSummary.headline(selfNotices: 0, hasWins: true), "Every nudge is teamwork too")
        XCTAssertEqual(WinsSummary.headline(selfNotices: 2, hasWins: true), "A good night, together")
    }
}
