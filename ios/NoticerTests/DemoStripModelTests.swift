import Foundation
import NoticerCore
import NoticerPipeline
import XCTest

/// Demo mode wiring: off means off, the idle timer round-trips, speech
/// captions land verbatim, the word list never drifts, and demo never
/// changes what the engine produces.
final class DemoStripModelTests: XCTestCase {
    private let demoKey = "noticer.demo.mode"
    private let keys = [
        "noticer.needs.v1",
        "noticer.moments.v1",
        "noticer.cueHistory.v1",
        "noticer.session.v1",
        "noticer.pausedNeeds.v1",
    ]
    private var stashed: [String: Data] = [:]
    private var hadDemoKey = false
    private var stashedDemo = false

    override func setUp() {
        super.setUp()
        stashed = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            UserDefaults.standard.data(forKey: key).map { (key, $0) }
        })
        hadDemoKey = UserDefaults.standard.object(forKey: demoKey) != nil
        stashedDemo = UserDefaults.standard.bool(forKey: demoKey)
    }

    override func tearDown() {
        for key in keys {
            if let data = stashed[key] {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if hadDemoKey {
            UserDefaults.standard.set(stashedDemo, forKey: demoKey)
        } else {
            UserDefaults.standard.removeObject(forKey: demoKey)
        }
        super.tearDown()
    }

    private func babyNeed() -> Need {
        Need(id: "take-baby", authorText: "take the baby", cueWording: "Take the baby?", priority: 0)
    }

    private func openBaby(at: Date) -> OpenNeedState {
        OpenNeedState(
            needID: "take-baby",
            latchedAt: at,
            cueDeadline: at.addingTimeInterval(10),
            hardCapAt: at.addingTimeInterval(40),
            evidenceAt: at,
            handsBusy: false,
            awaitingRecheck: false,
            choreID: nil,
            pendingWearerAction: nil
        )
    }

    private func view(at: Date, log: [EngineEvent], cues: [Cue] = [], modelCalls: Int = 1, resolution: ResolutionOutcome? = nil) -> SessionView {
        SessionView(
            now: at,
            needs: [babyNeed()],
            openNeeds: [openBaby(at: at)],
            cues: cues,
            log: log,
            modelCalls: modelCalls,
            lastResolution: resolution
        )
    }

    @MainActor
    func testToggleOffRendersNothing() {
        UserDefaults.standard.set(false, forKey: demoKey)
        // The real property does not round-trip in hostless tests, so the
        // assertions below observe the seam the model drives.
        let original = DemoIdleTimer.setDisabled
        addTeardownBlock { DemoIdleTimer.setDisabled = original }
        var calls: [Bool] = []
        DemoIdleTimer.setDisabled = { calls.append($0) }

        let model = PhoneSessionModel()
        model.mode = .replay
        model.selectedReplayID = "missing"

        model.start()
        let at = Date()
        model.applyLiveState(view(at: at, log: [EngineEvent(kind: .needLatched, needID: "take-baby", at: at)]))

        XCTAssertTrue(model.demoStrip.items.isEmpty)
        XCTAssertFalse(model.demoModeActive)
        XCTAssertNil(model.demoChip)
        XCTAssertNil(model.speaker.onSpeechStart)
        XCTAssertEqual(calls, [true], "the session keeps the screen on; demo off adds no extra write")
        model.stop()
        XCTAssertEqual(calls, [true, false])
    }

    @MainActor
    func testToggleOnCollectsAndRestoresIdleTimer() {
        UserDefaults.standard.set(true, forKey: demoKey)
        let original = DemoIdleTimer.setDisabled
        addTeardownBlock { DemoIdleTimer.setDisabled = original }
        var calls: [Bool] = []
        DemoIdleTimer.setDisabled = { calls.append($0) }

        let model = PhoneSessionModel()
        model.mode = .replay
        model.selectedReplayID = "missing"

        model.start()
        XCTAssertTrue(model.demoModeActive)
        XCTAssertEqual(calls, [true])
        XCTAssertTrue(model.demoStrip.items.isEmpty)

        let at = Date()
        model.applyLiveState(view(at: at, log: [EngineEvent(kind: .needLatched, needID: "take-baby", at: at)]))
        XCTAssertEqual(model.demoStrip.items.map(\.text), ["Noticed: take the baby", "Head start: 10s for you"])

        model.endDemoSession()
        XCTAssertEqual(calls, [true], "releasing demo leaves the session's screen demand in place")
        XCTAssertTrue(model.keepsScreenOn)
        XCTAssertFalse(model.demoModeActive)

        model.stop()
        XCTAssertEqual(calls, [true, false])
        XCTAssertFalse(model.demoModeActive)
        XCTAssertFalse(model.keepsScreenOn)
        XCTAssertFalse(model.demoStrip.items.isEmpty, "strip stays for the recording")
    }

    @MainActor
    func testHeadStartCountdownAnchoredToWallTime() throws {
        UserDefaults.standard.set(true, forKey: demoKey)
        let model = PhoneSessionModel()
        model.mode = .replay
        model.selectedReplayID = "missing"
        model.start()

        // Replay stamps events on the engine clock, which can lag the wall
        // clock the strip renders against. The countdown must still start
        // live instead of expiring instantly to "Head start: 0s for you".
        let eventAt = Date().addingTimeInterval(-30)
        model.applyLiveState(view(at: Date(), log: [EngineEvent(kind: .needLatched, needID: "take-baby", at: eventAt)]))

        let row = try XCTUnwrap(model.demoStrip.items.last { $0.style == .headStart })
        XCTAssertEqual(row.text, "Head start: 10s for you")
        let endsAt = try XCTUnwrap(row.countdownEndsAt)
        XCTAssertGreaterThan(endsAt.timeIntervalSinceNow, 5, "countdown already expired")
        XCTAssertLessThan(endsAt.timeIntervalSinceNow, 11, "countdown runs past the grant")
        model.stop()
    }

    @MainActor
    func testSpeechStartCaptionMatchesSpoken() async {
        UserDefaults.standard.set(true, forKey: demoKey)
        let model = PhoneSessionModel()
        model.mode = .replay
        model.selectedReplayID = "missing"

        model.start()
        // Replays caption whispers from cueFired, so the speech callback
        // stays unset there; drive the real wiring like a fake speaker.
        XCTAssertNil(model.speaker.onSpeechStart)
        let speak = "Her plate's getting cold, maybe take the baby?"
        model.demoSpeechCallback()(speak)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(model.demoStrip.items.last?.text, "Whispered: “\(speak)”")
        XCTAssertEqual(model.demoStrip.items.last?.style, .whisper)
        model.stop()
    }

    func testDemoWordsMatchWhisperValidator() {
        XCTAssertEqual(DemoStripMapper.forbiddenWords, NeedsIntentWhisper.forbiddenWords)
    }

    @MainActor
    func testNoEngineSideEffects() {
        let at = Date()
        let cue = Cue(id: "cue-1", needID: "take-baby", text: "Take the baby?", kind: .whisper, createdAt: at)
        let latched = EngineEvent(kind: .needLatched, needID: "take-baby", at: at)
        let fired = EngineEvent(kind: .cueFired, needID: "take-baby", at: at, detail: "whisper")
        let shared = EngineEvent(kind: .caughtHimself, needID: "take-baby", at: at, detail: "shared-finish")
        let skip = EngineEvent(kind: .skip, needID: nil, at: at, detail: "idle-bucket")
        let views = [
            view(at: at, log: [latched], modelCalls: 1),
            view(at: at, log: [latched, fired], cues: [cue], modelCalls: 2),
            view(
                at: at,
                log: [latched, fired, shared],
                cues: [cue],
                modelCalls: 3,
                resolution: ResolutionOutcome(
                    needID: "take-baby",
                    sharedWithPartner: true,
                    partnerSeenSecondsAgo: 38,
                    wearerActedSecondsAgo: 3,
                    at: at
                )
            ),
            view(at: at, log: [latched, fired, shared, skip], cues: [cue], modelCalls: 3),
        ]

        func drain(demoOn: Bool) -> PhoneSessionModel {
            UserDefaults.standard.set(demoOn, forKey: demoKey)
            let model = PhoneSessionModel()
            model.moments = []
            model.mode = .replay
            model.selectedReplayID = "missing"
            model.start()
            for view in views {
                model.applyLiveState(view)
            }
            model.stop()
            return model
        }

        let off = drain(demoOn: false)
        let on = drain(demoOn: true)

        // The demo path ran: rows collected, chip unset (no timing lines here).
        XCTAssertTrue(off.demoStrip.items.isEmpty)
        XCTAssertFalse(on.demoStrip.items.isEmpty)
        XCTAssertTrue(on.demoStrip.items.contains { $0.style == .whisper })

        // Everything the engine produced is identical with demo on and off.
        // Moment stamps and session ids come from the wall clock and start,
        // so they are excluded; everything derived is compared.
        XCTAssertEqual(
            off.sessionLog.entries.map { "\($0.tag)|\($0.message)" },
            on.sessionLog.entries.map { "\($0.tag)|\($0.message)" }
        )
        XCTAssertEqual(
            off.moments.map { "\($0.needID)|\($0.kind)|\($0.text)|\($0.sharedWithPartner ?? false)" },
            on.moments.map { "\($0.needID)|\($0.kind)|\($0.text)|\($0.sharedWithPartner ?? false)" }
        )
        XCTAssertEqual(off.liveEventTimeline, on.liveEventTimeline)
        XCTAssertEqual(off.liveDroppedNeedIDs, on.liveDroppedNeedIDs)
    }
}
