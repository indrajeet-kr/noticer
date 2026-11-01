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
            "Move that glass from the baby"
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

    func testRealListSpeaksAShortAction() {
        let rows: [(author: String, cue: String, spoken: String)] = [
            ("eating one-handed, take the baby", "Her plate's getting cold, maybe take the baby?", "Take the baby"),
            ("nursing, no water", "Her water's empty.", "Refill her water"),
            ("Keep water bottle on dining table", "Water on the table helps.", "Set water on the table"),
            ("Pick the kid he is roaming around", "Maybe pick up the little roamer?", "Pick up the little roamer"),
            ("Remove the empty glasses from the dinning table", "", "Remove the empty glasses from the dinning table"),
            ("Help clean the toys from floor", "", "Help clean the toys from floor"),
            ("Fold the mat if on the floor", "", "Fold the mat"),
            // The compiled line has no verb, so her words supply the action.
            ("Fold the mat if on the floor", "The mat is out.", "Fold the mat"),
            ("eating one-handed, take the baby", "She could use a hand.", "Take the baby"),
            ("Pick the kid he is roaming around", "She could use a hand.", "Pick the kid"),
            ("Help clean the toys from floor", "Toys are everywhere.", "Help clean the toys from floor"),
            ("Remove the empty glasses from the dinning table", "The table is crowded.", "Remove the empty glasses from the dinning table"),
        ]
        for row in rows {
            let spoken = SpokenCueForm.line(cueWording: row.cue, authorText: row.author)
            XCTAssertEqual(spoken, row.spoken, "author \(row.author) / cue \(row.cue)")
            assertDoesNotEndOnAFunctionWord(spoken)
        }
    }

    func testRoamingKidMatAndFloorToys() {
        XCTAssertEqual(SpokenCueForm.line(cueWording: "the kid is roaming"), "Pick up the kid")
        XCTAssertEqual(SpokenCueForm.line(cueWording: "toddler in the hall"), "Pick up the kid")
        XCTAssertEqual(SpokenCueForm.line(cueWording: "the baby is fussy"), "Take the baby")
        XCTAssertEqual(SpokenCueForm.line(cueWording: "infant needs a hold"), "Take the baby")
        XCTAssertEqual(SpokenCueForm.line(cueWording: "mat on the floor"), "Fold the mat")
        XCTAssertEqual(SpokenCueForm.line(cueWording: "Toys are on the floor."), "Pick up the toys")
        XCTAssertNotEqual(SpokenCueForm.line(cueWording: "the little roamer"), "Take the baby")
        XCTAssertNotEqual(SpokenCueForm.line(cueWording: "the little roamer"), "Pick up the kid")
    }

    func testClauseCutDropsTheReasonBeforeTheWordLimit() {
        XCTAssertEqual(SpokenCueForm.line(cueWording: "Fold the mat if on the floor"), "Fold the mat")
        XCTAssertEqual(SpokenCueForm.line(cueWording: "Pick the kid he is roaming around"), "Pick the kid")
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Fold the big blue mat if it is on the floor"),
            "Fold the big blue mat"
        )
        assertDoesNotEndOnAFunctionWord(SpokenCueForm.line(cueWording: "Fold the mat if on the floor"))
        assertDoesNotEndOnAFunctionWord(SpokenCueForm.line(cueWording: "Pick the kid he is roaming around"))
    }

    private func assertDoesNotEndOnAFunctionWord(_ spoken: String, file: StaticString = #filePath, line: UInt = #line) {
        let last = spoken.split(whereSeparator: \.isWhitespace).last.map(String.init)?.lowercased() ?? ""
        XCTAssertFalse(Self.functionWords.contains(last), "\(spoken) ends on a function word", file: file, line: line)
    }

    private static let functionWords: Set<String> = [
        "a", "an", "the", "her", "his", "some", "that", "to", "of", "from", "for",
        "on", "in", "with", "and", "or", "at", "by",
        "if", "when", "while", "because", "so", "but", "he", "she", "it", "is",
        "that's", "thats", "who", "which", "since", "until", "before", "after",
    ]

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

    func testSpokenLinesStayInsideThreeToEightWords() {
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

    func testCompoundActionSpeaksItsFirstAction() {
        XCTAssertEqual(
            SpokenCueForm.line(authorText: "Close the lid of trash can and move it to the corner"),
            "Close the lid of trash can"
        )
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: "Close the lid of trash can and move it to the corner"),
            "Close the lid of trash can"
        )
        XCTAssertEqual(SpokenCueForm.line(authorText: "Refill her water"), "Refill her water")
        XCTAssertEqual(
            SpokenCueForm.line(authorText: "Ask me for heat pack while on couch"),
            "Offer her the heat pack"
        )
    }

    func testHeatPackAndBlanketSpeakActions() {
        XCTAssertEqual(
            SpokenCueForm.line(authorText: "Ask me for heat pack while on couch"),
            "Offer her the heat pack"
        )
        XCTAssertEqual(
            SpokenCueForm.line(
                cueWording: "Maybe ask if she wants heat pack?",
                authorText: "Ask me for heat pack while on couch"
            ),
            "Offer her the heat pack"
        )
        XCTAssertEqual(
            SpokenCueForm.line(authorText: "Ask me for a blanket"),
            "Bring her a blanket"
        )
    }

    func testNewKeywordActions() {
        let rows: [(input: String, spoken: String)] = [
            ("heating pad for her back", "Offer her the heat pack"),
            ("needs a warm compress", "Offer her the heat pack"),
            ("she wants a snack", "Bring her a snack"),
            ("food is getting cold", "Bring her a snack"),
            ("diaper blowout", "Change the diaper"),
            ("needs burping", "Burp the baby"),
            ("Ask me for warm socks", "Offer her warm socks"),
            ("Maybe ask if she wants tea?", "Offer her tea"),
        ]
        for row in rows {
            XCTAssertEqual(SpokenCueForm.line(authorText: row.input), row.spoken, row.input)
        }
    }

    func testRealListStaysInsideTwoToFiveWords() {
        let rows: [(author: String, cue: String, spoken: String)] = [
            ("eating one-handed, take the baby", "Her plate's getting cold, maybe take the baby?", "Take the baby"),
            ("nursing, no water", "Her water's empty.", "Refill her water"),
            ("Keep water bottle on dining table", "Water on the table helps.", "Set water on the table"),
            ("Pick the kid he is roaming around", "Maybe pick up the little roamer?", "Pick up the little roamer"),
            ("Remove the empty glasses from the dinning table", "", "Remove the empty glasses from the dinning table"),
            ("Help clean the toys from floor", "", "Help clean the toys from floor"),
            ("Fold the mat if on the floor", "", "Fold the mat"),
            ("Ask me for heat pack while on couch", "Maybe ask if she wants heat pack?", "Offer her the heat pack"),
        ]
        for row in rows {
            let spoken = SpokenCueForm.line(cueWording: row.cue, authorText: row.author)
            XCTAssertEqual(spoken, row.spoken, "author \(row.author)")
            let count = spoken.split(whereSeparator: \.isWhitespace).count
            XCTAssertGreaterThanOrEqual(count, 2, spoken)
            XCTAssertLessThanOrEqual(count, CueSpeechTuning.spokenWordLimit, spoken)
        }
    }

    func testArbitraryAuthorTextNeverSpeaksZeroOrOneWord() {
        // Degenerate input falls back to the model whisper, never to a bare word.
        let whisper = "The room is cold"
        let authors = [
            "Ask me", "Help", "Me", "Water?", "",
            "I", "my", "me", "a", "the", "?", "!", "...", "   ",
            "Ask", "ask", "ASK ME FOR", "for", "her", "she",
            "warm", "socks", "please", "now", "heat", "pack",
            "nursing", "water", "baby", "toddler", "mat", "toys",
            "Can you", "Could you", "Maybe", "Please help",
            "the the the the the the", "if if if", "because",
            "12345", "💧", "Water!!", " E ", "x",
            "Supercalifragilisticexpialidocious", "a b c d e f g h",
            "Fold", "Take", "Bring her", "Offer",
        ]
        XCTAssertEqual(authors.count, 50)
        for author in authors {
            let spoken = SpokenCueForm.line(cueWording: whisper, authorText: author)
            let count = spoken.split(whereSeparator: \.isWhitespace).count
            XCTAssertGreaterThanOrEqual(count, 2, "author \(author.debugDescription) -> \(spoken.debugDescription)")
            XCTAssertLessThanOrEqual(count, CueSpeechTuning.spokenWordLimit, spoken)
        }
        XCTAssertEqual(
            SpokenCueForm.line(cueWording: whisper, authorText: ""),
            SpokenCueForm.line(cueWording: whisper),
            "empty input falls back to the whisper"
        )
    }

    func testRepeatKeepsTheSameTwoPlusWordLine() {
        let spoken = SpokenCueForm.line(authorText: "Ask me for heat pack while on couch")
        XCTAssertEqual(spoken, "Offer her the heat pack")
        XCTAssertEqual(SpokenCueForm.repeatLine(spoken), "Again, Offer her the heat pack")
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
        XCTAssertFalse(events(.resolvedByOther).isEmpty)
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
