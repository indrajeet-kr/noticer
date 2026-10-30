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
}
