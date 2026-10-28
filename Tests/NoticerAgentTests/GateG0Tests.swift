import Foundation
import NoticerCore
import XCTest
@testable import NoticerAgent

final class GateG0Tests: XCTestCase {
    func testHelpListsTheKnobs() async {
        let lines = LineBuffer()
        let code = await GateG0.run(arguments: ["noticer-gate-g0", "--help"], environment: [:], write: lines.add)
        XCTAssertEqual(code, 0)
        let text = lines.text().joined(separator: "\n")
        XCTAssertTrue(text.contains("META_API_KEY"))
        XCTAssertTrue(text.contains("reasoning_effort"))
        XCTAssertTrue(text.contains("max_tokens"))
        XCTAssertTrue(text.contains("muse-spark-1.3"))
        XCTAssertTrue(text.contains("api.meta.ai"))
        XCTAssertTrue(text.contains("none"))
    }

    func testMissingKeyAndRejectedReasoningDoNotCallTheModel() async {
        let lines = LineBuffer()
        let missing = await GateG0.run(arguments: ["noticer-gate-g0"], environment: [:], write: lines.add)
        XCTAssertEqual(missing, 1)
        XCTAssertTrue(lines.text().contains { $0.contains("META_API_KEY") })

        let client = FixedModelClient(verdict: ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment()
        ))
        let refused = await GateG0.run(
            arguments: ["noticer-gate-g0", "--reasoning-effort", "none"],
            environment: ["META_API_KEY": "test-key-not-real"],
            client: client,
            write: lines.add
        )
        XCTAssertEqual(refused, 1)
        XCTAssertEqual(client.calls(), 0)
        XCTAssertTrue(lines.text().contains { $0.contains("none") })

        let lowCap = await GateG0.run(
            arguments: ["noticer-gate-g0", "--max-tokens", "10"],
            environment: [:],
            client: client,
            write: lines.add
        )
        XCTAssertEqual(lowCap, 1)
        XCTAssertEqual(client.calls(), 0)
    }

    func testProbePassesOnlyWhenAToolCallComesBack() async throws {
        let passLines = LineBuffer()
        let passClient = FixedModelClient(verdict: ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(needID: "gate-g0")
        ))
        let pass = await GateG0.run(
            arguments: ["noticer-gate-g0", "--repeats", "2", "--base-url", "https://api.meta.ai/v1"],
            environment: [:],
            client: passClient,
            write: passLines.add
        )
        XCTAssertEqual(pass, 0)
        XCTAssertEqual(passClient.calls(), 2)
        let passText = passLines.text()
        XCTAssertTrue(passText.contains("reasoning_effort: low"))
        XCTAssertTrue(passText.contains("max_tokens: 1024"))
        XCTAssertTrue(passText.contains("tool_choice: auto"))
        XCTAssertTrue(passText.contains("endpoint: https://api.meta.ai/v1/chat/completions"))
        XCTAssertTrue(passText.contains("finish_reason: tool_calls"))
        XCTAssertTrue(passText.contains("result: pass"))
        XCTAssertTrue(passText.contains("call: 1"))
        XCTAssertTrue(passText.contains("call: 2"))

        let stopLines = LineBuffer()
        let stop = await GateG0.run(
            arguments: ["noticer-gate-g0"],
            environment: [:],
            client: FixedModelClient(verdict: ModelVerdict(
                finishReason: .stop,
                tool: .reportNoTransition,
                assessment: SceneAssessment()
            )),
            write: stopLines.add
        )
        XCTAssertEqual(stop, 2)
        XCTAssertTrue(stopLines.text().contains("result: no_tool_call"))

        let missingModel = await GateG0.run(
            arguments: ["noticer-gate-g0"],
            environment: [:],
            client: FixedModelClient(error: .modelNotFound),
            write: LineBuffer().add
        )
        XCTAssertEqual(missingModel, 3)

        let truncated = await GateG0.run(
            arguments: ["noticer-gate-g0"],
            environment: [:],
            client: FixedModelClient(error: .truncated),
            write: LineBuffer().add
        )
        XCTAssertEqual(truncated, 4)
    }

    func testProbeKeyframeIsAJPEG() {
        let request = GateG0.probeRequest()
        XCTAssertEqual(request.needs.map(\.id), ["gate-g0"])
        XCTAssertEqual(request.keyframes.count, 1)
        let bytes = request.keyframes[0].jpegData
        XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(Array(bytes.suffix(2)), [0xFF, 0xD9])
    }
}
