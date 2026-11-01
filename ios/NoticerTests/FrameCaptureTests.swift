import Foundation
import NoticerCore
import Synchronization
import XCTest

/// Frame capture: off means passthrough with no files; on means every
/// call's input and answer land on disk, ordered and capped, with no
/// secrets. Cancellation records nothing.
final class FrameCaptureTests: XCTestCase {
    private func request(frameBytes: [UInt8] = [0xFF, 0xD8, 0x01]) -> ModelRequest {
        ModelRequest(
            keyframes: [
                Keyframe(
                    id: "kf-1",
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    ageSeconds: 2,
                    episodeID: "ep-1",
                    jpegData: Data(frameBytes)
                ),
            ],
            needs: [
                Need(
                    id: "take-baby",
                    authorText: "eating one-handed, take the baby",
                    cueWording: "Take the baby?",
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
            purpose: .latch
        )
    }

    private func verdict() -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: "take-baby",
                sustainedAcrossStrip: true,
                confidence: 0.81
            )
        )
    }

    private func tempBase(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("framecap-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private var sessionStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func lines(_ recorded: borrowing Mutex<[(String, String)]>) -> [String] {
        recorded.withLock { $0.map { "[\($0.0)] \($0.1)" } }
    }

    private func store(
        base: URL,
        log: @escaping @Sendable (String, String) -> Void,
        callCap: Int = FrameCaptureStore.maxCalls,
        byteCap: Int = FrameCaptureStore.maxBytes
    ) -> FrameCaptureStore {
        FrameCaptureStore(
            sessionStart: Date(timeIntervalSince1970: 1_700_000_000),
            mode: "live",
            needs: request().needs,
            log: log,
            baseURL: base,
            callCap: callCap,
            byteCap: byteCap
        )
    }

    func testOffPassesThroughWithoutFiles() async throws {
        let inner = StubCaptureClient(verdict: verdict())
        let client = FrameCaptureModelClient(inner: inner, store: nil, model: "m", promptHash: "h")
        let returned = try await client.complete(request())
        XCTAssertEqual(returned, verdict())
        XCTAssertEqual(inner.calls, 1)
    }

    func testOnWritesCallFolder() async throws {
        let base = try tempBase("on")
        let recorded = Mutex<[(String, String)]>([])
        let capture = store(base: base, log: { tag, message in
            recorded.withLock { $0.append((tag, message)) }
        })
        await capture.begin()
        let client = FrameCaptureModelClient(
            inner: StubCaptureClient(verdict: verdict()),
            store: capture,
            model: "test-model",
            promptHash: "abc123"
        )
        let returned = try await client.complete(request())
        XCTAssertEqual(returned, verdict())
        await capture.drain()

        let dir = base.appendingPathComponent("FrameCapture/\(sessionStamp)/call-0001")
        let jpg = try Data(contentsOf: dir.appendingPathComponent("kf-kf-1.jpg"))
        XCTAssertEqual(jpg, Data([0xFF, 0xD8, 0x01]))
        let captured = try CapturedCall.jsonDecoder().decode(
            CapturedRequest.self,
            from: Data(contentsOf: dir.appendingPathComponent("request.json"))
        )
        XCTAssertEqual(captured.purpose, .latch)
        XCTAssertEqual(captured.needs.map(\.id), ["take-baby"])
        XCTAssertEqual(captured.model, "test-model")
        XCTAssertEqual(captured.promptHash, "abc123")
        XCTAssertEqual(captured.keyframes.map(\.fileName), ["kf-kf-1.jpg"])
        let answer = try CapturedCall.jsonDecoder().decode(
            CapturedVerdict.self,
            from: Data(contentsOf: dir.appendingPathComponent("verdict.json"))
        )
        XCTAssertEqual(answer.verdict, verdict())
        XCTAssertGreaterThan(answer.latencyMs, 0)
        let saved = lines(recorded)
        XCTAssertTrue(saved.contains { $0.contains("[CAPTURE] on dir=FrameCapture/\(sessionStamp)") }, "\(saved)")
        XCTAssertTrue(saved.contains { $0.hasPrefix("[CAPTURE] saved call-0001 kf=1 bytes=") }, "\(saved)")

        // No secrets anywhere in the session folder.
        let session = base.appendingPathComponent("FrameCapture/\(sessionStamp)")
        var jsonURLs = [session.appendingPathComponent("session.json")]
        let calls = try FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)
        for call in calls where call.lastPathComponent.hasPrefix("call-") {
            jsonURLs += try FileManager.default.contentsOfDirectory(at: call, includingPropertiesForKeys: nil)
        }
        for url in jsonURLs where url.pathExtension == "json" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("Authorization"), url.lastPathComponent)
            XCTAssertFalse(text.contains("Bearer"), url.lastPathComponent)
        }
    }

    func testErrorRecordsErrorJsonAndPassesThrough() async throws {
        struct Boom: Error {}
        let base = try tempBase("error")
        let recorded = Mutex<[(String, String)]>([])
        let capture = store(base: base, log: { tag, message in
            recorded.withLock { $0.append((tag, message)) }
        })
        await capture.begin()
        let client = FrameCaptureModelClient(
            inner: StubCaptureClient(verdict: nil, error: Boom()),
            store: capture,
            model: "m",
            promptHash: "h"
        )
        do {
            _ = try await client.complete(request())
            XCTFail("expected the error to pass through")
        } catch is Boom {
            await capture.drain()
            let dir = base.appendingPathComponent("FrameCapture/\(sessionStamp)/call-0001")
            let recorded = try CapturedCall.jsonDecoder().decode(
                CapturedError.self,
                from: Data(contentsOf: dir.appendingPathComponent("error.json"))
            )
            XCTAssertTrue(recorded.error.contains("Boom"), recorded.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("verdict.json").path))
        }
    }

    func testCancellationRecordsNothing() async throws {
        let base = try tempBase("cancel")
        let recorded = Mutex<[(String, String)]>([])
        let capture = store(base: base, log: { tag, message in
            recorded.withLock { $0.append((tag, message)) }
        })
        await capture.begin()
        let failures: [Error] = [CancellationError(), URLError(.cancelled)]
        for error in failures {
            let client = FrameCaptureModelClient(
                inner: StubCaptureClient(verdict: nil, error: error),
                store: capture,
                model: "m",
                promptHash: "h"
            )
            do {
                _ = try await client.complete(request())
                XCTFail("expected cancellation to pass through")
            } catch is CancellationError {
                // Expected.
            } catch let urlError as URLError where urlError.code == .cancelled {
                // Expected.
            }
        }
        await capture.drain()
        let session = base.appendingPathComponent("FrameCapture/\(sessionStamp)")
        let contents = try FileManager.default.contentsOfDirectory(atPath: session.path)
        XCTAssertFalse(contents.contains { $0.hasPrefix("call-") }, "\(contents)")
        XCTAssertFalse(lines(recorded).contains { $0.contains("saved call-") })
    }

    func testCapStopsWritingAndLogsOnce() async throws {
        XCTAssertEqual(FrameCaptureStore.maxCalls, 600)
        XCTAssertEqual(FrameCaptureStore.maxBytes, 60_000_000)
        let base = try tempBase("cap")
        let recorded = Mutex<[(String, String)]>([])
        let capture = store(base: base, log: { tag, message in
            recorded.withLock { $0.append((tag, message)) }
        }, callCap: 3)
        await capture.begin()
        for _ in 0..<5 {
            await capture.save(request: request(), verdict: verdict(), latencyMs: 1, model: "m", promptHash: "h")
        }
        let session = base.appendingPathComponent("FrameCapture/\(sessionStamp)")
        let contents = try FileManager.default.contentsOfDirectory(atPath: session.path)
        XCTAssertEqual(contents.filter { $0.hasPrefix("call-") }.count, 3)
        XCTAssertEqual(lines(recorded).filter { $0.contains("cap reached") }.count, 1)
    }

    func testPruneKeepsNewestTenSessions() async throws {
        let base = try tempBase("prune")
        let root = base.appendingPathComponent("FrameCapture", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for day in 1...12 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(String(format: "202401%02d-120000", day)),
                withIntermediateDirectories: true
            )
        }
        let recorded = Mutex<[(String, String)]>([])
        let capture = store(base: base, log: { tag, message in
            recorded.withLock { $0.append((tag, message)) }
        })
        await capture.begin()
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents.count, 10)
        XCTAssertTrue(contents.contains(sessionStamp), "the current session survives")
        XCTAssertFalse(contents.contains("20240101-120000"))
        XCTAssertFalse(contents.contains("20240102-120000"))
        XCTAssertFalse(contents.contains("20240103-120000"))
    }

    func testBackupExclusionFlagIsSet() async throws {
        let base = try tempBase("backup")
        let recorded = Mutex<[(String, String)]>([])
        let capture = store(base: base, log: { tag, message in
            recorded.withLock { $0.append((tag, message)) }
        })
        await capture.begin()
        let root = base.appendingPathComponent("FrameCapture")
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testCallNumbersIncreaseWithoutOverwrite() async throws {
        let base = try tempBase("order")
        let recorded = Mutex<[(String, String)]>([])
        let capture = store(base: base, log: { tag, message in
            recorded.withLock { $0.append((tag, message)) }
        })
        await capture.begin()
        let client = FrameCaptureModelClient(
            inner: StubCaptureClient(verdict: verdict()),
            store: capture,
            model: "m",
            promptHash: "h"
        )
        for byte in [UInt8(0xA1), 0xA2, 0xA3] {
            _ = try await client.complete(request(frameBytes: [byte]))
        }
        await capture.drain()
        let session = base.appendingPathComponent("FrameCapture/\(sessionStamp)")
        for (number, byte) in [(1, 0xA1), (2, 0xA2), (3, 0xA3)] as [(Int, UInt8)] {
            let jpg = try Data(contentsOf: session
                .appendingPathComponent(String(format: "call-%04d", number))
                .appendingPathComponent("kf-kf-1.jpg"))
            XCTAssertEqual(jpg, Data([byte]), "call-\(number)")
        }
    }

    func testSessionFileAndUsageAndDelete() async throws {
        let base = try tempBase("usage")
        XCTAssertEqual(FrameCaptureStore.usage(baseURL: base).sessions, 0)
        let recorded = Mutex<[(String, String)]>([])
        let capture = store(base: base, log: { tag, message in
            recorded.withLock { $0.append((tag, message)) }
        })
        await capture.begin()
        await capture.save(request: request(), verdict: verdict(), latencyMs: 1, model: "m", promptHash: "h")
        let session = try CapturedCall.jsonDecoder().decode(
            CapturedSession.self,
            from: Data(contentsOf: base.appendingPathComponent("FrameCapture/\(sessionStamp)/session.json"))
        )
        XCTAssertEqual(session.mode, "live")
        XCTAssertEqual(session.needs.map(\.id), ["take-baby"])
        let usage = FrameCaptureStore.usage(baseURL: base)
        XCTAssertEqual(usage.sessions, 1)
        XCTAssertGreaterThan(usage.bytes, 0)
        FrameCaptureStore.deleteAll(baseURL: base)
        XCTAssertEqual(FrameCaptureStore.usage(baseURL: base).sessions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("FrameCapture").path))
    }
}

private final class StubCaptureClient: ModelClient, @unchecked Sendable {
    var verdict: ModelVerdict?
    var error: Error?
    var calls = 0

    init(verdict: ModelVerdict?, error: Error? = nil) {
        self.verdict = verdict
        self.error = error
    }

    func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        calls += 1
        if let error {
            throw error
        }
        return try XCTUnwrap(verdict)
    }
}
