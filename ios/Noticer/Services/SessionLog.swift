import Foundation
import Observation

/// Developer-mode session transcript: lifecycle, frames, model turns, engine
/// events, speech, and errors. One entry per line, timestamped, written for
/// LLM debugging — paste the whole text and the full story is there.
///
/// MainActor for live SwiftUI observation; `@unchecked Sendable` so the model
/// client can hold it across domains. Sound because every method is isolated:
/// all appends hop to the main actor. Never carries the API key.
@MainActor
@Observable
final class SessionLog: @unchecked Sendable {
    struct Entry: Sendable {
        var at: Date
        var tag: String
        var message: String
    }

    static let cap = 600

    private(set) var entries: [Entry] = []
    private(set) var droppedCount = 0

    func append(_ tag: String, _ message: String, at date: Date = Date()) {
        entries.append(Entry(at: date, tag: tag, message: message))
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
            droppedCount += 1
        }
    }

    func clear() {
        entries = []
        droppedCount = 0
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    var text: String {
        var lines = ["noticer session log · \(entries.count) entries" + (droppedCount > 0 ? " (\(droppedCount) oldest dropped)" : "")]
        lines += entries.map { "\(Self.stamp($0.at)) [\($0.tag)] \($0.message)" }
        return lines.joined(separator: "\n")
    }

    static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// Persists session transcripts inside the app container so they can be
/// pulled off the device (`devicectl device copy from ... appDataContainer`).
/// Each run writes `noticer-<timestamp>.log` plus a `latest.log` overwrite.
/// `baseURL` exists for tests; the app always uses Documents.
enum SessionLogStore {
    static let folderName = "SessionLogs"
    static let latestName = "latest.log"
    static let keepRuns = 10

    @discardableResult
    static func save(_ text: String, at now: Date = Date(), baseURL: URL? = nil) -> URL? {
        let base = baseURL ?? documentsURL()
        guard let base else {
            return nil
        }
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = fileStampFormatter.string(from: now)
            let url = folder.appendingPathComponent("noticer-\(stamp).log")
            try text.write(to: url, atomically: true, encoding: .utf8)
            try text.write(to: folder.appendingPathComponent(latestName), atomically: true, encoding: .utf8)
            prune(folder: folder)
            return url
        } catch {
            return nil
        }
    }

    static func prune(folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        let runs = files
            .filter { $0.lastPathComponent.hasPrefix("noticer-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for stale in runs.dropLast(keepRuns) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private static func documentsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
