import XCTest
@testable import NoticerAgent

/// Muse Spark 1.3 returned this shape on a live call: `finish_reason` was
/// `tool_calls`, and `content` was the sentence below rather than null.
final class ContentAlongsideToolCallTests: XCTestCase {
    private let liveProse = "Watching for one-handed eating — latching that need."

    func testParserKeepsTheToolWhenContentIsAlsoPresent() async throws {
        let arguments = toolArguments([
            "need_id": "eating-one-handed",
            "sustained_across_strip": true,
            "partner_state_evidence": ["eating_one_handed", "plate_untouched"],
            "wearer_hands_occupied": false,
            "confidence": 0.7,
        ])
        var body = completionBody(
            finishReason: "tool_calls",
            content: liveProse,
            toolName: "latch_need_hypothesis",
            arguments: arguments
        )
        body["object"] = "chat.completion"
        body["model"] = "muse-spark-1.3"
        let encoded = try JSONSerialization.data(withJSONObject: body)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("tool_calls"))
        XCTAssertTrue(text.contains("latch_need_hypothesis"))
        XCTAssertTrue(text.contains("content"))

        let transport = ScriptedTransport(steps: [.response(HTTPResponse(statusCode: 200, headers: [:], body: encoded))])
        let client = liveClient(transport: transport)
        let verdict = try await client.complete(sampleRequest())
        XCTAssertEqual(verdict.finishReason, .toolCalls)
        XCTAssertEqual(verdict.tool, .latchNeedHypothesis)
        XCTAssertEqual(verdict.assessment.needID, "eating-one-handed")
        XCTAssertEqual(verdict.assessment.sustainedAcrossStrip, true)
        XCTAssertEqual(verdict.assessment.partnerStateEvidence, ["eating_one_handed", "plate_untouched"])
        XCTAssertEqual(verdict.assessment.confidence, 0.7)
    }

    func testProseDoesNotStandInForAMissingToolCall() async {
        let transport = ScriptedTransport(steps: [.response(httpJSON(200, completionBody(
            finishReason: "tool_calls",
            content: liveProse
        )))])
        let client = liveClient(transport: transport)
        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected a missing tool call to fail")
        } catch let error as ModelClientError {
            guard case .malformedResponse(let message) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("tool call"))
            XCTAssertFalse(message.contains("content is allowed to be null"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
