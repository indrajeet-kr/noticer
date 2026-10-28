import Foundation
import NoticerCore
import XCTest
@testable import NoticerAgent

final class AgentContractTests: XCTestCase {
    func testCatalogHasTheFiveToolsInPRDOrder() {
        XCTAssertEqual(ToolCatalog.all.map(\.name), ToolName.allCases)
        XCTAssertEqual(Set(ToolCatalog.all.map(\.name)).count, 5)
    }

    func testEachToolIsAStrictFunctionSchema() {
        let expectedRequired: [ToolName: Set<String>] = [
            .latchNeedHypothesis: [
                AssessmentField.needID,
                AssessmentField.sustainedAcrossStrip,
                AssessmentField.partnerStateEvidence,
                AssessmentField.wearerHandsOccupied,
                AssessmentField.confidence,
            ],
            .deferCueWearerBusy: [
                AssessmentField.needID,
                AssessmentField.wearerHandsOccupied,
            ],
            .logWearerIntervention: [
                AssessmentField.needID,
                AssessmentField.actionCode,
            ],
            .requestHeadStartExtension: [
                AssessmentField.needID,
                ToolCatalog.extensionReasonField,
            ],
            .reportNoTransition: [],
        ]

        for tool in ToolCatalog.all {
            guard case .object(let entry) = tool.chatCompletionsEntry else {
                return XCTFail("\(tool.name) is not an object")
            }
            XCTAssertEqual(entry["type"], .some(.string("function")))
            guard case .object(let function)? = entry["function"] else {
                return XCTFail("\(tool.name) has no function body")
            }
            XCTAssertEqual(function["name"], .some(.string(tool.name.rawValue)))
            XCTAssertEqual(function["strict"], .some(.bool(true)))
            XCTAssertFalse(tool.description.isEmpty)
            XCTAssertFalse(tool.allowsAdditionalProperties())
            XCTAssertEqual(Set(tool.requiredParameterNames()), expectedRequired[tool.name])
            XCTAssertTrue(Set(tool.parameterPropertyNames()).isSuperset(of: AssessmentField.all))
        }
    }

    func testExtensionReasonIsOnlyOnTheHeadStartTool() {
        for tool in ToolCatalog.all {
            let hasReason = tool.parameterPropertyNames().contains(ToolCatalog.extensionReasonField)
            XCTAssertEqual(hasReason, tool.name == .requestHeadStartExtension)
        }
    }

    func testChatCompletionsToolsMatchTheCatalog() {
        XCTAssertEqual(ToolCatalog.chatCompletionsTools().count, ToolCatalog.all.count)
    }

    func testRecordedStopFixtureBecomesNoTransition() async throws {
        let client = try RecordedModelClient.load(contentsOf: [fixtureURL("stop-no-transition.json")])
        let verdict = try await client.complete(ModelRequest(keyframes: [], needs: []))
        XCTAssertEqual(verdict.finishReason, .stop)
        XCTAssertEqual(verdict.tool, .reportNoTransition)
    }

    func testRecordedLatchFixtureKeepsTheAssessment() async throws {
        let client = try RecordedModelClient.load(contentsOf: [fixtureURL("latch-need.json")])
        let verdict = try await client.complete(ModelRequest(keyframes: [], needs: []))
        XCTAssertEqual(verdict.tool, .latchNeedHypothesis)
        XCTAssertEqual(verdict.assessment.needID, "eating-one-handed")
        XCTAssertEqual(verdict.assessment.sustainedAcrossStrip, true)
        XCTAssertEqual(verdict.assessment.wearerHandsOccupied, false)
        XCTAssertEqual(verdict.assessment.partnerStateEvidence, ["eating_one_handed", "plate_untouched"])
    }

    func testRecordedTapeEnds() async throws {
        let client = try RecordedModelClient.load(contentsOf: [fixtureURL("stop-no-transition.json")])
        _ = try await client.complete(ModelRequest(keyframes: [], needs: []))
        do {
            _ = try await client.complete(ModelRequest(keyframes: [], needs: []))
            XCTFail("expected the tape to end")
        } catch ModelClientError.recordingExhausted {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTruncatedFixtureDoesNotBecomeAVerdict() {
        XCTAssertThrowsError(
            try RecordedModelClient.load(contentsOf: [fixtureURL("truncated.json")])
        ) { error in
            XCTAssertEqual(error as? ModelContractError, .truncated)
        }
    }

    func testLiveClientDoesNotRunWithoutAKey() async {
        let client = MuseSparkModelClient()
        do {
            _ = try await client.complete(ModelRequest(keyframes: [], needs: []))
            XCTFail("expected a missing key")
        } catch ModelClientError.missingAPIKey(let name) {
            XCTAssertEqual(name, MuseSparkModelClient.apiKeyEnvironmentVariable)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testLiveClientWithAKeyIsStillAStub() async {
        let key = "not-a-real-key"
        let client = MuseSparkModelClient(apiKey: key)
        do {
            _ = try await client.complete(ModelRequest(keyframes: [], needs: []))
            XCTFail("expected the stub to refuse")
        } catch ModelClientError.notImplemented {
            XCTAssertFalse(String(describing: ModelClientError.notImplemented).contains(key))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testBasetenSlotIsRefused() async {
        let client = MuseSparkModelClient(backend: .baseten, apiKey: "not-a-real-key")
        do {
            _ = try await client.complete(ModelRequest(keyframes: [], needs: []))
            XCTFail("expected Baseten to stay out of scope")
        } catch ModelClientError.backendOutOfScope(let backend) {
            XCTAssertEqual(backend, .baseten)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testLiveCallShapeConstants() {
        XCTAssertEqual(MuseSparkModelClient.chatCompletionsURL.host, "api.meta.ai")
        XCTAssertEqual(MuseSparkModelClient.chatCompletionsURL.path, "/v1/chat/completions")
        XCTAssertEqual(MuseSparkModelClient.modelID, "muse-spark-1.3")
        XCTAssertEqual(MuseSparkModelClient.toolChoice, "auto")
        XCTAssertFalse(MuseSparkModelClient.parallelToolCalls)
        XCTAssertEqual(MuseSparkModelClient.reasoningEffortCandidates, ["minimal", "low"])
        XCTAssertFalse(MuseSparkModelClient.reasoningEffortCandidates.contains("none"))
        XCTAssertEqual(MuseSparkModelClient.minimumMaxTokens, 1024)
        XCTAssertEqual(BasetenSparkOpen.modelID, "meta-models/muse-spark-open-1026")
        XCTAssertEqual(BasetenSparkOpen.inferenceRoot.host, "inference.baseten.co")
    }

    func testFixturesDoNotContainSecrets() throws {
        let directory = repositoryRoot().appendingPathComponent(FixtureLayout.modelResponsesDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        XCTAssertFalse(jsonFiles.isEmpty)
        for file in jsonFiles {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            XCTAssertFalse(text.contains("meta_api_key"))
            XCTAssertFalse(text.contains("api_key"))
            XCTAssertFalse(text.contains("sk-"))
            XCTAssertFalse(text.contains("bearer "))
        }
    }

    private func fixtureURL(_ name: String) -> URL {
        repositoryRoot()
            .appendingPathComponent(FixtureLayout.modelResponsesDirectory)
            .appendingPathComponent(name)
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
