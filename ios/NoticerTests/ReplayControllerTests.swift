import Foundation
import NoticerAgent
import NoticerCore
import NoticerPipeline
import XCTest

/// Replay playback position: selecting a scenario always starts at 0:00,
/// paused, even when re-selecting the one already loaded.
final class ReplayControllerTests: XCTestCase {
    @MainActor
    func testSelectingScenarioStartsAtZero() async throws {
        let controller = ReplayController()
        controller.scenarios = [makeScenario()]
        controller.select("scenario:test-whisper", timing: .standard, needs: [])
        try await waitForLoad(controller)

        XCTAssertNil(controller.loadError)
        XCTAssertFalse(controller.frames.isEmpty)
        XCTAssertEqual(controller.statuses.count, controller.frames.count)
        XCTAssertEqual(controller.stripSnapshots.count, controller.frames.count)
        XCTAssertEqual(controller.statuses.first, .listening(checking: false))
        XCTAssertFalse(controller.stripSnapshots.flatMap({ $0 }).isEmpty, "the latch row replays")
        XCTAssertNil(controller.currentStillURL, "no stills bundled in tests")
        XCTAssertEqual(controller.index, 0)
        XCTAssertEqual(controller.elapsed, 0)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testReselectingScenarioResetsToZero() async throws {
        let controller = ReplayController()
        controller.scenarios = [makeScenario()]
        controller.select("scenario:test-whisper", timing: .standard, needs: [])
        try await waitForLoad(controller)
        XCTAssertFalse(controller.frames.isEmpty)

        controller.index = controller.frames.count - 1
        controller.select("scenario:test-whisper", timing: .standard, needs: [])
        try await waitForLoad(controller)

        XCTAssertEqual(controller.index, 0)
        XCTAssertEqual(controller.elapsed, 0)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    private func waitForLoad(_ controller: ReplayController) async throws {
        for _ in 0..<200 {
            if !controller.isLoading {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out waiting for replay load")
    }

    private func makeScenario() -> ReplayScenario {
        ReplayScenario(
            scenarioID: "test-whisper",
            summary: "test",
            needs: [
                Need(id: "water-table", authorText: "water", cueWording: "Water?", priority: 0)
            ],
            sampleEvery: 2,
            until: 12,
            people: ScriptedSignalGate.mom,
            responses: [
                ScenarioResponse(
                    fixtureID: "latch",
                    normalized: RecordedModelFixture.NormalizedModelTurn(
                        finishReason: .toolCalls,
                        tool: .latchNeedHypothesis,
                        assessment: SceneAssessment(
                            needID: "water-table",
                            sustainedAcrossStrip: true,
                            partnerStateEvidence: ["seated_at_table"],
                            wearerHandsOccupied: false
                        )
                    )
                ),
                ScenarioResponse(
                    fixtureID: "steady",
                    normalized: RecordedModelFixture.NormalizedModelTurn(
                        finishReason: .toolCalls,
                        tool: .reportNoTransition,
                        assessment: SceneAssessment(
                            needID: "water-table",
                            sustainedAcrossStrip: true,
                            wearerHandsOccupied: false
                        )
                    ),
                    repeats: true
                ),
            ],
            expect: ScenarioExpectation()
        )
    }
}
