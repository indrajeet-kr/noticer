import Foundation
import XCTest
@testable import NoticerAgent
import NoticerCore

/// Part 1: the model names its evidence. Schema shape on every tool,
/// decode-time validation against the request strip, and prompt sentences.
final class EvidenceFieldsTests: XCTestCase {
    // MARK: - Schema

    func testEvidenceFieldsAreOnEveryTool() {
        for tool in ToolCatalog.all {
            let names = Set(tool.parameterPropertyNames())
            XCTAssertTrue(
                names.contains(AssessmentField.evidenceKeyframeIDs),
                "\(tool.name.rawValue) is missing evidence_keyframe_ids"
            )
            XCTAssertTrue(
                names.contains(AssessmentField.newestAnchorState),
                "\(tool.name.rawValue) is missing newest_anchor_state"
            )
        }
    }

    func testEvidenceFieldShapes() throws {
        let latch = try XCTUnwrap(ToolCatalog.definition(named: .latchNeedHypothesis))
        guard case .object(let entry) = latch.chatCompletionsEntry,
              case .object(let function)? = entry["function"],
              case .object(let parameters)? = function["parameters"],
              case .object(let properties)? = parameters["properties"] else {
            return XCTFail("latch tool has no parameter properties")
        }
        XCTAssertEqual(
            properties[AssessmentField.evidenceKeyframeIDs],
            .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
            ])
        )
        XCTAssertEqual(
            properties[AssessmentField.newestAnchorState],
            .object([
                "type": .string("string"),
                "enum": .array(["unmet", "handled", "not_visible", "unclear"].map(JSONValue.string)),
            ])
        )
    }

    func testEvidenceFieldsStayOptional() {
        // Empty or omitted when no frame shows the anchor and its unmet
        // condition, so the catalog required sets do not grow.
        for tool in ToolCatalog.all {
            let required = Set(tool.requiredParameterNames())
            XCTAssertFalse(required.contains(AssessmentField.evidenceKeyframeIDs))
            XCTAssertFalse(required.contains(AssessmentField.newestAnchorState))
        }
    }

    // MARK: - Decoding

    func testKnownEvidenceIDsAreKept() throws {
        let parsed = try ChatCompletionResponse.parseArguments(
            .object([
                "need_id": .string("take-baby"),
                "evidence_keyframe_ids": .array([.string("kf-1"), .string("kf-2")]),
                "newest_anchor_state": .string("unmet"),
            ]),
            knownKeyframeIDs: ["kf-1", "kf-2"]
        )
        XCTAssertEqual(parsed.assessment.evidenceKeyframeIDs, ["kf-1", "kf-2"])
        XCTAssertEqual(parsed.assessment.newestAnchorState, .unmet)
    }

    func testUnknownEvidenceIDsAreDroppedAndReported() throws {
        var reported: [(String, String?)] = []
        let parsed = try ChatCompletionResponse.parseArguments(
            .object([
                "need_id": .string("take-baby"),
                "evidence_keyframe_ids": .array([.string("kf-1"), .string("kf-9")]),
            ]),
            knownKeyframeIDs: ["kf-1"],
            onUnknownEvidenceID: { reported.append(($0, $1)) }
        )
        XCTAssertEqual(parsed.assessment.evidenceKeyframeIDs, ["kf-1"])
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.0, "kf-9")
        XCTAssertEqual(reported.first?.1, "take-baby")
    }

    func testBlankEvidenceIDsDropSilently() throws {
        var reported = 0
        let parsed = try ChatCompletionResponse.parseArguments(
            .object([
                "evidence_keyframe_ids": .array([.string("  "), .string("kf-1 ")]),
            ]),
            knownKeyframeIDs: ["kf-1"],
            onUnknownEvidenceID: { _, _ in reported += 1 }
        )
        XCTAssertEqual(parsed.assessment.evidenceKeyframeIDs, ["kf-1"])
        XCTAssertEqual(reported, 0)
    }

    func testNullPlaceholdersDecodeToNil() throws {
        let parsed = try ChatCompletionResponse.parseArguments(.object([
            "evidence_keyframe_ids": .string("null"),
            "newest_anchor_state": .string("null"),
        ]))
        XCTAssertNil(parsed.assessment.evidenceKeyframeIDs)
        XCTAssertNil(parsed.assessment.newestAnchorState)
    }

    func testMissingEvidenceFieldsDecodeToNil() throws {
        // Old fixtures carry neither field and must still decode.
        let parsed = try ChatCompletionResponse.parseArguments(.object([
            "need_id": .string("take-baby"),
            "sustained_across_strip": .bool(true),
        ]))
        XCTAssertNil(parsed.assessment.evidenceKeyframeIDs)
        XCTAssertNil(parsed.assessment.newestAnchorState)
    }

    func testClientDropsUnknownIDsAndLogsModelLine() async throws {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let request = ModelRequest(
            keyframes: [
                Keyframe(id: "kf-1", capturedAt: now, ageSeconds: 2, episodeID: "g", jpegData: jpeg),
                Keyframe(id: "kf-2", capturedAt: now, ageSeconds: 0, episodeID: "g", jpegData: jpeg),
            ],
            needs: []
        )
        let body = completionBody(
            finishReason: "tool_calls",
            toolName: "latch_need_hypothesis",
            arguments: toolArguments([
                "need_id": "take-baby",
                "evidence_keyframe_ids": ["kf-2", "kf-9"],
                "newest_anchor_state": "unmet",
            ]),
            usage: sampleUsage()
        )
        let transport = ScriptedTransport(steps: [.response(httpJSON(200, body))])
        let lines = LineBuffer()
        let client = MuseSparkModelClient(
            apiKey: "test-key-not-real",
            transport: transport,
            sleeper: RecordingSleeper(),
            jitter: ZeroJitter(),
            log: { tag, message in lines.add("[\(tag)] \(message)") }
        )
        let verdict = try await client.complete(request)
        XCTAssertEqual(verdict.assessment.evidenceKeyframeIDs, ["kf-2"])
        XCTAssertEqual(verdict.assessment.newestAnchorState, .unmet)
        XCTAssertEqual(lines.text(), ["[MODEL] evidence-id-unknown id=kf-9 need=take-baby"])
    }

    func testSceneTextShowsCompoundConditionsOnlyForCompoundNeeds() {
        let single = Need(
            id: "take-baby",
            authorText: "eating one-handed, take the baby",
            cueWording: "Take the baby?",
            visualCondition: "partner eating while holding the baby",
            handledCondition: "partner eating with both hands free",
            priority: 0
        )
        var compound = single
        compound.id = "trash-can-lid"
        compound.unknownCondition = "placement cannot be judged when the corner is out of view"
        compound.handledCondition = "lid closed AND can in the designated corner"

        let singleText = ChatCompletionRequest.sceneText(ModelRequest(keyframes: [], needs: [single]))
        XCTAssertFalse(singleText.contains("handled_when="))
        XCTAssertFalse(singleText.contains("unknown_when="))
        XCTAssertFalse(singleText.contains("parts="))

        let compoundText = ChatCompletionRequest.sceneText(ModelRequest(keyframes: [], needs: [compound]))
        XCTAssertTrue(compoundText.contains("handled_when=lid closed AND can in the designated corner"))
        XCTAssertTrue(compoundText.contains(
            "unknown_when=placement cannot be judged when the corner is out of view"
        ))
        XCTAssertTrue(compoundText.contains("parts=lid:handled|unmet,placement:handled|unmet|unknown"))
    }

    // MARK: - Prompt

    func testDeveloperPromptNamesTheEvidenceRules() {
        let prompt = DeveloperPrompt.text
        XCTAssertTrue(prompt.contains("Each keyframe row shows its id and age in seconds."))
        XCTAssertTrue(prompt.contains(
            "evidence_keyframe_ids lists frames showing the need's anchor AND its unmet condition together"
        ))
        XCTAssertTrue(prompt.contains(
            "newest_anchor_state is the newest frame's anchor state: unmet, handled, not_visible, unclear."
        ))
        XCTAssertTrue(prompt.contains("Evidence shows what is visible, not confidence."))
        XCTAssertTrue(prompt.contains(
            "Urgent: latch from one frame when it is at most 2.5 s old, newest_anchor_state is unmet, confidence at least 0.75."
        ))
        XCTAssertTrue(prompt.contains(
            "report each part as `<part_id>_handled`, `<part_id>_unmet` or `<part_id>_unknown`"
        ))
        XCTAssertTrue(prompt.contains("Use only the listed part ids."))
    }
}
