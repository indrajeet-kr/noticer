import Foundation
import XCTest
@testable import NoticerCore

final class ContractTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    func testInitialMasteryIsCoaching() {
        let state = MasteryState.initial
        XCTAssertEqual(state.score, 0)
        XCTAssertEqual(state.consecutiveSelfNotices, 0)
        XCTAssertEqual(state.consecutiveMisses, 0)
        XCTAssertEqual(state.phase, .coaching)
    }

    func testPhaseClassifiesWithoutUpdatingTheScore() {
        // Three self-notices from zero land near 0.578, which clears 0.5.
        // This test plants that score. It does not run the update rule.
        let retired = MasteryState(score: 0.578, consecutiveSelfNotices: 3, consecutiveMisses: 0)
        XCTAssertEqual(retired.phase, .retired)

        let quiet = MasteryState(score: 0.578, consecutiveSelfNotices: 2, consecutiveMisses: 0)
        XCTAssertEqual(quiet.phase, .quiet)

        let coaching = MasteryState(score: 0.49, consecutiveSelfNotices: 3, consecutiveMisses: 0)
        XCTAssertEqual(coaching.phase, .coaching)

        // Two misses do not un-retire by themselves.
        let stillRetired = MasteryState(score: 0.6, consecutiveSelfNotices: 3, consecutiveMisses: 2)
        XCTAssertEqual(stillRetired.phase, .retired)
    }

    func testSharedLimitsMatchThePRD() {
        XCTAssertEqual(SessionLimits.defaultHeadStartSeconds, 90)
        XCTAssertEqual(SessionLimits.headStartCapSeconds, 120)
        XCTAssertEqual(SessionLimits.staleEvidenceSeconds, 30)
        XCTAssertEqual(SessionLimits.noPersonKeyframeCloseSeconds, 45)
        XCTAssertEqual(SessionLimits.maxModelCallsPerSession, 300)
        XCTAssertEqual(SessionLimits.maxOpenNeeds, 2)
        XCTAssertEqual(SessionLimits.maxAuthoredNeeds, 6)
        XCTAssertEqual(SessionLimits.cueRateLimitSeconds, 180)
        XCTAssertEqual(SessionLimits.relatchCooldownSeconds, 300)
        XCTAssertEqual(SessionLimits.latchMinIntervalSeconds, 10)
        XCTAssertEqual(SessionLimits.latchMinKeyframes, 2)
        XCTAssertEqual(SessionLimits.latchMinKeyframeSpacingSeconds, 4)
        XCTAssertEqual(SessionLimits.heartbeatSeconds, 8)
        XCTAssertEqual(SessionLimits.visitorPersistenceFrames, 3)
        XCTAssertEqual(SessionLimits.glanceAbsentSeconds, 2)
        XCTAssertEqual(SessionLimits.keyframeBufferSeconds, 60)
        XCTAssertEqual(SessionLimits.requestedFramesPerSecond, 2)
        XCTAssertEqual(CueFadeSpec.selfNoticeStep, 0.25)
        XCTAssertEqual(CueFadeSpec.cueFiredMultiplier, 0.85)
        XCTAssertEqual(CueFadeSpec.quietThreshold, 0.5)
        XCTAssertEqual(CueFadeSpec.retireSelfNoticeStreak, 3)
        XCTAssertEqual(CueFadeSpec.unretireMissStreak, 2)
        XCTAssertEqual(CueFadeSpec.headStartMasteryCoefficient, 2)
    }

    func testManualClockAdvancesWithoutSleeping() {
        let clock = ManualClock(now: instant)
        XCTAssertEqual(clock.now(), instant)
        clock.advance(by: SessionLimits.defaultHeadStartSeconds)
        XCTAssertEqual(clock.now(), instant.addingTimeInterval(90))
    }

    func testSystemClockReturnsADate() {
        let now = SystemClock().now()
        XCTAssertLessThan(abs(now.timeIntervalSinceNow), 5)
    }

    func testReplayFrameSourceEndsAfterTheTape() async throws {
        let frame = CameraFrame(
            capturedAt: instant,
            jpegData: Data([0xFF, 0xD8]),
            width: 8,
            height: 8
        )
        let source = ReplayFrameSource(frames: [frame])
        let first = try await source.nextFrame()
        XCTAssertEqual(first, frame)
        let second = try await source.nextFrame()
        XCTAssertNil(second)
    }

    func testUnlinkedDATSourceThrows() async {
        let source = UnlinkedDATFrameSource()
        do {
            _ = try await source.nextFrame()
            XCTFail("expected the DAT seam to throw")
        } catch FrameSourceError.datSDKNotLinked {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRecordingCueSpeakerStoresTheCue() async throws {
        let speaker = RecordingCueSpeaker()
        let cue = Cue(
            id: "cue-1",
            needID: "eating-one-handed",
            text: "Her plate's getting cold, maybe take the baby?",
            kind: .whisper,
            createdAt: instant
        )
        try await speaker.speak(cue)
        XCTAssertEqual(speaker.spokenCues(), [cue])
        await speaker.stop()
        XCTAssertEqual(speaker.spokenCues(), [cue])
    }

    func testKeyframeCopiesFrameBytes() {
        let frame = CameraFrame(capturedAt: instant, jpegData: Data([1, 2, 3]), width: 4, height: 5)
        let keyframe = Keyframe(id: "k1", frame: frame, ageSeconds: 28, episodeID: "g1", sharpness: nil)
        XCTAssertEqual(keyframe.jpegData, frame.jpegData)
        XCTAssertEqual(keyframe.capturedAt, frame.capturedAt)
        XCTAssertEqual(keyframe.ageSeconds, 28)
    }

    func testAssessmentJSONUsesTheSharedFieldNames() throws {
        let assessment = SceneAssessment(
            needID: "eating-one-handed",
            sustainedAcrossStrip: true,
            partnerStateEvidence: ["eating_one_handed"],
            wearerHandsOccupied: false,
            partnerInView: true,
            wearerHandsVisible: false,
            resolution: .unknown,
            actionCode: ActionCodeExamples.waterGlassPresent,
            confidence: 0.7,
            partnerAsleep: false
        )
        let data = try JSONEncoder().encode(assessment)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(AssessmentField.all))
        let decoded = try JSONDecoder().decode(SceneAssessment.self, from: data)
        XCTAssertEqual(decoded, assessment)
    }

    func testUnknownActionCodeAndResolutionStayIntact() throws {
        let json = Data(#"{"action_code":"not_a_known_code","resolution":"she_handled_it"}"#.utf8)
        let assessment = try JSONDecoder().decode(SceneAssessment.self, from: json)
        XCTAssertEqual(assessment.actionCode, "not_a_known_code")
        XCTAssertEqual(assessment.resolution, Resolution(rawValue: "she_handled_it"))
        XCTAssertFalse(Resolution.recognized.contains(Resolution(rawValue: "she_handled_it")))
    }

    func testUnknownToolNameDoesNotDecode() {
        let data = Data(#""invented_tool""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ToolName.self, from: data))
    }

    func testStopBecomesReportNoTransition() throws {
        let verdict = try ModelTurnNormalizer.verdict(
            finishReason: .stop,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(needID: "water"),
            extensionReason: "hot pan"
        )
        XCTAssertEqual(verdict.tool, .reportNoTransition)
        XCTAssertEqual(verdict.finishReason, .stop)
        XCTAssertEqual(verdict.assessment.needID, "water")
        XCTAssertNil(verdict.extensionReason)
    }

    func testToolCallKeepsTheTool() throws {
        let verdict = try ModelTurnNormalizer.verdict(
            finishReason: .toolCalls,
            tool: .logWearerIntervention,
            assessment: SceneAssessment(actionCode: ActionCodeExamples.wearerHandsReceivingBaby),
            extensionReason: nil
        )
        XCTAssertEqual(verdict.tool, .logWearerIntervention)
        XCTAssertEqual(verdict.assessment.actionCode, ActionCodeExamples.wearerHandsReceivingBaby)
    }

    func testLengthDoesNotInventAVerdict() {
        XCTAssertThrowsError(
            try ModelTurnNormalizer.verdict(finishReason: .length, tool: nil)
        ) { error in
            XCTAssertEqual(error as? ModelContractError, .truncated)
        }
    }

    func testToolCallsWithoutAToolThrow() {
        XCTAssertThrowsError(
            try ModelTurnNormalizer.verdict(finishReason: .toolCalls, tool: nil)
        ) { error in
            XCTAssertEqual(error as? ModelContractError, .toolCallsMissingTool)
        }
    }

    func testFixtureDirectoriesExist() {
        let root = repositoryRoot()
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent(FixtureLayout.clipsDirectory).path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent(FixtureLayout.modelResponsesDirectory).path))
    }
}

func repositoryRoot(file: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: file).deletingLastPathComponent()
    let fileManager = FileManager.default
    while url.path != "/" {
        if fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    fatalError("Package.swift not found from \(file)")
}
