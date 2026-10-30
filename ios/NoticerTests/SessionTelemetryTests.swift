import Foundation
import NoticerCore
import XCTest

/// Telemetry shown in the live dev panel: which need ids the engine dropped
/// as unknown, so a device run shows what the model actually sent.
final class SessionTelemetryTests: XCTestCase {
    func testDroppedNeedIDsFiltersUnknownNeedDrops() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            EngineEvent(kind: .needLatched, needID: "refill-water", at: at),
            EngineEvent(kind: .assessmentDropped, needID: "no_need", at: at, detail: "unknown-need"),
            EngineEvent(kind: .assessmentDropped, needID: "no_need", at: at, detail: "unknown-need"),
            EngineEvent(kind: .assessmentDropped, needID: "water-glass", at: at, detail: "unknown-need"),
            EngineEvent(kind: .assessmentDropped, needID: nil, at: at, detail: "unknown-need"),
            EngineEvent(kind: .assessmentDropped, needID: "take-baby", at: at, detail: "unknown-resolution"),
            EngineEvent(kind: .cueFired, needID: "refill-water", at: at),
        ]
        XCTAssertEqual(
            SessionTelemetry.droppedNeedIDs(from: events),
            ["no_need", "water-glass"],
            "only unknown-need drops surface, consecutive repeats collapse"
        )
    }

    func testDroppedNeedIDsCapsTail() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let events = (0..<12).map {
            EngineEvent(kind: .assessmentDropped, needID: "id-\($0)", at: at, detail: "unknown-need")
        }
        XCTAssertEqual(SessionTelemetry.droppedNeedIDs(from: events).count, 8)
        XCTAssertEqual(SessionTelemetry.droppedNeedIDs(from: events).last, "id-11")
    }

    func testDroppedLine() {
        XCTAssertEqual(SessionTelemetry.droppedLine([]), "dropped: —")
        XCTAssertEqual(SessionTelemetry.droppedLine(["no_need"]), "dropped: no_need")
    }

    func testEventTimelineFormatsOldestFirstCapped() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            EngineEvent(kind: .needLatched, needID: "water", at: start),
            EngineEvent(kind: .recheckRequested, needID: "water", at: start.addingTimeInterval(20)),
            EngineEvent(kind: .cueFired, needID: "water", at: start.addingTimeInterval(24), detail: "whisper"),
            EngineEvent(kind: .caughtHimself, needID: nil, at: start.addingTimeInterval(30)),
        ]
        let lines = SessionTelemetry.eventTimeline(from: events, cap: 3)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("recheckRequested water"))
        XCTAssertTrue(lines[1].hasSuffix("cueFired water whisper"))
        XCTAssertTrue(lines[2].hasSuffix("caughtHimself"))
        XCTAssertTrue(lines.allSatisfy { $0.count > 9 && $0[$0.startIndex ..< $0.index($0.startIndex, offsetBy: 8)].contains(":") })
    }

    func testEventTimelineEmpty() {
        XCTAssertTrue(SessionTelemetry.eventTimeline(from: []).isEmpty)
    }

    func testClockTimeHasSecondsPrecision() {
        let rendered = SessionTelemetry.clockTime(Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(rendered.filter { $0 == ":" }.count, 2)
        XCTAssertEqual(rendered.count, 8)
    }
}
