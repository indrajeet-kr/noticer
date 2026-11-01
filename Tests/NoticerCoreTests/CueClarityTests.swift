import XCTest
@testable import NoticerCore

final class SpokenCueFormTests: XCTestCase {
    func testShortensReasonPlusActionToTheAction() {
        XCTAssertEqual(
            SpokenCueForm.line(
                cueWording: "Her plate's getting cold, maybe take the baby?",
                authorText: "eating one-handed, take the baby"
            ),
            "Take the baby"
        )
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Maybe offer to take the baby?"),
            "Take the baby"
        )
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Could you move that glass from the baby?"),
            "Move that glass"
        )
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Clear the table a bit?"),
            "Clear the table"
        )
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Hand her a burp cloth?"),
            "Hand her a burp cloth"
        )
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Maybe set water on the table?"),
            "Set water on the table"
        )
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Grab her a water refill?"),
            "Grab her a water refill"
        )
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Maybe bring her some water?"),
            "Bring her some water"
        )
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Maybe pick up the little roamer?"),
            "Pick up the little roamer"
        )
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Check the hallway."),
            "Check the hallway"
        )
    }

    func testStateLinesBecomeActions() {
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Her water's empty.", authorText: "nursing, no water"),
            "Refill her water"
        )
        XCTAssertEqual(SpokenCueForm.line(cueWording: "Her water's low."), "Refill her water")
        XCTAssertEqual(SpokenCueForm.line(cueWording: "Water on the table helps."), "Set water on the table")
        XCTAssertEqual(SpokenCueForm.line(cueWording: "Toys are on the floor."), "Pick up the toys")
        XCTAssertEqual(SpokenCueForm.line(cueWording: "Sink's full."), "Clear the sink")
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "She could use a hand.", authorText: "Take the baby"),
            "Take the baby"
        )
        XCTAssertEqual(SpokenCueForm.line(cueWording: "She could use a hand."), "Lend a hand")
    }

    func testSpokenLinesStayInsideThreeToFiveWords() {
        let lines = [
            "Take the baby",
            "Refill her water",
            "Move that glass",
            "Hand her a burp cloth",
            "Set water on the table",
            "Grab her a water refill",
            "Pick up the little roamer",
        ]
        for line in lines {
            let count = line.split(whereSeparator: \.isWhitespace).count
            XCTAssertGreaterThanOrEqual(count, 3, line)
            XCTAssertLessThanOrEqual(count, CueSpeechTuning.spokenWordLimit, line)
        }
    }

    func testRepeatPrefix() {
        XCTAssertEqual(SpokenCueForm.repeatLine("Refill her water"), "Again, Refill her water")
        XCTAssertTrue(SpokenCueForm.isRepeat("Again, Take the baby"))
        XCTAssertFalse(SpokenCueForm.isRepeat("Take the baby"))
        XCTAssertEqual(SpokenCueForm.repeatLine("Again, Take the baby"), "Again, Take the baby")
    }

    func testSpeechTuningIsSlowerAndCalm() {
        XCTAssertEqual(CueSpeechTuning.speechRateScale, 0.83, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(CueSpeechTuning.speechRateScale, 0.80)
        XCTAssertLessThanOrEqual(CueSpeechTuning.speechRateScale, 0.85)
        XCTAssertLessThan(CueSpeechTuning.repeatRateScale, CueSpeechTuning.speechRateScale)
        XCTAssertEqual(CueSpeechTuning.repeatRateScale, 0.70, accuracy: 0.001)
        XCTAssertLessThan(CueSpeechTuning.pitchMultiplier, 1)
        XCTAssertEqual(CueSpeechTuning.preUtteranceSilence, 0.30, accuracy: 0.001)
        XCTAssertTrue(CueSpeechTuning.leadInChimeDefault)
        XCTAssertLessThan(CueSpeechTuning.leadInAmplitude, 0.25)
        XCTAssertLessThan(CueSpeechTuning.leadInDuration, 0.25)
        XCTAssertEqual(CueSpeechTuning.repeatDelaySeconds, 8, accuracy: 0.001)
        XCTAssertLessThan(CueSpeechTuning.repeatMasteryCutoff, CueFadeSpec.quietThreshold)
    }
}

final class CueRecencyTests: XCTestCase {
    func testRelativePhrases() {
        XCTAssertEqual(CueRecency.phrase(secondsAgo: 0), "just now")
        XCTAssertEqual(CueRecency.phrase(secondsAgo: 0.4), "just now")
        XCTAssertEqual(CueRecency.phrase(secondsAgo: -3), "just now")
        XCTAssertEqual(CueRecency.phrase(secondsAgo: 12), "12s ago")
        XCTAssertEqual(CueRecency.phrase(secondsAgo: 12.9), "12s ago")
        XCTAssertEqual(CueRecency.phrase(secondsAgo: 59.9), "59s ago")
        XCTAssertEqual(CueRecency.phrase(secondsAgo: 60), "1m ago")
        XCTAssertEqual(CueRecency.phrase(secondsAgo: 119), "1m ago")
        XCTAssertEqual(CueRecency.phrase(secondsAgo: 3_600), "1h ago")
    }

    func testGlanceLine() {
        XCTAssertEqual(
            CueRecency.line(spoken: "Refill her water", secondsAgo: 12),
            "Refill her water · 12s ago"
        )
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            CueRecency.line(spoken: "Take the baby", at: at, now: at.addingTimeInterval(12)),
            "Take the baby · 12s ago"
        )
    }
}

final class CueRepeatTests: EngineTestCase {
    func testRepeatFiresOnceAfterTheDelayWhenNothingHappened() throws {
        let cue = try whisperTakeBaby()
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds - 0.5))
        engine.tick()
        XCTAssertEqual(engine.cues.filter(\.isRepeat).count, 0)

        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        let repeats = engine.cues.filter(\.isRepeat)
        XCTAssertEqual(repeats.count, 1)
        let repeatCue = try XCTUnwrap(repeats.first)
        XCTAssertEqual(repeatCue.text, "Again, Take the baby")
        XCTAssertEqual(repeatCue.needID, "take-baby")
        XCTAssertEqual(repeatCue.kind, .whisper)
        XCTAssertEqual(events(.cueFired).filter { $0.detail == CueSpeechTuning.repeatEventDetail }.count, 1)
        XCTAssertEqual(events(.cueFired).filter { $0.detail == CueKind.whisper.rawValue }.count, 1)

        advance(to: repeatCue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertEqual(engine.cues.filter(\.isRepeat).count, 1, "never more than one repeat per cue")
    }

    func testRepeatSuppressedByIntervention() throws {
        try engine.setNeeds([
            Self.takeBaby(selfNotice: ActionCodeExamples.wearerHandsReceivingBaby)
        ])
        let cue = try whisperTakeBaby()
        try handleNext(intervention("take-baby", action: ActionCodeExamples.wearerHandsReceivingBaby))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"], "an intervention holds the repeat; it does not have to close the need")
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty)
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testRepeatSuppressedByPartnerResolution() throws {
        let cue = try whisperTakeBaby()
        try handleNext(partnerResolved("take-baby"))
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertFalse(events(.resolvedByPartner).isEmpty)
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty)
    }

    func testRepeatSuppressedByPartnerHold() throws {
        let cue = try whisperTakeBaby(partnerInView: true)
        if engine.pendingModelCalls.isEmpty {
            // A new keyframe changes the strip, so a check can be in flight
            // without being the one that already returned.
            advance(to: cue.createdAt.addingTimeInterval(1))
            see([mom()], jpeg: 9, sceneActive: true)
        }
        XCTAssertFalse(engine.pendingModelCalls.isEmpty, "a check stays in flight so the hold can apply")
        XCTAssertEqual(engine.pendingModelCalls.contains { call in
            call.request.openNeeds.contains { $0.needID == "take-baby" }
        }, true)
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty, "partner in view and an in-flight check hold the repeat")

        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds + CueSpeechTuning.repeatWindowSeconds))
        engine.tick()
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty, "a hold that outlasts the window does not speak late")
    }

    func testAJumpedClockDoesNotRepeatLate() throws {
        let cue = try whisperTakeBaby()
        advance(to: cue.createdAt.addingTimeInterval(30))
        see([mom()])
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty)
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
    }

    func testRepeatSuppressedByBusyDeferral() throws {
        let cue = try whisperTakeBaby()
        try handleNext(deferral("take-baby"))
        XCTAssertEqual(engine.openNeeds.first?.handsBusy, true)
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty)

        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds + CueSpeechTuning.repeatWindowSeconds))
        engine.tick()
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty)
    }

    func testRepeatSuppressedWhenTheNeedIsRemoved() throws {
        let cue = try whisperTakeBaby()
        try engine.setNeeds([Self.refillWater()])
        XCTAssertFalse(engine.openNeedIDs.contains("take-baby"))
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty)
    }

    func testRepeatSuppressedWhenTheSessionStops() throws {
        let cue = try whisperTakeBaby()
        engine.stopSession()
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty)
        XCTAssertEqual(events(.sessionEnded).last?.detail, "stopped")
    }

    func testRepeatSuppressedWhenPlaybackDisablesRepeats() throws {
        // Plain replay turns this off. Demo mode and a live session leave it on.
        engine.setRepeatsEnabled(false)
        let cue = try whisperTakeBaby()
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty)
        XCTAssertEqual(engine.cues.count, 1)
        _ = cue
    }

    func testRepeatDisabledOnceLearningPassesTheThreshold() throws {
        let practiced = MasteryState(score: 0.45, consecutiveSelfNotices: 2, consecutiveMisses: 0)
        XCTAssertEqual(practiced.phase, .coaching, "the cue itself is still words below 0.5")
        XCTAssertGreaterThanOrEqual(practiced.score, CueSpeechTuning.repeatMasteryCutoff)
        try engine.setNeeds([Self.takeBaby(mastery: practiced)])
        let cue = try whisperTakeBaby()
        XCTAssertEqual(cue.kind, .whisper)
        XCTAssertFalse(cue.text.isEmpty)
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty)
    }

    func testRepeatStillOnAfterOneSelfNotice() throws {
        let once = MasteryState(score: 0.25, consecutiveSelfNotices: 1, consecutiveMisses: 0)
        XCTAssertLessThan(once.score, CueSpeechTuning.repeatMasteryCutoff)
        try engine.setNeeds([Self.takeBaby(mastery: once)])
        let cue = try whisperTakeBaby()
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertEqual(engine.cues.filter(\.isRepeat).count, 1)
    }

    func testQuietPhaseDoesNotRepeat() throws {
        let quiet = MasteryState(score: 0.55, consecutiveSelfNotices: 1, consecutiveMisses: 0)
        try engine.setNeeds([Self.takeBaby(mastery: quiet)])
        let cue = try whisperTakeBaby()
        XCTAssertEqual(cue.kind, .chime)
        advance(to: cue.createdAt.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds))
        engine.tick()
        XCTAssertTrue(engine.cues.filter(\.isRepeat).isEmpty)
    }

    // MARK: - Helpers

    @discardableResult
    private func whisperTakeBaby(partnerInView: Bool = false) throws -> Cue {
        glancePair()
        var verdict = latchVerdict("take-baby")
        if partnerInView {
            verdict.assessment.partnerInView = true
        }
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: verdict)
        let open = try XCTUnwrap(engine.openNeeds.first { $0.needID == "take-baby" })
        try refreshSighting(before: open.cueDeadline)
        advance(to: open.cueDeadline)
        engine.tick()
        return try XCTUnwrap(engine.cues.first { $0.needID == "take-baby" && !$0.isRepeat })
    }

    private func refreshSighting(before date: Date) throws {
        advance(to: date.addingTimeInterval(-20))
        see([mom()])
        if let call = engine.pendingModelCall {
            engine.handle(callID: call.id, verdict: noTransition("take-baby", sustained: true))
        }
    }

    /// Completes the in-flight check if one is waiting, otherwise opens a heartbeat.
    private func handleNext(_ verdict: ModelVerdict) throws {
        if engine.pendingModelCall == nil {
            advance(1)
            see([mom()], handsEdge: true)
        }
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: verdict)
    }
}
