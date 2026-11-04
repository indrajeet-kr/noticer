import Foundation
import NoticerAgent
import NoticerCore
import NoticerPipeline
import XCTest

final class ScenarioSchemaTests: XCTestCase {
    private func blank(scenarioID: String = "test") -> ReplayScenario {
        ReplayScenario(
            scenarioID: scenarioID,
            summary: "test",
            needs: [],
            sampleEvery: 2,
            until: 10,
            people: ScriptedSignalGate.mom,
            responses: [],
            expect: ScenarioExpectation()
        )
    }

    func testStillAtReturnsLatestFrameAtOrBeforeTime() {
        var scenario = blank()
        scenario.frames = [
            ScenarioStill(t: 0, image: "water-table/0001.jpg"),
            ScenarioStill(t: 4, image: "water-table/0002.jpg"),
            ScenarioStill(t: 8, image: "water-table/0003.jpg"),
        ]
        XCTAssertEqual(scenario.still(at: 0)?.image, "water-table/0001.jpg")
        XCTAssertEqual(scenario.still(at: 3.9)?.image, "water-table/0001.jpg")
        XCTAssertEqual(scenario.still(at: 4)?.image, "water-table/0002.jpg")
        XCTAssertEqual(scenario.still(at: 100)?.image, "water-table/0003.jpg")
        XCTAssertNil(scenario.still(at: -1))
        XCTAssertNil(blank().still(at: 5))

        var shuffled = blank()
        shuffled.frames = [
            ScenarioStill(t: 0, image: "a.jpg"),
            ScenarioStill(t: 6, image: "b.jpg"),
            ScenarioStill(t: 4, image: "c.jpg"),
        ]
        XCTAssertEqual(shuffled.still(at: 6)?.image, "b.jpg")
        XCTAssertEqual(shuffled.still(at: 5)?.image, "c.jpg")
    }

    func testTimingDefaultsToStandard() throws {
        XCTAssertEqual(blank().resolvedTiming, .standard)
        let decoded = try JSONDecoder().decode(
            ReplayScenario.self,
            from: Data(
                """
                {"scenario_id":"x","summary":"x","needs":[],"sample_every":2,"until":10,"people":"mom","responses":[],"expect":{}}
                """.utf8
            )
        )
        XCTAssertEqual(decoded.resolvedTiming, .standard)
        XCTAssertEqual(decoded.frames, [])
    }

    func testTimingQuickDecodes() throws {
        let decoded = try JSONDecoder().decode(
            ReplayScenario.self,
            from: Data(
                """
                {"scenario_id":"x","summary":"x","needs":[],"sample_every":2,"until":10,"people":"mom","responses":[],"expect":{},"timing":"quick","frames":[{"t":0,"image":"a.jpg"}]}
                """.utf8
            )
        )
        XCTAssertEqual(decoded.resolvedTiming, .quick)
        XCTAssertEqual(decoded.frames, [ScenarioStill(t: 0, image: "a.jpg")])
    }

    func testUnknownTimingFailsValidation() {
        var scenario = blank()
        scenario.timingName = "turbo"
        XCTAssertThrowsError(try scenario.validate())
    }

    func testStillsAvailableChecksImageSet() {
        var scenario = blank()
        scenario.frames = [ScenarioStill(t: 0, image: "water-table/0001.jpg")]
        XCTAssertTrue(scenario.stillsAvailable(in: ["water-table/0001.jpg"]))
        XCTAssertFalse(scenario.stillsAvailable(in: []))
        XCTAssertFalse(scenario.stillsAvailable(in: ["other.jpg"]))
        XCTAssertTrue(blank().stillsAvailable(in: []))
    }
}
