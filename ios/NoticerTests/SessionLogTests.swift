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
        log.appendActivity("UI", "stop tapped", at: Date(timeIntervalSince1970: 1_700_000_002))
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries.map(\.tag), ["SESSION", "MODEL"])
        let lines = log.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].contains("3 entries"), lines[0])
        XCTAssertTrue(lines[1].contains("sessions 0"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("[SESSION] start mode=live"))
        XCTAssertTrue(lines[3].hasSuffix("[MODEL] call keyframes=2"))
        XCTAssertTrue(lines[4].hasSuffix("[UI] stop tapped"))
        XCTAssertEqual(lines[2].prefix(12).filter { $0 == ":" }.count, 2, "HH:mm:ss.SSS stamp")
    }

    func testCapDropsOldest() {
        XCTAssertEqual(SessionLog.maxEntries, 10_000)
        let log = SessionLog()
        for index in 1...SessionLog.maxEntries + 5 {
            log.append("T", "m\(index)")
        }
        XCTAssertEqual(log.entries.count, SessionLog.maxEntries)
        XCTAssertEqual(log.droppedCount, 5)
        XCTAssertEqual(log.entries.first?.message, "m6")
        XCTAssertTrue(log.text.contains("5 oldest dropped"))
    }

    func testClearKeepsActivity() {
        let log = SessionLog()
        log.append("T", "x")
        log.appendActivity("UI", "y")
        log.clear()
        XCTAssertFalse(log.isEmpty)
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.droppedCount, 0)
        XCTAssertEqual(log.activity.count, 1)
    }

    func testStoreSavesAndPrunesToCap() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("logstore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<(SessionLogStore.maxFiles + 2) {
            SessionLogStore.save(
                "run \(index)",
                at: start.addingTimeInterval(TimeInterval(index * 60)),
                baseURL: base
            )
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(SessionLogStore.maxFiles, 50)
        XCTAssertEqual(files.filter { $0.hasPrefix("noticer-") }.count, SessionLogStore.maxFiles)
    }

    func testDisplaySliceShowsNewest1500WithTotal() {
        let log = SessionLog()
        for index in 1...2000 {
            log.append("T", "m\(index)")
        }
        let slice = log.displaySlice()
        XCTAssertEqual(slice.totalLines, log.text.components(separatedBy: "\n").count)
        XCTAssertEqual(slice.text.components(separatedBy: "\n").count, 1_500)
        XCTAssertTrue(slice.text.hasSuffix("[T] m2000"))
        XCTAssertFalse(slice.text.contains("[T] m1\n"))
        XCTAssertEqual(
            slice.note,
            "Showing the last 1,500 of \(slice.totalLines) lines. Share includes everything."
        )
    }

    func testExportWritesNamedFileWithFullText() throws {
        let log = SessionLog()
        log.append("SESSION", "start mode=live", at: Date(timeIntervalSince1970: 1_700_000_000))
        log.appendActivity("UI", "stop tapped", at: Date(timeIntervalSince1970: 1_700_000_001))
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try XCTUnwrap(SessionLogExport.writeFile(text: log.text, date: Date(), baseURL: base))
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertTrue(
            url.lastPathComponent.range(of: #"^noticer-log-\d{8}-\d{6}\.txt$"#, options: .regularExpression) != nil,
            url.lastPathComponent
        )
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), log.text)
    }

    func testExportDefaultsToTemporaryDirectory() throws {
        let url = try XCTUnwrap(SessionLogExport.writeFile(text: "hello", date: Date(), baseURL: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(
            url.deletingLastPathComponent().resolvingSymlinksInPath().path,
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        )
    }

    func testExportRedactsSecrets() throws {
        let log = SessionLog()
        log.append("MODEL", "api_key=sk-testfakekey1234567890", at: Date(timeIntervalSince1970: 1_700_000_000))
        log.append("MODEL", "Authorization: Bearer abcdef123456", at: Date(timeIntervalSince1970: 1_700_000_001))
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try XCTUnwrap(SessionLogExport.writeFile(text: log.text, date: Date(), baseURL: base))
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("sk-testfakekey"), content)
        XCTAssertFalse(content.contains("abcdef123456"), content)
        XCTAssertTrue(content.contains("[redacted]"), content)
    }

    func testDisplaySliceUnderLimitShowsEverything() {
        let log = SessionLog()
        log.append("T", "only")
        let slice = log.displaySlice()
        XCTAssertEqual(slice.text, log.text)
        XCTAssertNil(slice.note)
    }

    func testRunsListsNewestFirstAndIgnoresOtherFiles() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for name in ["noticer-20240101-120000.log", "noticer-20240103-120000.log", "noticer-20240102-120000.log"] {
            try "body \(name)".write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "junk".write(to: base.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "junk".write(to: base.appendingPathComponent("other.log"), atomically: true, encoding: .utf8)
        try "junk".write(to: base.appendingPathComponent("noticer-draft.txt"), atomically: true, encoding: .utf8)

        let runs = SessionLogStore.runs(baseURL: base)
        XCTAssertEqual(
            runs.map(\.url.lastPathComponent),
            ["noticer-20240103-120000.log", "noticer-20240102-120000.log", "noticer-20240101-120000.log"]
        )
        XCTAssertGreaterThan(runs.first?.size ?? 0, 0)
        XCTAssertNotNil(runs.first?.date)
    }

    func testRunsOnMissingFolderIsEmpty() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runs-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(SessionLogStore.runs(baseURL: base).isEmpty)
    }

    func testActivityFileRoundTrips() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let persisted = ActivityPersisted(
            sessionCount: 4,
            entries: [ActivityEvent(tag: "APP", message: "launch")],
            droppedCount: 1
        )
        ActivityFileStore.save(persisted, baseURL: base)
        let loaded = try XCTUnwrap(ActivityFileStore.load(baseURL: base))
        XCTAssertEqual(loaded, persisted)
        XCTAssertNil(ActivityFileStore.load(baseURL: base.appendingPathComponent("missing")))
    }

    func testLoadActivityMergesUnderNewLines() async {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        ActivityFileStore.save(
            ActivityPersisted(
                sessionCount: 4,
                entries: [ActivityEvent(at: Date(timeIntervalSince1970: 100), tag: "APP", message: "old")],
                droppedCount: 2
            ),
            baseURL: base
        )
        let log = SessionLog()
        log.activityBaseURL = base
        log.appendActivity("UI", "new", at: Date(timeIntervalSince1970: 200))
        await log.loadActivity()
        XCTAssertEqual(log.activity.map(\.message), ["old", "new"])
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
