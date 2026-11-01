import Foundation

// MARK: - App activity log (pure logic, Linux-tested)

/// One app-activity record: everything outside the engine transcript, so a
/// reviewer can reconstruct any problem from the exported log alone. Same
/// shape and line format as the session entries they merge with.
public struct ActivityEvent: Sendable, Equatable, Codable {
    public var at: Date
    public var tag: String
    public var message: String

    public init(at: Date = Date(), tag: String, message: String) {
        self.at = at
        self.tag = tag
        self.message = message
    }
}

/// Rolling activity buffer: newest 2000 entries, oldest-first. Dropped
/// entries are counted so the export can say so.
public struct ActivityBuffer: Sendable, Equatable, Codable {
    public static let maxEntries = 2000
    public static let maxBytes = 1_000_000

    public private(set) var entries: [ActivityEvent]
    public private(set) var droppedCount: Int

    public init(entries: [ActivityEvent] = [], droppedCount: Int = 0) {
        self.entries = entries
        self.droppedCount = droppedCount
    }

    public mutating func append(_ event: ActivityEvent) {
        entries.append(event)
        if entries.count > Self.maxEntries {
            let overflow = entries.count - Self.maxEntries
            entries.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    /// Merges entries persisted by an earlier launch under the current (newer)
    /// ones, keeping time order and the cap.
    public mutating func merge(saved: ActivityPersisted) {
        let combined = (saved.entries + entries).sorted { $0.at < $1.at }
        if combined.count > Self.maxEntries {
            droppedCount += saved.droppedCount + (combined.count - Self.maxEntries)
            entries = Array(combined.suffix(Self.maxEntries))
        } else {
            droppedCount += saved.droppedCount
            entries = combined
        }
    }

    /// Drops the oldest entries until the encoded size fits. Sizes are
    /// estimated (framing plus a margin), never re-encoded in a loop.
    public func trimmed(toMaxBytes limit: Int = maxBytes) -> ActivityBuffer {
        var kept = entries
        var dropped = droppedCount
        while estimatedBytes(kept) > limit, !kept.isEmpty {
            // Drop in proportionate chunks: one pass for sane inputs.
            let over = estimatedBytes(kept) - limit
            let perEntry = max(1, estimatedBytes(kept) / max(1, kept.count))
            let count = min(kept.count, max(1, over / perEntry))
            kept.removeFirst(count)
            dropped += count
        }
        return ActivityBuffer(entries: kept, droppedCount: dropped)
    }

    private func estimatedBytes(_ entries: [ActivityEvent]) -> Int {
        entries.reduce(0) { $0 + $1.message.utf8.count + $1.tag.utf8.count + 64 }
    }
}

/// What crosses launches: the buffer plus the session counter.
public struct ActivityPersisted: Sendable, Equatable, Codable {
    public var sessionCount: Int
    public var entries: [ActivityEvent]
    public var droppedCount: Int

    public init(sessionCount: Int = 0, entries: [ActivityEvent] = [], droppedCount: Int = 0) {
        self.sessionCount = sessionCount
        self.entries = entries
        self.droppedCount = droppedCount
    }
}

// MARK: - Export (one merged, redacted, time-ordered transcript)

public struct ActivityExportHeader: Sendable, Equatable {
    public var appVersion: String
    public var build: String
    public var device: String
    public var systemVersion: String
    public var timeZone: String
    public var sessionCount: Int

    public init(
        appVersion: String,
        build: String,
        device: String,
        systemVersion: String,
        timeZone: String,
        sessionCount: Int
    ) {
        self.appVersion = appVersion
        self.build = build
        self.device = device
        self.systemVersion = systemVersion
        self.timeZone = timeZone
        self.sessionCount = sessionCount
    }
}

public enum ActivityExport {
    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    /// One line. Embedded newlines become spaces so every event stays greppable.
    public static func line(at: Date, tag: String, message: String) -> String {
        let flat = message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\(stamp(at)) [\(tag)] \(flat)"
    }

    /// Header plus activity and session events interleaved by time. Order is
    /// stable within each list; cross-list ties read activity first.
    public static func text(
        header: ActivityExportHeader,
        activity: [ActivityEvent],
        session: [ActivityEvent],
        activityDropped: Int,
        sessionDropped: Int
    ) -> String {
        let total = activity.count + session.count
        let dropped = activityDropped + sessionDropped
        var lines = [
            "noticer log · \(total) entries" + (dropped > 0 ? " (\(dropped) oldest dropped)" : ""),
            "app \(header.appVersion) (\(header.build)) · \(header.device) · iOS \(header.systemVersion) · \(header.timeZone) · sessions \(header.sessionCount)",
        ]
        let merged = (activity.map { (0, $0) } + session.map { (1, $0) })
            .enumerated()
            .sorted {
                if $0.element.1.at != $1.element.1.at {
                    return $0.element.1.at < $1.element.1.at
                }
                if $0.element.0 != $1.element.0 {
                    return $0.element.0 < $1.element.0
                }
                return $0.offset < $1.offset
            }
        for (_, ( _, event)) in merged {
            lines.append(ActivityRedaction.redact(line(at: event.at, tag: event.tag, message: event.message)))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Redaction (keys and auth headers never reach the export)

public enum ActivityRedaction {
    /// Redacts explicit secrets plus key-shaped accidents. Conservative by
    /// design: UUIDs, timestamps, need ids, and plain words pass through.
    public static func redact(_ text: String, secrets: [String] = []) -> String {
        var out = text
        for secret in secrets where secret.count >= 8 {
            out = out.replacingOccurrences(of: secret, with: "[redacted]")
        }
        out = out.replacingOccurrences(
            of: "Authorization:\\s*.*",
            with: "Authorization: [redacted]",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "Bearer\\s+[A-Za-z0-9._~+/\\-]+=*",
            with: "Bearer [redacted]",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "\\bsk-[A-Za-z0-9]{8,}",
            with: "[redacted]",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "(?i)\\b(api[_-]?key|secret|token)\\b\\s*[:=]\\s*\\S+",
            with: "$1=[redacted]",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: "\\b[0-9a-fA-F]{32,}\\b",
            with: "[redacted]",
            options: .regularExpression
        )
        return out
    }
}

// MARK: - List diffs and snapshots ([LIST] messages; the caller tags them)

public enum NeedListDiff {
    public struct Row: Sendable, Equatable {
        public var need: Need
        public var paused: Bool

        public init(need: Need, paused: Bool) {
            self.need = need
            self.paused = paused
        }
    }

    /// Old → new as one line per change: adds, removes (a lone
    /// remove-plus-add reads as one `swap` line), field edits, pause flips.
    /// Engine-owned fields (mastery) never diff. Every line carries the
    /// cause, and the source when the edit came from a conversation turn.
    public static func lines(old: [Row], new: [Row], cause: String, source: String? = nil) -> [String] {
        let suffix = " cause=\(cause)" + (source.map { " source=\($0)" } ?? "")
        let oldIDs = old.map { $0.need.id }
        let newIDs = Set(new.map { $0.need.id })
        let removed = old.filter { !newIDs.contains($0.need.id) }
        let added = new.filter { need in !oldIDs.contains(need.need.id) }
        var lines: [String] = []
        if removed.count == 1, added.count == 1,
           let out = removed.first, let fresh = added.first {
            lines.append("swap out=\(out.need.id) in=\(fresh.need.id)"
                + " name=\"\(fresh.need.authorText)\"" + suffix)
        } else {
            for row in removed {
                lines.append("remove id=\(row.need.id) name=\"\(row.need.authorText)\"" + suffix)
            }
            for row in added {
                lines.append("add id=\(row.need.id) name=\"\(row.need.authorText)\"" + suffix)
            }
        }
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.need.id, $0) })
        for row in old {
            guard let after = newByID[row.need.id] else {
                continue
            }
            lines += editLines(id: row.need.id, before: row, after: after, suffix: suffix)
        }
        return lines
    }

    private static func editLines(id: String, before: Row, after: Row, suffix: String) -> [String] {
        var lines: [String] = []
        let a = before.need, b = after.need
        if a.authorText != b.authorText {
            lines.append("edit id=\(id) name: \"\(a.authorText)\" -> \"\(b.authorText)\"" + suffix)
        }
        if a.cueWording != b.cueWording {
            lines.append("edit id=\(id) whisper: \"\(a.cueWording)\" -> \"\(b.cueWording)\"" + suffix)
        }
        if a.priority != b.priority {
            lines.append("edit id=\(id) priority: \(a.priority) -> \(b.priority)" + suffix)
        }
        if a.allowsCheckIn != b.allowsCheckIn {
            lines.append("edit id=\(id) checkin: \(a.allowsCheckIn) -> \(b.allowsCheckIn)" + suffix)
        }
        if a.isUrgent != b.isUrgent {
            lines.append("edit id=\(id) urgent: \(onOff(a.isUrgent)) -> \(onOff(b.isUrgent))" + suffix)
        }
        if a.dwellSeconds != b.dwellSeconds {
            lines.append("edit id=\(id) dwell: \(seconds(a.dwellSeconds)) -> \(seconds(b.dwellSeconds))" + suffix)
        }
        if a.visualCondition != b.visualCondition {
            lines.append("edit id=\(id) visual: \"\(a.visualCondition ?? "")\" -> \"\(b.visualCondition ?? "")\"" + suffix)
        }
        if a.handledCondition != b.handledCondition {
            lines.append("edit id=\(id) handled: \"\(a.handledCondition ?? "")\" -> \"\(b.handledCondition ?? "")\"" + suffix)
        }
        if a.selfNoticeSignal != b.selfNoticeSignal {
            lines.append("edit id=\(id) signal: \"\(a.selfNoticeSignal ?? "")\" -> \"\(b.selfNoticeSignal ?? "")\"" + suffix)
        }
        if before.paused != after.paused {
            lines.append("pause id=\(id) \(onOff(after.paused))" + suffix)
        }
        return lines
    }

    /// Full list state: one count line plus one line per need.
    public static func snapshotLines(rows: [Row]) -> [String] {
        var lines = ["snapshot n=\(rows.count)"]
        for row in rows {
            lines.append("snapshot id=\(row.need.id) name=\"\(row.need.authorText)\""
                + " paused=\(yesNo(row.paused)) priority=\(row.need.priority)"
                + " urgent=\(yesNo(row.need.isUrgent))")
        }
        return lines
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }
    private static func yesNo(_ value: Bool) -> String { value ? "y" : "n" }
    private static func seconds(_ value: TimeInterval?) -> String {
        value.map { "\(Int($0))s" } ?? "default"
    }
}

// MARK: - Tonight snapshots ([TONIGHT] messages)

public enum ActivityTonight {
    public struct Entry: Sendable, Equatable {
        public var at: Date
        public var kind: String
        public var needID: String
        public var text: String

        public init(at: Date, kind: String, needID: String, text: String) {
            self.at = at
            self.kind = kind
            self.needID = needID
            self.text = text
        }
    }

    public static let snapshotCap = 30

    /// One count line plus the newest entries first.
    public static func snapshotLines(_ moments: [Entry]) -> [String] {
        let shown = moments.sorted { $0.at > $1.at }.prefix(snapshotCap)
        var lines = ["snapshot n=\(moments.count)"]
        for moment in shown {
            lines.append("snapshot at=\(ActivityExport.stamp(moment.at))"
                + " kind=\(moment.kind) need=\(moment.needID) text=\"\(moment.text)\"")
        }
        return lines
    }

    public static func addLine(kind: String, needID: String, why: String) -> String {
        "add kind=\(kind) need=\(needID) why=\(why)"
    }

    public static func trimLine(dropped: Int, cap: Int) -> String {
        "trim dropped=\(dropped) (cap \(cap))"
    }
}

// MARK: - Conversation lines ([CONV] messages, derived from sheet entries)

public enum ActivityConversation {
    public static func herLine(text: String, source: String) -> String {
        "her source=\(source) \"\(text)\""
    }

    public static func replyQuestionLine(question: String, chips: [String]) -> String {
        "reply question \"\(question)\" chips=[\(chips.joined(separator: ", "))]"
    }

    public static func replyNeedsLine(count: Int, readBack: String) -> String {
        "reply needs n=\(count) \"\(readBack)\""
    }

    public static func draftDiscardedLine(id: String) -> String {
        "draft discarded id=\(id)"
    }
}

// MARK: - Edit sources (typed, voice, chip tap; swap flow joins later)

public enum ListEditSource: String, Sendable {
    case typed
    case voice
    case chip
    case swapFlow = "swap-flow"
}
