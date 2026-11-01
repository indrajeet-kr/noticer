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

    func testStoreSavesAndPrunesToCap() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("logstore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<(SessionLogStore.maxFiles + 2) {
            await SessionLogStore.save(
                "run \(index)",
                at: start.addingTimeInterval(TimeInterval(index * 60)),
                baseURL: base
            ).value
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

    func testDisplaySliceSkipsFullTextOnHugeLogs() {
        let log = SessionLog()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 1...12_000 {
            log.append("T", "m\(index)", at: base.addingTimeInterval(TimeInterval(index)))
        }
        for index in 1...5_000 {
            log.appendActivity("UI", "a\(index)", at: base.addingTimeInterval(TimeInterval(index) + 0.5))
        }
        XCTAssertEqual(log.textBuildCount, 0)
        let slice = log.displaySlice()
        XCTAssertEqual(log.textBuildCount, 0, "the display path never builds the full text")
        XCTAssertEqual(slice.totalLines, 2 + 10_000 + 5_000)
        let lines = slice.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 1_500)
        XCTAssertTrue(lines.first?.hasSuffix("[T] m10501") == true, lines.first ?? "")
        XCTAssertTrue(lines.last?.hasSuffix("[T] m12000") == true, lines.last ?? "")
        XCTAssertEqual(slice.note, "Showing the last 1,500 of \(slice.totalLines) lines. Share includes everything.")
    }

    func testDisplaySliceMergesTailsInTimeOrder() {
        let log = SessionLog()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        log.append("T", "s1", at: base)
        log.append("T", "s2", at: base.addingTimeInterval(20))
        log.appendActivity("UI", "a1", at: base.addingTimeInterval(10))
        log.appendActivity("UI", "a2", at: base.addingTimeInterval(20))
        let slice = log.displaySlice()
        XCTAssertEqual(slice.text, log.text, "under the limit the slice is the full text")
        let tails = slice.text.components(separatedBy: "\n").suffix(4).map {
            $0.components(separatedBy: "] ").last ?? $0
        }
        XCTAssertEqual(Array(tails), ["s1", "a1", "a2", "s2"])
    }

    func testDisplaySliceThrottlesRebuilds() {
        let log = SessionLog()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        log.append("T", "first", at: base)
        let first = log.displaySlice(now: base)
        XCTAssertTrue(first.text.hasSuffix("[T] first"))

        log.append("T", "second", at: base.addingTimeInterval(1))
        let throttled = log.displaySlice(now: base.addingTimeInterval(0.1))
        XCTAssertEqual(throttled.text, first.text, "rebuilds wait out the half second")

        let rebuilt = log.displaySlice(now: base.addingTimeInterval(0.6))
        XCTAssertTrue(rebuilt.text.hasSuffix("[T] second"))
        XCTAssertEqual(rebuilt.totalLines, first.totalLines + 1)
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

    func testShareFileBuildsFromCurrentState() throws {
        let log = SessionLog()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharefresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        log.append("T", "first")
        let first = try XCTUnwrap(SessionLogExport.writeFile(text: log.text, date: stamp, baseURL: base))
        log.append("T", "second")
        let second = try XCTUnwrap(
            SessionLogExport.writeFile(text: log.text, date: stamp.addingTimeInterval(1), baseURL: base)
        )
        XCTAssertFalse(try String(contentsOf: first, encoding: .utf8).contains("second"))
        XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).contains("second"))
    }

    func testShareFilePastCapAndActivityOnly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharefresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let capped = SessionLog()
        for index in 1...SessionLog.maxEntries + 5 {
            capped.append("T", "m\(index)")
        }
        let cappedURL = try XCTUnwrap(SessionLogExport.writeFile(text: capped.text, date: stamp, baseURL: base))
        let cappedContent = try String(contentsOf: cappedURL, encoding: .utf8)
        XCTAssertTrue(cappedContent.hasSuffix("[T] m10005"))
        XCTAssertFalse(cappedContent.contains("[T] m1\n"))

        let activityOnly = SessionLog()
        activityOnly.appendActivity("UI", "tap-note")
        let activityURL = try XCTUnwrap(
            SessionLogExport.writeFile(text: activityOnly.text, date: stamp.addingTimeInterval(1), baseURL: base)
        )
        XCTAssertTrue(try String(contentsOf: activityURL, encoding: .utf8).contains("[UI] tap-note"))
    }

    func testCleanupDeletesDayOldShareFiles() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("shareclean-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let now = Date()
        let old = base.appendingPathComponent("noticer-log-20240101-000000.txt")
        let fresh = base.appendingPathComponent("noticer-log-20330101-000000.txt")
        let other = base.appendingPathComponent("notes.txt")
        try "old".write(to: old, atomically: true, encoding: .utf8)
        try "fresh".write(to: fresh, atomically: true, encoding: .utf8)
        try "other".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-100_000)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-100_000)],
            ofItemAtPath: other.path
        )
        SessionLogExport.cleanupOldFiles(baseURL: base, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "only share files are cleaned")
    }

    func testPastRunLoaderSlicesHugeFile() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("runload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("noticer-20240101-120000.log")
        let lines = (1...10_000).map { "line\($0)" }.joined(separator: "\n")
        try lines.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(PastRunLoader.load(url: url))
        XCTAssertEqual(loaded.full, lines)
        XCTAssertEqual(loaded.slice.totalLines, 10_000)
        XCTAssertEqual(loaded.slice.text.components(separatedBy: "\n").count, 1_500)
        XCTAssertTrue(loaded.slice.text.hasSuffix("line10000"))
        XCTAssertEqual(
            loaded.slice.note,
            "Showing the last 1,500 of 10000 lines. Share includes everything."
        )
        XCTAssertNil(PastRunLoader.load(url: base.appendingPathComponent("missing.log")))
    }

    func testBackgroundSavesLandInOrder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("saveorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = SessionLogStore.save("first", at: stamp, baseURL: base)
        let second = SessionLogStore.save("second", at: stamp, baseURL: base)
        await first.value
        await second.value
        let url = try XCTUnwrap(SessionLogStore.sessionURL(at: stamp, baseURL: base))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second")

        let other = SessionLogStore.save("third", at: stamp.addingTimeInterval(60), baseURL: base)
        await other.value
        let otherURL = try XCTUnwrap(SessionLogStore.sessionURL(at: stamp.addingTimeInterval(60), baseURL: base))
        XCTAssertEqual(try String(contentsOf: otherURL, encoding: .utf8), "third")
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
