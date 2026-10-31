import Foundation
import XCTest
@testable import NoticerAgent
import NoticerCore

final class FastCuesAgentTests: XCTestCase {

    // MARK: - Payload Bounds (448 px JPEGs)

    func testScoutingPayloadUnderBound() throws {
        let jpeg1 = try loadKeyframeFixture("scout-448-a.jpg")
        let jpeg2 = try loadKeyframeFixture("scout-448-b.jpg")
        let jpeg3 = try loadKeyframeFixture("scout-448-c.jpg")

        XCTAssertGreaterThanOrEqual(jpeg1.count, 12 * 1024)
        XCTAssertGreaterThanOrEqual(jpeg2.count, 12 * 1024)
        XCTAssertGreaterThanOrEqual(jpeg3.count, 12 * 1024)

        let needs = [
            Need(
                id: "take-baby",
                authorText: "eating one-handed, take the baby",
                cueWording: "Maybe offer to take the baby?",
                visualCondition: "partner eating while holding the baby",
                handledCondition: "partner eating with both hands free",
                selfNoticeSignal: "wearer_hands_receiving_baby",
                priority: 0
            ),
            Need(
                id: "couch-water",
                authorText: "Bring her water when she's on the couch",
                cueWording: "Grab her a water refill?",
                visualCondition: "partner on couch with no water within reach",
                handledCondition: "glass of water within her reach",
                selfNoticeSignal: "wearer_handing_water_to_partner",
                priority: 1
            ),
        ]

        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let scoutingRequest = ModelRequest(
            keyframes: [
                Keyframe(id: "kf-1", capturedAt: now.addingTimeInterval(-2), ageSeconds: 2, episodeID: "ep-1", jpegData: jpeg1),
                Keyframe(id: "kf-2", capturedAt: now, ageSeconds: 0, episodeID: "ep-1", jpegData: jpeg2),
            ],
            needs: needs,
            openNeeds: [],
            purpose: .latch
        )
        let scoutingBody = try ChatCompletionRequest.body(
            request: scoutingRequest,
            configuration: MuseSparkConfiguration()
        )
        XCTAssertLessThanOrEqual(
            scoutingBody.count,
            45 * 1024,
            "2-keyframe scouting payload (\(scoutingBody.count) B) must be <= 45 KB"
        )

        let confirmRequest = ModelRequest(
            keyframes: [
                Keyframe(id: "kf-1", capturedAt: now.addingTimeInterval(-4), ageSeconds: 4, episodeID: "ep-1", jpegData: jpeg1),
                Keyframe(id: "kf-2", capturedAt: now.addingTimeInterval(-2), ageSeconds: 2, episodeID: "ep-1", jpegData: jpeg2),
                Keyframe(id: "kf-3", capturedAt: now, ageSeconds: 0, episodeID: "ep-1", jpegData: jpeg3),
            ],
            needs: needs,
            openNeeds: [
                OpenNeedContext(
                    needID: "couch-water",
                    latchedSecondsAgo: 12,
                    cueSpoken: false,
                    problemCondition: "partner on couch with no water within reach",
                    resolutionSignal: "glass of water within her reach; wearer_handing_water_to_partner"
                )
            ],
            purpose: .recheck
        )
        let confirmBody = try ChatCompletionRequest.body(
            request: confirmRequest,
            configuration: MuseSparkConfiguration()
        )
        XCTAssertLessThanOrEqual(
            confirmBody.count,
            70 * 1024,
            "3-keyframe confirm payload (\(confirmBody.count) B) must be <= 70 KB"
        )
    }

    // MARK: - DeveloperPrompt & ToolCatalog Snapshots

    func testDeveloperPromptContainsResolutionExampleAndNarrowedActionCodeRule() {
        let prompt = DeveloperPrompt.text
        XCTAssertTrue(prompt.contains("Example: Open now lists couch-water."))
        XCTAssertTrue(prompt.contains("report_need_resolved need_id=couch-water resolved_by=wearer"))
        XCTAssertTrue(
            prompt.contains("action_code: use a wearer_ code only for an action that helps a listed need, and prefer that need's self_notice_signal exactly.")
        )
    }

    func testDeveloperPromptSnapshot() throws {
        let prompt = DeveloperPrompt.text
        XCTAssertFalse(prompt.contains("water_glass_present"))
        for definition in ToolCatalog.all {
            let encoded = try String(data: JSONEncoder().encode(definition.chatCompletionsEntry), encoding: .utf8) ?? ""
            XCTAssertFalse(encoded.contains("water_glass_present"))
        }
        XCTAssertTrue(prompt.contains("at least 2 keyframes"))
        XCTAssertTrue(prompt.contains("sink"))
        XCTAssertTrue(prompt.contains("sustained_across_strip null"))
        XCTAssertFalse(prompt.contains("ride on any tool"))
        XCTAssertTrue(prompt.contains("Safety needs (marked urgent) latch on one clear keyframe."))

        // Only one place specifies `report_no_transition` rules (no conflicting second paragraph).
        let occurrences = prompt.components(separatedBy: "report_no_transition:").count - 1
        XCTAssertEqual(occurrences, 1)
        XCTAssertFalse(prompt.contains("For report_no_transition, set need_id to null rather than writing a placeholder id."))
    }

    func testProbePromptPinsStrictFields() {
        let probe = GateG0.probeDeveloperPrompt
        XCTAssertTrue(probe.contains("need_id \"gate-g0\""))
        XCTAssertTrue(probe.contains("sustained_across_strip true"))
        XCTAssertTrue(probe.contains("partner_state_evidence [\"eating_one_handed\"]"))
        XCTAssertTrue(probe.contains("wearer_hands_occupied false"))
        XCTAssertTrue(probe.contains("confidence 0.5"))
        XCTAssertTrue(probe.contains("partner_in_view false"))
        XCTAssertTrue(probe.contains("wearer_hands_visible false"))
        XCTAssertTrue(probe.contains("resolution null"))
        XCTAssertTrue(probe.contains("action_code null"))
    }

    // MARK: - sceneText Polarity & Noise Removal

    func testSceneTextHasNoCueWording() {
        let request = ModelRequest(
            keyframes: [],
            needs: [
                Need(
                    id: "take-baby",
                    authorText: "Take the baby",
                    cueWording: "Maybe offer to take the baby?",
                    visualCondition: "partner eating while holding the baby",
                    handledCondition: "partner eating with both hands free",
                    selfNoticeSignal: "wearer_hands_receiving_baby",
                    priority: 0
                )
            ]
        )
        let text = ChatCompletionRequest.sceneText(request)
        XCTAssertFalse(text.contains("cue_wording="))
        XCTAssertFalse(text.contains("Maybe offer to take the baby?"))
    }

    func testSceneTextNeverEchoesProblemAsHandled() {
        let problem = "partner sitting on couch with no water within reach"
        let needWithoutHandled = Need(
            id: "couch-water",
            authorText: "sitting on couch pass me water",
            cueWording: "Grab her a water refill?",
            visualCondition: problem,
            priority: 0
        )
        let request1 = ModelRequest(
            keyframes: [],
            needs: [needWithoutHandled],
            openNeeds: [
                OpenNeedContext(
                    needID: "couch-water",
                    latchedSecondsAgo: 10,
                    cueSpoken: false,
                    problemCondition: problem,
                    resolutionSignal: NeedEngine<SystemClock>.resolutionSignal(for: needWithoutHandled)
                )
            ]
        )
        let text1 = ChatCompletionRequest.sceneText(request1)
        XCTAssertTrue(text1.contains("problem=\(problem)"))
        XCTAssertTrue(text1.contains("handled_when=unspecified"))
        XCTAssertFalse(text1.contains("handled_when=\(problem)"))

        let handled = "glass of water within her reach"
        let needWithHandled = Need(
            id: "couch-water",
            authorText: "sitting on couch pass me water",
            cueWording: "Grab her a water refill?",
            visualCondition: problem,
            handledCondition: handled,
            selfNoticeSignal: "wearer_handing_water_to_partner",
            priority: 0
        )
        let request2 = ModelRequest(
            keyframes: [],
            needs: [needWithHandled],
            openNeeds: [
                OpenNeedContext(
                    needID: "couch-water",
                    latchedSecondsAgo: 10,
                    cueSpoken: false,
                    problemCondition: problem,
                    resolutionSignal: NeedEngine<SystemClock>.resolutionSignal(for: needWithHandled)
                )
            ]
        )
        let text2 = ChatCompletionRequest.sceneText(request2)
        XCTAssertTrue(text2.contains("problem=\(problem)"))
        XCTAssertTrue(text2.contains("handled_when=\(handled); wearer_handing_water_to_partner"))
        XCTAssertFalse(text2.contains("handled_when=\(problem)"))
    }

    func testStringifiedNullAndBoolToolArgumentsDecodeCleanly() throws {
        // Out-of-view reply where the model quotes `"null"` on `sustained_across_strip`,
        // `resolution`, and `action_code`.
        let outOfViewJSON: JSONValue = .object([
            "need_id": .string("null"),
            "sustained_across_strip": .string("null"),
            "partner_in_view": .string("false"),
            "wearer_hands_visible": .string("true"),
            "wearer_hands_occupied": .string("false"),
            "resolution": .string("null"),
            "action_code": .string("null"),
            "confidence": .string("0.85"),
        ])
        let parsedNull = try ChatCompletionResponse.parseArguments(outOfViewJSON)
        XCTAssertNil(parsedNull.assessment.sustainedAcrossStrip)
        XCTAssertEqual(parsedNull.assessment.partnerInView, false)
        XCTAssertEqual(parsedNull.assessment.wearerHandsVisible, true)
        XCTAssertEqual(parsedNull.assessment.wearerHandsOccupied, false)
        XCTAssertNil(parsedNull.assessment.resolution)
        XCTAssertNil(parsedNull.assessment.actionCode)
        XCTAssertEqual(parsedNull.assessment.confidence ?? 0, 0.85, accuracy: 1e-6)

        let sustainedJSON: JSONValue = .object([
            "need_id": .string("water"),
            "sustained_across_strip": .string("true"),
            "resolution": .string("nil"),
            "action_code": .string("none"),
        ])
        let parsedTrue = try ChatCompletionResponse.parseArguments(sustainedJSON)
        XCTAssertEqual(parsedTrue.assessment.sustainedAcrossStrip, true)
        XCTAssertNil(parsedTrue.assessment.resolution)
        XCTAssertNil(parsedTrue.assessment.actionCode)
    }

    func testDeveloperPromptWearerRuleMatchesPlan() {
        let prompt = DeveloperPrompt.text
        XCTAssertTrue(prompt.contains("or the item appeared without the wearer"))
        XCTAssertFalse(prompt.contains("right in front of the wearer"))
    }

    // MARK: - Helpers

    private func loadKeyframeFixture(_ name: String) throws -> Data {
        let root = repositoryRoot()
        let url = root.appendingPathComponent("fixtures/keyframes/\(name)")
        return try Data(contentsOf: url)
    }
}
