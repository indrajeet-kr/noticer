import Foundation
import NoticerAgent
import NoticerCore
import NoticerPipeline
import XCTest

/// The compressed replay timeline: one beat for the opening, one for every
/// frame where a strip row appears or the phase changes, and a final
/// outcome beat. Played against every bundled scenario.
final class ReplayTimelineTests: XCTestCase {
    func testOpeningBeatIsFrameZero() {
        let beats = ReplayTimeline.beats(
            times: [0, 2, 4],
            rowCounts: [0, 0, 0],
            statusKeys: ["listening", "listening", "listening"]
        )
        XCTAssertEqual(beats.count, 2)
        XCTAssertEqual(beats[0].frameIndex, 0)
        XCTAssertEqual(beats[0].scenarioTime, 0, accuracy: 0.001)
        XCTAssertEqual(beats[0].dwell, 1, accuracy: 0.001)
        XCTAssertEqual(beats[1].frameIndex, 2)
    }

    func testBeatsLandOnRowAndPhaseChanges() {
        let beats = ReplayTimeline.beats(
            times: [0, 2, 4, 6, 8, 10],
            rowCounts: [0, 1, 1, 2, 2, 3],
            statusKeys: ["listening", "noticed", "headstart", "headstart", "cue", "gotit"]
        )
        XCTAssertEqual(beats.map(\.frameIndex), [0, 1, 2, 3, 4, 5])
        let total = beats.map(\.dwell).reduce(0, +)
        XCTAssertEqual(total, 15, accuracy: 1)
        for beat in beats.dropFirst().dropLast() {
            XCTAssertGreaterThanOrEqual(beat.dwell, 1.5)
            XCTAssertLessThanOrEqual(beat.dwell, 2.5)
        }
        XCTAssertGreaterThanOrEqual(beats.last!.dwell, 2.5)
    }

    func testQuietTailStillEndsOnTheOutcomeBeat() {
        let beats = ReplayTimeline.beats(
            times: [0, 2, 4, 6, 8, 10, 12],
            rowCounts: [0, 1, 1, 1, 1, 1, 1],
            statusKeys: ["listening", "noticed", "headstart", "headstart", "headstart", "headstart", "headstart"]
        )
        XCTAssertEqual(beats.map(\.frameIndex), [0, 1, 2, 6])
        XCTAssertEqual(beats.map(\.dwell).reduce(0, +), 15, accuracy: 1)
    }

    func testClampedOffsetStaysInsideTheRun() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            ReplayTimeline.clampedOffset(at: start.addingTimeInterval(10), start: start, duration: 95),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReplayTimeline.clampedOffset(at: start.addingTimeInterval(-5), start: start, duration: 95),
            0,
            accuracy: 0.001
        )
        // A row stamped by another run clamps instead of exploding.
        XCTAssertEqual(
            ReplayTimeline.clampedOffset(at: start.addingTimeInterval(1_563_544 * 60 + 52), start: start, duration: 95),
            95,
            accuracy: 0.001
        )
    }

    @MainActor
    func testAllScenariosPlayInFifteenSecondsAndEndOnTheirOutcome() async throws {
        let expectedEndings = [
            "water-table-self-catch": "gotit",
            "take-baby-self-catch": "gotit",
            "water-table-she-handled-it": "shehandled",
            "water-table-whisper": "gotit",
            "take-baby-whisper": "gotit",
            "refill-water-whisper": "gotit",
            "water-table-whisper-she-handled-it": "shehandled",
        ]
        let directory = try XCTUnwrap(ScenarioLibrary.sourceTreeDirectory())
        let scenarios = try ScenarioLibrary.load(directory: directory)
        XCTAssertEqual(Set(scenarios.map(\.scenarioID)), Set(expectedEndings.keys))

        for scenario in scenarios {
            let frames = try await play(scenario: scenario)
            let beats = ReplayTimeline.beats(
                times: frames.map(\.time),
                rowCounts: frames.map { $0.rows.count },
                statusKeys: frames.map(\.phase)
            )
            XCTAssertFalse(beats.isEmpty, scenario.scenarioID)
            XCTAssertEqual(beats.first!.frameIndex, 0, scenario.scenarioID)
            XCTAssertEqual(
                beats.map(\.dwell).reduce(0, +), 15, accuracy: 1,
                "\(scenario.scenarioID) totals 15 s"
            )
            for beat in beats.dropFirst().dropLast() {
                XCTAssertGreaterThanOrEqual(beat.dwell, 1.5, scenario.scenarioID)
                XCTAssertLessThanOrEqual(beat.dwell, 2.5, scenario.scenarioID)
            }
            XCTAssertGreaterThanOrEqual(beats.last!.dwell, 2.5, scenario.scenarioID)

            // Every strip row appears, in order.
            var firstFrame: [String: Int] = [:]
            for (index, frame) in frames.enumerated() {
                for row in frame.rows where firstFrame[row] == nil {
                    firstFrame[row] = index
                }
            }
            XCTAssertFalse(firstFrame.isEmpty, "\(scenario.scenarioID) has strip rows")
            let beatFrames = Set(beats.map(\.frameIndex))
            var lastSeen = -1
            for frame in firstFrame.values.sorted() {
                XCTAssertTrue(beatFrames.contains(frame), "\(scenario.scenarioID) row at frame \(frame)")
                XCTAssertGreaterThanOrEqual(frame, lastSeen, scenario.scenarioID)
                lastSeen = frame
            }

            // Shown times move forward inside the run.
            let duration = frames.map(\.time).max() ?? 0
            var previous = -1.0
            for beat in beats {
                XCTAssertGreaterThanOrEqual(beat.scenarioTime, previous, scenario.scenarioID)
                XCTAssertGreaterThanOrEqual(beat.scenarioTime, 0, scenario.scenarioID)
                XCTAssertLessThanOrEqual(beat.scenarioTime, duration + 0.001, scenario.scenarioID)
                previous = beat.scenarioTime
            }

            // Ends on the outcome and stays there.
            XCTAssertEqual(frames.last!.phase, expectedEndings[scenario.scenarioID], scenario.scenarioID)
            if scenario.scenarioID.contains("whisper"), !scenario.scenarioID.contains("self-catch") {
                var whisperAt: (frame: Int, row: Int)?
                var outcomeAt: (frame: Int, row: Int)?
                for (frameIndex, frame) in frames.enumerated() {
                    for (rowIndex, row) in frame.rows.enumerated() {
                        if row.hasPrefix("Whispered"), whisperAt == nil {
                            whisperAt = (frameIndex, rowIndex)
                        }
                        if (row == "You got it" || row == "She handled it"), outcomeAt == nil {
                            outcomeAt = (frameIndex, rowIndex)
                        }
                    }
                }
                let cue = try XCTUnwrap(whisperAt, "\(scenario.scenarioID) whispers")
                let end = try XCTUnwrap(outcomeAt, "\(scenario.scenarioID) resolves")
                XCTAssertTrue(
                    cue.frame < end.frame || (cue.frame == end.frame && cue.row < end.row),
                    "\(scenario.scenarioID) cues before the outcome"
                )
            }
        }
    }

    @MainActor
    func testCuedAndSheHandledScenariosLeaveMasteryAlone() async throws {
        let directory = try XCTUnwrap(ScenarioLibrary.sourceTreeDirectory())
        let scenarios = try ScenarioLibrary.load(directory: directory)
        for id in [
            "water-table-whisper", "take-baby-whisper", "refill-water-whisper",
            "water-table-she-handled-it", "water-table-whisper-she-handled-it",
        ] {
            let scenario = try XCTUnwrap(scenarios.first { $0.scenarioID == id })
            let playback = try ScenarioPlayback(
                scenario: scenario,
                speaker: RecordingCueSpeaker(),
                timing: scenario.resolvedTiming
            )
            let report = try await playback.run()
            for need in report.needs {
                XCTAssertEqual(need.mastery.score, 0, accuracy: 1e-9, "\(id) \(need.id)")
            }
        }
    }

    // MARK: - Headless playback shaped like the replay precompute

    private struct PlayedFrame {
        var time: TimeInterval
        var rows: [String]
        var phase: String
    }

    @MainActor
    private func play(scenario: ReplayScenario) async throws -> [PlayedFrame] {
        let playback = try ScenarioPlayback(
            scenario: scenario,
            speaker: RecordingCueSpeaker(),
            timing: scenario.resolvedTiming
        )
        var origin: Date?
        var seenLogCount = 0
        var seenCueIDs = Set<String>()
        var rows: [String] = []
        var outcome: String?
        var openSince: Date?
        var played: [PlayedFrame] = []
        _ = try await playback.run(pace: nil) { [scenario] step, view in
            let start = origin ?? view.now
            origin = start
            let headStartSeconds: (String) -> TimeInterval? = { needID in
                view.openNeeds.first(where: { $0.needID == needID }).map {
                    $0.cueDeadline.timeIntervalSince($0.latchedAt)
                }
            }
            for cue in step.spoken where !seenCueIDs.contains(cue.id) {
                seenCueIDs.insert(cue.id)
                if cue.kind != .chime {
                    rows.append(DemoStripMapper.stepCaption(spoken: cue.text, isRepeat: cue.isRepeat))
                }
            }
            for event in view.log.dropFirst(seenLogCount) {
                if let row = DemoStripMapper.item(
                    for: event,
                    needs: scenario.needs,
                    headStartSeconds: headStartSeconds
                ) {
                    rows.append(row.0)
                }
                if event.kind == .needLatched,
                    let followUp = DemoStripMapper.headStartFollowUp(
                        for: event,
                        headStartSeconds: headStartSeconds,
                        now: view.now
                    ) {
                    rows.append(followUp.0)
                }
                if event.kind == .caughtHimself {
                    outcome = "gotit"
                } else if event.kind == .resolvedByOther {
                    outcome = "shehandled"
                }
            }
            seenLogCount = view.log.count
            if view.openNeeds.first != nil, openSince == nil {
                openSince = view.now
            } else if view.openNeeds.first == nil {
                openSince = nil
            }
            played.append(PlayedFrame(
                time: view.now.timeIntervalSince(start),
                rows: rows,
                phase: Self.phase(
                    outcome: outcome,
                    cues: view.cues,
                    open: view.openNeeds.first,
                    openSince: openSince,
                    needs: scenario.needs,
                    now: view.now
                )
            ))
        }
        return played
    }

    /// The same phase rules the replay status line uses: sticky outcome,
    /// fresh cue, head start only before its deadline, then noticed.
    private static func phase(
        outcome: String?,
        cues: [Cue],
        open: OpenNeedState?,
        openSince: Date?,
        needs: [Need],
        now: Date
    ) -> String {
        if let outcome {
            return outcome
        }
        if let cue = cues.last, now.timeIntervalSince(cue.createdAt) <= 8 {
            return "cue"
        }
        if let open {
            if now >= open.cueDeadline {
                return "noticed"
            }
            if let since = openSince, now.timeIntervalSince(since) < 3 {
                return "noticed"
            }
            return "headstart"
        }
        return "listening"
    }
}
