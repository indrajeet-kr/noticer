import Foundation
import XCTest
@testable import NoticerCore

/// Saved Muse calls load back into the exact `ModelRequest` they were
/// saved from, JPEG bytes included, so a later eval tool can replay them.
final class CapturedCallTests: XCTestCase {
    private func request() -> ModelRequest {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return ModelRequest(
            keyframes: [
                Keyframe(
                    id: "kf-1",
                    capturedAt: base,
                    ageSeconds: 2,
                    episodeID: "ep-1",
                    sharpness: 0.81,
                    jpegData: Data([0xFF, 0xD8, 0x01, 0x02])
                ),
                Keyframe(
                    id: "kf-2",
                    capturedAt: base.addingTimeInterval(1),
                    ageSeconds: 0,
                    episodeID: "ep-1",
                    jpegData: Data([0xFF, 0xD8, 0x03])
                ),
            ],
            needs: [
                Need(
                    id: "take-baby",
                    authorText: "eating one-handed, take the baby",
                    cueWording: "Take the baby?",
                    visualCondition: "partner eating while holding the baby",
                    handledCondition: "partner eating with both hands free",
                    selfNoticeSignal: "wearer_taking_baby",
                    priority: 0
                ),
            ],
            openNeeds: [
                OpenNeedContext(
                    needID: "take-baby",
                    latchedSecondsAgo: 12,
                    cueSpoken: false,
                    problemCondition: "partner eating while holding the baby",
                    resolutionSignal: "partner eating with both hands free"
                ),
            ],
            purpose: .latch,
            unpromptedStartedIDs: ["refill-water"]
        )
    }

    private func verdict() -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: "take-baby",
                sustainedAcrossStrip: true,
                partnerStateEvidence: ["eating_one_handed"],
                wearerHandsOccupied: false,
                confidence: 0.81
            )
        )
    }

    private func writeCall(
        _ request: ModelRequest,
        verdict: ModelVerdict?,
        error: String?,
        to folder: URL
    ) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let captured = CapturedRequest(request: request, model: "test-model", promptHash: "abc123")
        try CapturedCall.jsonEncoder().encode(captured)
            .write(to: folder.appendingPathComponent("request.json"))
        for frame in request.keyframes {
            try frame.jpegData.write(to: folder.appendingPathComponent("kf-\(frame.id).jpg"))
        }
        if let verdict {
            try CapturedCall.jsonEncoder().encode(CapturedVerdict(verdict: verdict, latencyMs: 250.5))
                .write(to: folder.appendingPathComponent("verdict.json"))
        }
        if let error {
            try CapturedCall.jsonEncoder().encode(CapturedError(error: error))
                .write(to: folder.appendingPathComponent("error.json"))
        }
    }

    private func tempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testLoadRebuildsRequestWithImageBytes() throws {
        let base = try tempDir("roundtrip")
        let original = request()
        try writeCall(original, verdict: verdict(), error: nil, to: base.appendingPathComponent("call-0001"))

        let calls = try CapturedCall.load(directory: base)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "call-0001")
        XCTAssertEqual(calls.first?.modelRequest, original)
        XCTAssertEqual(calls.first?.modelRequest.keyframes.map(\.jpegData), original.keyframes.map(\.jpegData))
        XCTAssertEqual(calls.first?.verdict?.verdict, verdict())
        XCTAssertEqual(calls.first?.verdict?.latencyMs, 250.5)
        XCTAssertNil(calls.first?.error)
        XCTAssertEqual(calls.first?.request.model, "test-model")
        XCTAssertEqual(calls.first?.request.promptHash, "abc123")
    }

    func testErrorFolderLoadsWithNilVerdict() throws {
        let base = try tempDir("error")
        try writeCall(request(), verdict: nil, error: "boom", to: base.appendingPathComponent("call-0001"))

        let calls = try CapturedCall.load(directory: base)

        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls.first?.verdict)
        XCTAssertEqual(calls.first?.error?.error, "boom")
        XCTAssertEqual(calls.first?.modelRequest, request())
    }

    func testMissingVerdictLoadsWithNilVerdict() throws {
        let base = try tempDir("bare")
        try writeCall(request(), verdict: nil, error: nil, to: base.appendingPathComponent("call-0001"))

        let calls = try CapturedCall.load(directory: base)

        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls.first?.verdict)
        XCTAssertNil(calls.first?.error)
    }

    func testWrittenFilesContainNoSecrets() throws {
        let encoder = CapturedCall.jsonEncoder()
        let files = [
            try encoder.encode(CapturedRequest(request: request(), model: "test-model", promptHash: "abc123")),
            try encoder.encode(CapturedVerdict(verdict: verdict(), latencyMs: 1)),
            try encoder.encode(CapturedSession(
                appVersion: "0.1.0",
                deviceModel: "iPhone",
                systemVersion: "18.0",
                mode: "live",
                needs: request().needs
            )),
        ]
        for data in files {
            let text = String(data: data, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("Authorization"), text)
            XCTAssertFalse(text.contains("Bearer"), text)
        }
    }
}
