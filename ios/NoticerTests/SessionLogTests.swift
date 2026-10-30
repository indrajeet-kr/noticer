import Foundation
import NoticerCore
import Synchronization
import XCTest

/// Developer-mode transcript: ordering, cap, text format, and the logging
/// model-client decorator (pass-through calls and errors, request + verdict
/// lines for every turn).
@MainActor
final class SessionLogTests: XCTestCase {
    func testAppendOrderAndTextFormat() {
        let log = SessionLog()
        log.append("SESSION", "start mode=live", at: Date(timeIntervalSince1970: 1_700_000_000))
        log.append("MODEL", "call keyframes=2", at: Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries.map(\.tag), ["SESSION", "MODEL"])
        let lines = log.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("2 entries"))
        XCTAssertTrue(lines[1].hasSuffix("[SESSION] start mode=live"))
        XCTAssertTrue(lines[2].hasSuffix("[MODEL] call keyframes=2"))
        XCTAssertEqual(lines[1].prefix(12).filter { $0 == ":" }.count, 2, "HH:mm:ss.SSS stamp")
    }

    func testCapDropsOldest() {
        let log = SessionLog()
        for index in 1...SessionLog.cap + 5 {
            log.append("T", "m\(index)")
        }
        XCTAssertEqual(log.entries.count, SessionLog.cap)
        XCTAssertEqual(log.droppedCount, 5)
        XCTAssertEqual(log.entries.first?.message, "m6")
        XCTAssertTrue(log.text.contains("5 oldest dropped"))
    }

    func testClear() {
        let log = SessionLog()
        log.append("T", "x")
        log.clear()
        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(log.droppedCount, 0)
    }

    func testStoreSavesLatestAndPrunesRuns() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("logstore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<(SessionLogStore.keepRuns + 2) {
            let url = SessionLogStore.save(
                "run \(index)",
                at: start.addingTimeInterval(TimeInterval(index * 60)),
                baseURL: base
            )
            XCTAssertNotNil(url)
        }
        let folder = base.appendingPathComponent(SessionLogStore.folderName, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.filter { $0.hasPrefix("noticer-") }.count, SessionLogStore.keepRuns)
        XCTAssertTrue(files.contains(SessionLogStore.latestName))
        let latest = try String(
            contentsOf: folder.appendingPathComponent(SessionLogStore.latestName),
            encoding: .utf8
        )
        XCTAssertEqual(latest, "run \(SessionLogStore.keepRuns + 1)")
    }

    func testLoggingClientPassesThroughAndLogs() async throws {
        let verdict = ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: "water",
                sustainedAcrossStrip: true,
                partnerInView: false,
                confidence: 0.81
            )
        )
        let recorded = Mutex<[String]>([])
        let client = LoggingModelClient(
            inner: StubModelClient(verdict: verdict),
            log: { tag, message in
                recorded.withLock { $0.append("[\(tag)] \(message)") }
            }
        )
        let request = ModelRequest(
            keyframes: [
                Keyframe(id: "a", capturedAt: Date(), ageSeconds: 0, episodeID: "e", jpegData: Data(repeating: 0, count: 2048)),
                Keyframe(id: "b", capturedAt: Date(), ageSeconds: 4, episodeID: "e", jpegData: Data(repeating: 0, count: 2048)),
            ],
            needs: [Need(id: "water", authorText: "Water", cueWording: "Water.", priority: 0)]
        )
        let returned = try await client.complete(request)
        XCTAssertEqual(returned, verdict)
        let lines = recorded.withLock { $0 }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("keyframes=2"), lines[0])
        XCTAssertTrue(lines[0].contains("needs=[water]"), lines[0])
        XCTAssertTrue(lines[1].contains("latch_need_hypothesis"), lines[1])
        XCTAssertTrue(lines[1].contains("need=water"), lines[1])
        XCTAssertTrue(lines[1].contains("sustained=true"), lines[1])
        XCTAssertTrue(lines[1].contains("partner=false"), lines[1])
    }

    func testLoggingClientPassesErrorsThrough() async {
        struct Boom: Error {}
        let recorded = Mutex<[String]>([])
        let client = LoggingModelClient(
            inner: StubModelClient(verdict: nil, error: Boom()),
            log: { tag, message in
                recorded.withLock { $0.append("[\(tag)] \(message)") }
            }
        )
        let request = ModelRequest(keyframes: [], needs: [])
        do {
            _ = try await client.complete(request)
            XCTFail("expected the error to pass through")
        } catch is Boom {
            let lines = recorded.withLock { $0 }
            XCTAssertEqual(lines.count, 2)
            XCTAssertTrue(lines[1].contains("error:"), lines[1])
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

private struct StubModelClient: ModelClient, @unchecked Sendable {
    var verdict: ModelVerdict?
    var error: Error?

    func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        if let error {
            throw error
        }
        return try XCTUnwrap(verdict)
    }
}
