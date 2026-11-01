import Foundation
import NoticerCore
import NoticerPipeline
import XCTest

@testable import Noticer

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

    func testOldSavedMomentsDecodeWithoutSharedFlag() throws {
        let json = """
        {"id":"\(UUID().uuidString)","at":\(Date().timeIntervalSince1970),"needID":"take-baby","kind":"selfNotice","text":"take the baby"}
        """.data(using: .utf8)!
        let moment = try JSONDecoder().decode(SessionMoment.self, from: json)
        XCTAssertNil(moment.sharedWithPartner)
    }

    func testSharedMomentRoundTrips() throws {
        let moment = SessionMoment(
            at: Date(),
            needID: "take-baby",
            kind: .selfNotice,
            text: "take the baby",
            sharedWithPartner: true
        )
        let back = try JSONDecoder().decode(SessionMoment.self, from: JSONEncoder().encode(moment))
        XCTAssertEqual(back.sharedWithPartner, true)
        XCTAssertEqual(back, moment)
    }

    @MainActor
    func testCaughtUpgradesTheSameEpisodeInPlace() {
        let model = PhoneSessionModel()
        model.needs = [Need(id: "take-baby", authorText: "Take the baby", cueWording: "", priority: 0)]
        model.moments = []
        let now = Date()
        model.applyLiveState(SessionView(
            now: now,
            needs: [],
            openNeeds: [],
            cues: [],
            log: [EngineEvent(kind: .cueFired, needID: "take-baby", at: now, episodeID: "e1")],
            modelCalls: 1
        ))
        model.applyLiveState(SessionView(
            now: now,
            needs: [],
            openNeeds: [],
            cues: [],
            log: [
                EngineEvent(kind: .cueFired, needID: "take-baby", at: now, episodeID: "e1"),
                EngineEvent(kind: .caughtHimself, needID: "take-baby", at: now, detail: "after-cue", episodeID: "e1"),
            ],
            modelCalls: 1
        ))

        XCTAssertEqual(model.moments.count, 1, "one completed action, one entry")
        XCTAssertEqual(model.moments.first?.kind, .nudge)
        XCTAssertEqual(model.moments.first?.episodeID, "e1")
        XCTAssertTrue(model.sessionLog.activity.contains {
            $0.tag == "TONIGHT" && $0.message == "upgrade need=take-baby episode=e1 cued->nudge"
        })
    }

    @MainActor
    func testUnpromptedCompletionNeverUpgradesAnotherEpisode() {
        let model = PhoneSessionModel()
        model.needs = [Need(id: "take-baby", authorText: "Take the baby", cueWording: "", priority: 0)]
        model.moments = []
        let now = Date()
        model.applyLiveState(SessionView(
            now: now,
            needs: [],
            openNeeds: [],
            cues: [],
            log: [EngineEvent(kind: .cueFired, needID: "take-baby", at: now, episodeID: "e1")],
            modelCalls: 1
        ))
        model.applyLiveState(SessionView(
            now: now,
            needs: [],
            openNeeds: [],
            cues: [],
            log: [
                EngineEvent(kind: .cueFired, needID: "take-baby", at: now, episodeID: "e1"),
                EngineEvent(kind: .selfNoticedUnprompted, needID: "take-baby", at: now),
            ],
            modelCalls: 1
        ))

        XCTAssertEqual(model.moments.map(\.kind), [.cued, .selfNotice])
        XCTAssertEqual(model.moments.filter(\.kind.isWin).count, 1, "only the selfNotice counts")
        XCTAssertNil(model.moments.last?.episodeID)
    }

    func testWinsCountNudgeAndSelfNoticeSeparately() {
        let base = Date()
        let moments = [
            moment(at: base, kind: .cued),
            moment(at: base, kind: .nudge),
            moment(at: base, kind: .selfNotice),
            moment(at: base, kind: .selfNotice),
        ]
        XCTAssertEqual(moments.filter { $0.kind == .selfNotice }.count, 2, "You noticed: 2")
        XCTAssertEqual(moments.filter { $0.kind == .nudge }.count, 1, "After a reminder: 1")
        XCTAssertEqual(moments.filter(\.kind.isWin).count, 3, "cued rows are shown, never counted")
    }

    func testEpisodeIDRoundTripsAndOldRowsDecodeWithoutIt() throws {
        let moment = SessionMoment(
            at: Date(),
            needID: "take-baby",
            kind: .nudge,
            text: "take the baby",
            episodeID: "e3"
        )
        let back = try JSONDecoder().decode(SessionMoment.self, from: JSONEncoder().encode(moment))
        XCTAssertEqual(back.episodeID, "e3")
        XCTAssertEqual(back, moment)

        let json = """
        {"id":"\(UUID().uuidString)","at":\(Date().timeIntervalSince1970),"needID":"take-baby","kind":"cued","text":"take the baby"}
        """.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(SessionMoment.self, from: json).episodeID)
    }
}
