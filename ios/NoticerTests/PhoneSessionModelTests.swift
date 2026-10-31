import Foundation
import NoticerCore
import XCTest

/// Model wiring: observable cue history, session boundaries, latest-session
/// tonight, and learning reset. MainActor-serialized, so `start()` is still
/// running synchronously after it returns — no suspension, no flakiness.
final class PhoneSessionModelTests: XCTestCase {
    private let keys = [
        "noticer.needs.v1",
        "noticer.moments.v1",
        "noticer.cueHistory.v1",
        "noticer.session.v1",
        "noticer.pausedNeeds.v1",
    ]
    private var stashed: [String: Data] = [:]

    override func setUp() {
        super.setUp()
        stashed = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            UserDefaults.standard.data(forKey: key).map { (key, $0) }
        })
    }

    override func tearDown() {
        for key in keys {
            if let data = stashed[key] {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    @MainActor
    private func stubNeeds() -> [Need] {
        [
            Need(id: "take-baby", authorText: "take the baby", cueWording: "Take the baby?", priority: 0),
            Need(id: "refill-water", authorText: "nursing, no water", cueWording: "Her water's empty.", priority: 1),
        ]
    }

    @MainActor
    func testRecordCueHistoryUpdatesObservableHistory() {
        let model = PhoneSessionModel()
        model.cueHistory = [:]

        model.recordCueHistory()

        XCTAssertEqual(CueHistoryStore.count(on: Date(), in: model.cueHistory), 1)
        XCTAssertEqual(
            CueHistoryStore.count(on: Date(), in: CueHistoryStore.load()), 1,
            "the observable history must persist through the store"
        )
    }

    @MainActor
    func testStartStopRecordsSessionBoundaries() {
        let model = PhoneSessionModel()
        model.mode = .replay
        model.selectedReplayID = "missing"

        model.start()
        XCTAssertTrue(model.isRunning)
        let id = model.currentSessionID
        XCTAssertNotNil(id)
        XCTAssertNotNil(model.sessionStartedAt)
        XCTAssertNil(model.sessionEndedAt)

        model.stop()
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.sessionEndedAt)

        let info = SessionMomentsStore.loadSessionInfo()
        XCTAssertEqual(info?.id, id)
        XCTAssertEqual(info?.startedAt, model.sessionStartedAt)
        XCTAssertEqual(info?.endedAt, model.sessionEndedAt)
    }

    @MainActor
    func testTonightMomentsShowsLatestSessionOnly() {
        let model = PhoneSessionModel()
        let old = UUID()
        let new = UUID()
        let base = Date()
        model.moments = [
            SessionMoment(at: base.addingTimeInterval(-7200), needID: "take-baby", kind: .cued, text: "old", sessionID: old),
            SessionMoment(at: base.addingTimeInterval(-100), needID: "refill-water", kind: .selfNotice, text: "new", sessionID: new),
        ]

        XCTAssertEqual(model.tonightMoments.map(\.needID), ["refill-water"])
    }

    @MainActor
    func testTonightCueCountAgreesWithWins() {
        let model = PhoneSessionModel()
        model.needs = stubNeeds()
        let session = UUID()
        let now = Date()
        // History says 1 (a pre-history cue survives only in moments);
        // the latest session holds 2 cue-kind moments.
        model.cueHistory = [CueHistoryStore.dayKey(for: now): 1]
        model.moments = [
            SessionMoment(at: now.addingTimeInterval(-300), needID: "take-baby", kind: .cued, text: "take the baby", sessionID: session),
            SessionMoment(at: now.addingTimeInterval(-200), needID: "refill-water", kind: .nudge, text: "nursing, no water", sessionID: session),
            SessionMoment(at: now.addingTimeInterval(-100), needID: "take-baby", kind: .selfNotice, text: "take the baby", sessionID: session),
        ]
        model.currentSessionID = session
        model.sessionStartedAt = now.addingTimeInterval(-600)

        XCTAssertEqual(model.tonightMoments.count, 3)
        XCTAssertEqual(model.tonightCueCount, 2, "session moments win over the day count")
        XCTAssertTrue(CueHistoryStore.hasSession(on: now, in: model.cueHistory), "dots agree")
        let prior = CueHistoryStore.mostRecentPriorDay(before: model.tonightSessionDay, in: model.cueHistory)?.count
        XCTAssertEqual(CueWeekSentence.text(tonight: model.tonightCueCount, prior: prior), "2 cues tonight.")
    }

    @MainActor
    func testResetLearningProgress() {
        let model = PhoneSessionModel()
        model.needs = [
            Need(
                id: "take-baby",
                authorText: "take the baby",
                cueWording: "Take the baby?",
                priority: 0,
                mastery: MasteryState(score: 0.8, consecutiveSelfNotices: 3, consecutiveMisses: 0)
            ),
        ]

        let stash = model.resetLearningProgress()

        XCTAssertNotNil(stash)
        XCTAssertEqual(model.needs.first?.mastery.score, 0)
        XCTAssertEqual(model.needs.first?.mastery.consecutiveSelfNotices, 0)
        XCTAssertEqual(model.needs.first?.id, "take-baby")
        XCTAssertEqual(model.needs.first?.authorText, "take the baby")

        model.restoreMastery(stash!)
        XCTAssertEqual(model.needs.first?.mastery.score, 0.8)
        XCTAssertEqual(model.needs.first?.mastery.consecutiveSelfNotices, 3)
    }

    @MainActor
    func testResetLearningProgressRefusedWhileRunning() {
        let model = PhoneSessionModel()
        model.mode = .replay
        model.selectedReplayID = "missing"

        model.start()
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.resetLearningProgress(), "reset must be refused while a session runs")
        model.stop()
    }
}
