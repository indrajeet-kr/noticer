import Foundation
import NoticerCore
import NoticerPipeline
import XCTest

/// Model wiring: observable cue history, session boundaries, today's Tonight
/// list, and learning reset. MainActor-serialized, so `start()` is still
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
    func testTonightMomentsAreTodayAndStillOnHerList() {
        let model = PhoneSessionModel()
        model.needs = stubNeeds()
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.startOfDay(for: now)
        let morning = start.addingTimeInterval(10 * 3600 + 15 * 60)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let morningSession = UUID()
        let eveningSession = UUID()
        model.moments = [
            SessionMoment(at: morning, needID: "clean-floor-toys", kind: .cued, text: "Clean the floor toys are everywhere", sessionID: morningSession),
            SessionMoment(at: morning.addingTimeInterval(60), needID: "take-baby", kind: .selfNotice, text: "old wording", sessionID: morningSession),
            SessionMoment(at: now, needID: "refill-water", kind: .cued, text: "water", sessionID: eveningSession),
            SessionMoment(at: yesterday, needID: "refill-water", kind: .cued, text: "yesterday", sessionID: UUID()),
        ]

        let active = Set(model.needs.map(\.id))
        let expected = TonightList.select(model.moments, at: \.at, needID: \.needID, activeNeedIDs: active, now: now)
        XCTAssertEqual(model.tonightMoments.map(\.id), expected.map(\.id))
        let shown = model.tonightMoments.map(\.needID)
        XCTAssertEqual(Set(shown), ["take-baby", "refill-water"])
        XCTAssertFalse(shown.contains("clean-floor-toys"))
        // One selection for the timeline. It does not branch on isRunning,
        // so the rows match after Stop.
        XCTAssertFalse(model.isRunning)
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

    @MainActor
    func testSharedFinishShowsYouFinishedIt() throws {
        let model = PhoneSessionModel()
        model.moments = []
        let at = Date()
        model.applyLiveState(SessionView(
            now: at,
            needs: [],
            openNeeds: [],
            cues: [],
            log: [EngineEvent(kind: .caughtHimself, needID: "take-baby", at: at, detail: "shared-finish")],
            modelCalls: 1,
            lastResolution: ResolutionOutcome(
                needID: "take-baby",
                sharedWithPartner: true,
                partnerSeenSecondsAgo: 38,
                wearerActedSecondsAgo: 3,
                at: at
            )
        ))

        let moment = try XCTUnwrap(model.moments.last)
        XCTAssertEqual(moment.sharedWithPartner, true)
        XCTAssertEqual(SessionStatus.gotIt(needName: "take-baby", shared: true).word, "You finished it")
        XCTAssertEqual(SessionStatus.gotIt(needName: "take-baby", shared: true).line, "Nice teamwork.")
        XCTAssertEqual(
            SessionCircleWords.text(for: .gotIt(needName: "take-baby", shared: true)),
            "You finished it. Nice teamwork."
        )
        XCTAssertEqual(
            PhoneSessionModel.describe(EngineEvent(kind: .caughtHimself, needID: "take-baby", at: at, detail: "shared-finish")),
            "You finished it take-baby. She started, you wrapped it up."
        )
        XCTAssertTrue(model.sessionLog.entries.contains {
            $0.message.contains("sharedFinish take-baby partnerSeen=38s wearerActed=3s")
        })
    }

    @MainActor
    func testSoloStillYouGotIt() throws {
        let model = PhoneSessionModel()
        model.moments = []
        let at = Date()
        let event = EngineEvent(kind: .caughtHimself, needID: "take-baby", at: at, detail: "before-cue")
        model.applyLiveState(SessionView(
            now: at,
            needs: [],
            openNeeds: [],
            cues: [],
            log: [event],
            modelCalls: 1
        ))

        let moment = try XCTUnwrap(model.moments.last)
        XCTAssertEqual(moment.kind, .selfNotice)
        XCTAssertNotEqual(moment.sharedWithPartner, true)
        XCTAssertEqual(SessionStatus.gotIt(needName: "take-baby", shared: false).word, "You got it")
        XCTAssertEqual(SessionStatus.gotIt(needName: "take-baby", shared: false).line, "Nice catch.")
        XCTAssertEqual(
            SessionCircleWords.text(for: .gotIt(needName: "take-baby", shared: false)),
            "You got it. Nice catch."
        )
        XCTAssertEqual(PhoneSessionModel.describe(event), "Caught it himself take-baby.")
        XCTAssertFalse(model.sessionLog.entries.contains { $0.message.contains("sharedFinish") })
    }

    @MainActor
    func testSharedFinishCopyHasNoForbiddenWords() {
        let lines = [
            "You finished it",
            "Nice teamwork.",
            "You finished it. Nice teamwork.",
            "You finished it take-baby. She started, you wrapped it up.",
            "sharedFinish take-baby partnerSeen=38s wearerActed=3s",
            SessionStatus.gotIt(needName: "take-baby", shared: true).word,
            SessionStatus.gotIt(needName: "take-baby", shared: true).line,
            SessionCircleWords.text(for: .gotIt(needName: "take-baby", shared: true)),
            PhoneSessionModel.describe(EngineEvent(
                kind: .caughtHimself,
                needID: "take-baby",
                at: Date(),
                detail: "shared-finish"
            )),
        ]
        for line in lines {
            XCTAssertNil(NeedsIntentWhisper.forbiddenWord(in: line), line)
        }
    }

    @MainActor
    func testSkipEventsReachSessionLogThrottled() {
        let model = PhoneSessionModel()
        let t0 = Date()
        let first = EngineEvent(kind: .skip, needID: nil, at: t0, detail: "idle-bucket")
        let repeatDetail = EngineEvent(kind: .skip, needID: nil, at: t0.addingTimeInterval(1), detail: "idle-bucket")
        let other = EngineEvent(kind: .skip, needID: nil, at: t0.addingTimeInterval(2), detail: "min-gap purpose=latch")
        model.applyLiveState(SessionView(now: t0, needs: [], openNeeds: [], cues: [], log: [first], modelCalls: 1))
        model.applyLiveState(SessionView(
            now: t0.addingTimeInterval(1),
            needs: [],
            openNeeds: [],
            cues: [],
            log: [first, repeatDetail],
            modelCalls: 1
        ))
        model.applyLiveState(SessionView(
            now: t0.addingTimeInterval(2),
            needs: [],
            openNeeds: [],
            cues: [],
            log: [first, repeatDetail, other],
            modelCalls: 1
        ))

        let lines = model.sessionLog.entries.map(\.message)
        XCTAssertEqual(lines.filter { $0.contains("skip idle-bucket") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("skip min-gap purpose=latch") }.count, 1)
    }
}
