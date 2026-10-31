import Foundation
import NoticerCore
import XCTest

/// Latest-session "tonight": only the most recent session shows, legacy
/// moments without an id use the day/window fallback, and rows render one
/// current wording per need.
final class SessionMomentsTests: XCTestCase {
    private func moment(
        at: Date,
        needID: String = "take-baby",
        kind: SessionMoment.Kind = .cued,
        text: String = "take the baby",
        sessionID: UUID? = nil
    ) -> SessionMoment {
        SessionMoment(at: at, needID: needID, kind: kind, text: text, sessionID: sessionID)
    }

    func testLatestSessionShowsOnly() {
        let old = UUID()
        let new = UUID()
        let base = Date()
        let moments = [
            moment(at: base.addingTimeInterval(-7200), text: "old", sessionID: old),
            moment(at: base.addingTimeInterval(-7100), text: "old", sessionID: old),
            moment(at: base.addingTimeInterval(-100), text: "new", sessionID: new),
        ]
        let tonight = SessionMomentsStore.latestSessionMoments(from: moments)
        XCTAssertEqual(tonight.map(\.text), ["new"])
    }

    func testLegacyFallbackUsesDayAndSixHourWindow() {
        let calendar = Calendar.current
        let last = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let moments = [
            moment(at: last, text: "last"),
            moment(at: last.addingTimeInterval(-3600), text: "an hour ago"),
            moment(at: last.addingTimeInterval(-9 * 3600), text: "nine hours ago"),
            moment(at: last.addingTimeInterval(-24 * 3600), text: "yesterday"),
        ]
        let tonight = SessionMomentsStore.latestSessionMoments(from: moments)
        XCTAssertEqual(Set(tonight.map(\.text)), ["last", "an hour ago"])
    }

    func testLegacyMomentsJoinANearbyIdentifiedSession() {
        let base = Date()
        let session = UUID()
        let moments = [
            moment(at: base.addingTimeInterval(-100), text: "session", sessionID: session),
            moment(at: base.addingTimeInterval(-200), text: "legacy nearby"),
        ]
        let tonight = SessionMomentsStore.latestSessionMoments(from: moments)
        XCTAssertEqual(Set(tonight.map(\.text)), ["session", "legacy nearby"])
    }

    func testLegacyMomentsDecodeWithoutSessionID() throws {
        let json = """
            [{"id":"\(UUID().uuidString)","at":\(Date().timeIntervalSinceReferenceDate),"needID":"take-baby","kind":"cued","text":"take the baby"}]
            """.data(using: .utf8)!
        let moments = try JSONDecoder().decode([SessionMoment].self, from: json)
        XCTAssertNil(moments.first?.sessionID)
    }

    func testEmptyMomentsShowNothing() {
        XCTAssertTrue(SessionMomentsStore.latestSessionMoments(from: []).isEmpty)
    }

    func testSessionInfoRoundTrip() {
        let defaults = UserDefaults(suiteName: "SessionMomentsTests")!
        defaults.removePersistentDomain(forName: "SessionMomentsTests")
        let info = SessionMomentsStore.SessionInfo(id: UUID(), startedAt: Date(), endedAt: nil)
        SessionMomentsStore.saveSessionInfo(info, defaults: defaults)
        XCTAssertEqual(SessionMomentsStore.loadSessionInfo(defaults: defaults), info)
        defaults.removePersistentDomain(forName: "SessionMomentsTests")
    }

    func testSameNeedRendersOneCurrentWording() {
        let needs = [Need(id: "take-baby", authorText: "Take the baby, please", cueWording: "", priority: 0)]
        let first = moment(at: Date(), text: "old wording one")
        let second = moment(at: Date(), text: "old wording two")
        XCTAssertEqual(MomentWords.text(for: first, needs: needs), "Take the baby, please")
        XCTAssertEqual(MomentWords.text(for: second, needs: needs), "Take the baby, please")
    }

    func testMissingNeedFallsBackToSnapshot() {
        let gone = moment(at: Date(), needID: "removed-need", text: "what she said then")
        XCTAssertEqual(MomentWords.text(for: gone, needs: []), "what she said then")
    }
}
