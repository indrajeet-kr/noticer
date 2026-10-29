import Foundation
import NoticerAgent
import NoticerCore
import NoticerPipeline
import XCTest

final class EndToEndReplayTests: XCTestCase {
    func testScenariosCoverBothMVPNeeds() throws {
        let scenarios = try loadAll()
        let ids = Set(scenarios.map(\.scenarioID))
        XCTAssertEqual(
            ids,
            ["take-baby-whisper", "refill-water-whisper", "take-baby-self-catch"]
        )
        for scenario in scenarios {
            XCTAssertEqual(scenario.needs.map(\.id), [MVPNeedList.takeBabyID, MVPNeedList.refillWaterID])
            XCTAssertEqual(scenario.needs[0].cueWording, MVPNeedList.takeBaby.cueWording)
            XCTAssertEqual(scenario.needs[1].cueWording, MVPNeedList.refillWater.cueWording)
            XCTAssertEqual(scenario.needs[0].selfNoticeSignal, ActionCodeExamples.wearerHandsReceivingBaby)
            XCTAssertEqual(scenario.needs[1].selfNoticeSignal, ActionCodeExamples.wearerCarryingWaterTowardPartner)
        }
        let cueNeeds = Set(scenarios.compactMap(\.expect.cueNeedID))
        XCTAssertEqual(cueNeeds, [MVPNeedList.takeBabyID, MVPNeedList.refillWaterID])
    }

    func testTakeBabyCueFiresAfterTheHeadStart() async throws {
        let scenario = try load("take-baby-whisper.json")
        let speaker = RecordingCueSpeaker()
        let report = try await play(scenario, speaker: speaker)
        assertPassed(report, expect: scenario.expect)
        let cue = try XCTUnwrap(report.cues.first)
        XCTAssertEqual(cue.needID, MVPNeedList.takeBabyID)
        XCTAssertEqual(cue.kind, .whisper)
        XCTAssertEqual(cue.text, MVPNeedList.takeBaby.cueWording)
        XCTAssertEqual(speaker.spokenCues().map(\.id), [cue.id])
        let latch = try XCTUnwrap(report.latchTimes[MVPNeedList.takeBabyID])
        XCTAssertEqual(cue.createdAt.timeIntervalSince(latch), 90, accuracy: 0.001)
        XCTAssertFalse(report.log.contains { $0.kind == .cueFired && $0.at < latch.addingTimeInterval(90) })
    }

    func testRefillWaterCueFiresAfterTheHeadStart() async throws {
        let scenario = try load("refill-water-whisper.json")
        let speaker = RecordingCueSpeaker()
        let report = try await play(scenario, speaker: speaker)
        assertPassed(report, expect: scenario.expect)
        let cue = try XCTUnwrap(report.cues.first)
        XCTAssertEqual(cue.needID, MVPNeedList.refillWaterID)
        XCTAssertEqual(cue.kind, .whisper)
        XCTAssertEqual(cue.text, MVPNeedList.refillWater.cueWording)
        XCTAssertEqual(speaker.spokenCues().map(\.id), [cue.id])
        let latch = try XCTUnwrap(report.latchTimes[MVPNeedList.refillWaterID])
        XCTAssertEqual(cue.createdAt.timeIntervalSince(latch), 90, accuracy: 0.001)
    }

    func testSelfCatchRaisesMasteryAndDoesNotCue() async throws {
        let scenario = try load("take-baby-self-catch.json")
        let speaker = RecordingCueSpeaker()
        let report = try await play(scenario, speaker: speaker)
        assertPassed(report, expect: scenario.expect)
        XCTAssertTrue(report.cues.isEmpty)
        XCTAssertTrue(speaker.spokenCues().isEmpty)
        XCTAssertEqual(
            report.log.filter { $0.kind == .caughtHimself }.map(\.needID),
            [MVPNeedList.takeBabyID]
        )
        XCTAssertEqual(
            report.log.first { $0.kind == .caughtHimself }?.detail,
            ActionCodeExamples.wearerHandsReceivingBaby
        )
        let mastery = try XCTUnwrap(report.needs.first { $0.id == MVPNeedList.takeBabyID }?.mastery)
        XCTAssertEqual(mastery.score, 0.25, accuracy: 1e-9)
        XCTAssertEqual(mastery.consecutiveSelfNotices, 1)
        XCTAssertEqual(mastery.phase, .coaching)
        let latch = try XCTUnwrap(report.latchTimes[MVPNeedList.takeBabyID])
        XCTAssertGreaterThanOrEqual(report.endedAt.timeIntervalSince(latch), 90)
        XCTAssertFalse(report.log.contains { $0.kind == .cueFired })
    }

    func testExtensionStepIsTheEngineFifteenSeconds() async throws {
        let origin = ScenarioLibrary.origin
        let clock = SessionClock.manual(startingAt: origin)
        let client = ScriptedModelClient(verdicts: [
            latchVerdict(MVPNeedList.takeBabyID),
            extensionVerdict(MVPNeedList.takeBabyID),
        ])
        let pipeline = try SessionPipeline(
            clock: clock,
            needs: MVPNeedList.all,
            model: client,
            speaker: RecordingCueSpeaker()
        )
        XCTAssertEqual(pipeline.extensionStepSeconds, EngineTuning.headStartExtensionStepSeconds)
        XCTAssertEqual(pipeline.extensionStepSeconds, 15)

        let opened = try await ingest(pipeline, clock: clock, origin: origin, t: 0)
        XCTAssertTrue(opened.decisions.isEmpty)
        let latched = try await ingest(pipeline, clock: clock, origin: origin, t: 5)
        guard case .accepted(.latch(let needID)) = latched.decisions.first?.outcome else {
            return XCTFail("expected the gate to accept the latch, got \(latched.decisions)")
        }
        XCTAssertEqual(needID, MVPNeedList.takeBabyID)
        let latchedView = await pipeline.view()
        let open = try XCTUnwrap(latchedView.openNeeds.first)
        XCTAssertEqual(open.cueDeadline.timeIntervalSince(open.latchedAt), 90)

        let extended = try await ingest(pipeline, clock: clock, origin: origin, t: 13)
        guard case .accepted(.headStartExtension(_, let granted, let resulting)) = extended.decisions.last?.outcome else {
            return XCTFail("expected a 15s grant, got \(extended.decisions)")
        }
        XCTAssertEqual(granted, 15)
        XCTAssertEqual(resulting, 105)
        let after = await pipeline.view()
        let window = try XCTUnwrap(after.openNeeds.first)
        XCTAssertEqual(window.cueDeadline.timeIntervalSince(window.latchedAt), 105)
        XCTAssertTrue(after.log.contains { $0.kind == .headStartExtended && $0.needID == MVPNeedList.takeBabyID })
        XCTAssertTrue(after.cues.isEmpty)
    }

    private func play(_ scenario: ReplayScenario, speaker: RecordingCueSpeaker) async throws -> ScenarioReport {
        let playback = try ScenarioPlayback(scenario: scenario, speaker: speaker)
        return try await playback.run()
    }

    private func assertPassed(_ report: ScenarioReport, expect: ScenarioExpectation, file: StaticString = #filePath, line: UInt = #line) {
        let failures = ScenarioCheck.failures(report, expect: expect)
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"), file: file, line: line)
    }

    private func loadAll() throws -> [ReplayScenario] {
        let directory = try XCTUnwrap(ScenarioLibrary.sourceTreeDirectory())
        return try ScenarioLibrary.load(directory: directory)
    }

    private func load(_ name: String) throws -> ReplayScenario {
        let id = (name as NSString).deletingPathExtension
        let scenarios = try loadAll()
        return try XCTUnwrap(scenarios.first { $0.scenarioID == id })
    }

    private func ingest(
        _ pipeline: SessionPipeline,
        clock: SessionClock,
        origin: Date,
        t: TimeInterval
    ) async throws -> PipelineStep {
        let at = origin.addingTimeInterval(t)
        clock.advance(to: at)
        let frame = CameraFrame(
            capturedAt: at,
            jpegData: Data([0xFF, 0xD8, UInt8(Int(t))]),
            width: 8,
            height: 8
        )
        let gate = ScriptedSignalGate.snapshot(at: at, people: ScriptedSignalGate.mom, handsRising: false)
        return try await pipeline.ingest(frame: frame, gate: gate)
    }

    private func latchVerdict(_ id: String) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: id,
                sustainedAcrossStrip: true,
                partnerStateEvidence: ["eating_one_handed"],
                wearerHandsOccupied: false
            )
        )
    }

    private func extensionVerdict(_ id: String) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .requestHeadStartExtension,
            assessment: SceneAssessment(needID: id, wearerHandsOccupied: false),
            extensionReason: "hot pan"
        )
    }
}
