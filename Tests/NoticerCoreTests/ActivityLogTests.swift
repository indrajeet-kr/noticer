import Foundation
import XCTest
@testable import NoticerCore

/// App activity log: diffs, snapshots, buffer, export, and redaction.
final class ActivityLogTests: XCTestCase {
    private func need(
        _ id: String,
        _ authorText: String,
        priority: Int = 1,
        isUrgent: Bool = false,
        allowsCheckIn: Bool = false
    ) -> Need {
        Need(
            id: id,
            authorText: authorText,
            cueWording: "Whisper \(id).",
            priority: priority,
            allowsCheckIn: allowsCheckIn,
            isUrgent: isUrgent
        )
    }

    private func row(_ need: Need, paused: Bool = false) -> NeedListDiff.Row {
        NeedListDiff.Row(need: need, paused: paused)
    }

    // MARK: - Diffs

    func testDiffAddAndRemoveCarryCauseAndSource() {
        let old = [row(need("take-baby", "Take the baby")), row(need("refill-water", "Water"))]
        let new = [row(need("take-baby", "Take the baby")), row(need("fold-mat", "Fold the mat"))]
        // One removal plus one addition reads as a single swap line.
        XCTAssertEqual(
            NeedListDiff.lines(old: old, new: new, cause: "looks-right", source: "chip"),
            ["swap out=refill-water in=fold-mat name=\"Fold the mat\" cause=looks-right source=chip"]
        )
    }

    func testDiffSeparateAddAndRemove() {
        let old = [row(need("take-baby", "Take the baby"))]
        let added = NeedListDiff.lines(
            old: old,
            new: old + [row(need("fold-mat", "Fold the mat"))],
            cause: "looks-right", source: "typed"
        )
        XCTAssertEqual(
            added,
            ["add id=fold-mat name=\"Fold the mat\" cause=looks-right source=typed"]
        )
        let removed = NeedListDiff.lines(old: old, new: [], cause: "remove")
        XCTAssertEqual(removed, ["remove id=take-baby name=\"Take the baby\" cause=remove"])
    }

    func testDiffEditsPauseAndPriority() {
        let before = need("take-baby", "Take the baby")
        var after = before
        after.priority = 0
        after.isUrgent = true
        after.allowsCheckIn = true
        let lines = NeedListDiff.lines(
            old: [row(before, paused: false)],
            new: [row(after, paused: true)],
            cause: "looks-right"
        )
        XCTAssertTrue(lines.contains("edit id=take-baby priority: 1 -> 0 cause=looks-right"))
        XCTAssertTrue(lines.contains("edit id=take-baby urgent: off -> on cause=looks-right"))
        XCTAssertTrue(lines.contains("edit id=take-baby checkin: false -> true cause=looks-right"))
        XCTAssertTrue(lines.contains("pause id=take-baby on cause=looks-right"))
        XCTAssertFalse(lines.contains { $0.contains("mastery") })
    }

    func testDiffIgnoresMastery() {
        let before = need("take-baby", "Take the baby")
        var after = before
        after.mastery = MasteryState(score: 0.9, consecutiveSelfNotices: 3, consecutiveMisses: 0)
        XCTAssertTrue(NeedListDiff.lines(old: [row(before)], new: [row(after)], cause: "x").isEmpty)
    }

    // MARK: - Snapshots

    func testListSnapshot() {
        let lines = NeedListDiff.snapshotLines(rows: [
            row(need("take-baby", "Take the baby", priority: 0), paused: false),
            row(need("refill-water", "Water"), paused: true),
        ])
        XCTAssertEqual(lines, [
            "snapshot n=2",
            "snapshot id=take-baby name=\"Take the baby\" paused=n priority=0 urgent=n",
            "snapshot id=refill-water name=\"Water\" paused=y priority=1 urgent=n",
        ])
    }

    func testTonightSnapshotNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let lines = ActivityTonight.snapshotLines([
            ActivityTonight.Entry(at: base, kind: "selfNotice", needID: "take-baby", text: "Take the baby"),
            ActivityTonight.Entry(at: base.addingTimeInterval(60), kind: "cued", needID: "water", text: "Water"),
        ])
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "snapshot n=2")
        XCTAssertTrue(lines[1].contains("kind=cued need=water"))
        XCTAssertTrue(lines[2].contains("kind=selfNotice need=take-baby"))
    }

    func testTonightAddAndTrimLines() {
        XCTAssertEqual(
            ActivityTonight.addLine(kind: "selfNotice", needID: "take-baby", why: "caught-himself"),
            "add kind=selfNotice need=take-baby why=caught-himself"
        )
        XCTAssertEqual(ActivityTonight.trimLine(dropped: 3, cap: 200), "trim dropped=3 (cap 200)")
    }

    // MARK: - Buffer and persistence

    func testBufferCapsAt2000AndCountsDrops() {
        var buffer = ActivityBuffer()
        for index in 0..<2010 {
            buffer.append(ActivityEvent(tag: "UI", message: "line \(index)"))
        }
        XCTAssertEqual(buffer.entries.count, 2000)
        XCTAssertEqual(buffer.droppedCount, 10)
        XCTAssertEqual(buffer.entries.first?.message, "line 10")
        XCTAssertEqual(buffer.entries.last?.message, "line 2009")
    }

    func testBufferMergesSavedEntriesAcrossRelaunch() throws {
        let base = Date(timeIntervalSince1970: 2_000_000)
        let saved = ActivityPersisted(
            sessionCount: 7,
            entries: [
                ActivityEvent(at: base, tag: "APP", message: "launch"),
                ActivityEvent(at: base.addingTimeInterval(5), tag: "UI", message: "tab Tonight"),
            ],
            droppedCount: 3
        )
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(ActivityPersisted.self, from: data)
        var buffer = ActivityBuffer()
        buffer.append(ActivityEvent(at: base.addingTimeInterval(10), tag: "APP", message: "launch again"))
        buffer.merge(saved: decoded)
        XCTAssertEqual(buffer.entries.map(\.message), ["launch", "tab Tonight", "launch again"])
        XCTAssertEqual(buffer.droppedCount, 3)
        XCTAssertEqual(decoded.sessionCount, 7)
    }

    func testBufferTrimsToByteCap() throws {
        var buffer = ActivityBuffer()
        for index in 0..<50 {
            buffer.append(ActivityEvent(tag: "UI", message: String(repeating: "x", count: 200) + " \(index)"))
        }
        let trimmed = buffer.trimmed(toMaxBytes: 2000)
        let bytes = try JSONEncoder().encode(trimmed).count
        XCTAssertLessThanOrEqual(bytes, 2000)
        XCTAssertGreaterThan(trimmed.droppedCount, 0)
        // Newest survive.
        XCTAssertTrue(trimmed.entries.last?.message.hasSuffix(" 49") == true)
    }

    // MARK: - Export

    private func header() -> ActivityExportHeader {
        ActivityExportHeader(
            appVersion: "1.2", build: "34", device: "iPhone iPhone17,2",
            systemVersion: "26.1", timeZone: "America/New_York", sessionCount: 12
        )
    }

    func testExportHeaderAndOrdering() {
        let base = Date(timeIntervalSince1970: 3_000_000)
        let text = ActivityExport.text(
            header: header(),
            activity: [
                ActivityEvent(at: base, tag: "APP", message: "launch"),
                ActivityEvent(at: base.addingTimeInterval(20), tag: "UI", message: "stop tapped"),
            ],
            session: [
                ActivityEvent(at: base.addingTimeInterval(10), tag: "ENGINE", message: "latch take-baby"),
            ],
            activityDropped: 1,
            sessionDropped: 2
        )
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "noticer log · 3 entries (3 oldest dropped)")
        XCTAssertEqual(lines[1], "app 1.2 (34) · iPhone iPhone17,2 · iOS 26.1 · America/New_York · sessions 12")
        XCTAssertTrue(lines[2].contains("[APP] launch"))
        XCTAssertTrue(lines[3].contains("[ENGINE] latch take-baby"))
        XCTAssertTrue(lines[4].contains("[UI] stop tapped"))
    }

    func testExportRedactsSecrets() {
        let text = ActivityExport.text(
            header: header(),
            activity: [ActivityEvent(tag: "ERROR", message: "call failed Bearer abcDEF123")],
            session: [],
            activityDropped: 0,
            sessionDropped: 0
        )
        XCTAssertTrue(text.contains("Bearer [redacted]"))
        XCTAssertFalse(text.contains("abcDEF123"))
    }

    func testExportFlattensNewlines() {
        let text = ActivityExport.text(
            header: header(),
            activity: [ActivityEvent(tag: "CONV", message: "her \"line one\nline two\"")],
            session: [],
            activityDropped: 0,
            sessionDropped: 0
        )
        XCTAssertEqual(text.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(text.contains("line one line two"))
    }

    // MARK: - Redaction

    func testRedactionRules() {
        XCTAssertEqual(
            ActivityRedaction.redact("call failed Bearer abcDEF123=="),
            "call failed Bearer [redacted]"
        )
        XCTAssertEqual(
            ActivityRedaction.redact("Authorization: Bearer xyz"),
            "Authorization: [redacted]"
        )
        XCTAssertEqual(
            ActivityRedaction.redact("key sk-abcdefgh12345678 leaked"),
            "key [redacted] leaked"
        )
        XCTAssertEqual(
            ActivityRedaction.redact("token=abcdef0123456789abcdef0123456789 sent"),
            "token=[redacted] sent"
        )
        XCTAssertEqual(
            ActivityRedaction.redact("hex abcdef0123456789abcdef0123456789 here"),
            "hex [redacted] here"
        )
        XCTAssertEqual(
            ActivityRedaction.redact("using my-secret-token-123 today", secrets: ["my-secret-token-123"]),
            "using [redacted] today"
        )
    }

    func testRedactionLeavesNormalTextAlone() {
        let uuid = UUID().uuidString
        for text in [
            "He gets about 90 seconds to notice first",
            "add id=take-baby name=\"Take the baby\" cause=looks-right",
            "session \(uuid) started",
            "21:04:55.470 [ENGINE] latch take-baby",
            "token expired, retrying",
            "6 cues, down from 9",
        ] {
            XCTAssertEqual(ActivityRedaction.redact(text), text, text)
        }
    }

    // MARK: - Conversation lines

    func testConversationLines() {
        XCTAssertEqual(
            ActivityConversation.herLine(text: "Fold the mat", source: "voice"),
            "her source=voice \"Fold the mat\""
        )
        XCTAssertEqual(
            ActivityConversation.replyQuestionLine(question: "Which one?", chips: ["Water", "Baby"]),
            "reply question \"Which one?\" chips=[Water, Baby]"
        )
        XCTAssertEqual(
            ActivityConversation.replyNeedsLine(count: 2, readBack: "Added the mat."),
            "reply needs n=2 \"Added the mat.\""
        )
        XCTAssertEqual(
            ActivityConversation.draftDiscardedLine(id: "fold-mat"),
            "draft discarded id=fold-mat"
        )
    }
}
