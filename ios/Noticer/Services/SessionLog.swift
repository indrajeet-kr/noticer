import Foundation
import NoticerCore
import Observation
import UIKit

/// Display clock for the log view. All stamps read the same way.
/// Unchecked Sendable: every real caller hops to the main actor (the two
/// cross-actor closures already do), and strict checking rejects the
/// macro's backing storage otherwise.
@Observable
final class SessionLog: @unchecked Sendable {
    static let maxEntries = 600

    /// Rolling session transcript: newest `maxEntries` engine lines, oldest first.
    /// A new run starts with a fresh transcript.
    private(set) var entries: [ActivityEvent] = []
    private(set) var droppedCount = 0
    /// App activity across launches: newest 2000 lines, oldest first.
    /// Persisted on a background actor; never cleared by a new run.
    private(set) var activityBuffer = ActivityBuffer()
    private(set) var sessionCount = 0
    /// Test seam: persistence root (nil means Documents).
    var activityBaseURL: URL?

    var activity: [ActivityEvent] {
        activityBuffer.entries
    }

    /// One-line session call: `log.append("ENGINE", "latch take-baby")`.
    func append(_ tag: String, _ message: String, at: Date = Date()) {
        entries.append(ActivityEvent(at: at, tag: tag, message: message))
        if entries.count > Self.maxEntries {
            let overflow = entries.count - Self.maxEntries
            entries.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    /// One-line activity call: `log.appendActivity("LIST", "add ...")`.
    /// In-memory append only; persistence runs on a background actor.
    func appendActivity(_ tag: String, _ message: String, at: Date = Date()) {
        activityBuffer.append(ActivityEvent(at: at, tag: tag, message: message))
        scheduleActivitySave()
    }

    var isEmpty: Bool {
        entries.isEmpty && activityBuffer.entries.isEmpty
    }

    /// Header plus activity and session lines interleaved by time, redacted.
    /// The lead-up before a session exports with the session itself.
    var text: String {
        ActivityExport.text(
            header: ActivityExportHeader(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                build: Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "?",
                device: Self.deviceString(),
                systemVersion: UIDevice.current.systemVersion,
                timeZone: TimeZone.current.identifier,
                sessionCount: sessionCount
            ),
            activity: activityBuffer.entries,
            session: entries,
            activityDropped: activityBuffer.droppedCount,
            sessionDropped: droppedCount
        )
    }

    /// Loads previously persisted activity under any lines already appended.
    /// Called once at launch; file IO runs off the main thread.
    func loadActivity() async {
        let baseURL = activityBaseURL
        let saved = await Task.detached(priority: .utility) {
            ActivityFileStore.load(baseURL: baseURL)
        }.value
        guard let saved else {
            return
        }
        activityBuffer.merge(saved: saved)
        sessionCount = saved.sessionCount
    }

    /// A session started: bump the persisted counter the header reports.
    func noteSessionStart() {
        sessionCount += 1
        scheduleActivitySave()
    }

    /// A new run starts with a fresh session transcript; activity persists.
    func clear() {
        entries = []
        droppedCount = 0
    }

    /// App launch marker, called once persisted activity loads beneath it.
    func logLaunch() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "?"
        appendActivity(
            "APP",
            "launch app=\(version) (\(build)) device=\(Self.deviceString())"
                + " ios=\(UIDevice.current.systemVersion) tz=\(TimeZone.current.identifier)"
        )
    }

    private func scheduleActivitySave() {
        let trimmed = activityBuffer.trimmed()
        let persisted = ActivityPersisted(
            sessionCount: sessionCount,
            entries: trimmed.entries,
            droppedCount: trimmed.droppedCount
        )
        let baseURL = activityBaseURL
        Task {
            await ActivitySaver.shared.save(persisted, baseURL: baseURL)
        }
    }

    private static func deviceString() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return "\(UIDevice.current.model) \(machine)"
    }

    nonisolated static func stamp(_ date: Date) -> String {
        ActivityExport.stamp(date)
    }
}

/// Session transcripts saved at stop/end, newest first.
enum SessionLogStore {
    static let folderName = "SessionLogs"
    static let filePrefix = "noticer-"
    static let fileExtension = "log"
    static let maxFiles = 20

    static func sessionURL(at date: Date = Date(), baseURL: URL? = nil) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(filePrefix)\(formatter.string(from: date)).\(fileExtension)"
        if let baseURL {
            return baseURL.appendingPathComponent(name)
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent(folderName).appendingPathComponent(name)
    }

    static func save(_ text: String, at date: Date = Date(), baseURL: URL? = nil) {
        guard let url = sessionURL(at: date, baseURL: baseURL) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
        prune(baseURL: baseURL)
    }

    /// Deletes oldest `noticer-*.log` files past the cap. Test-visible so the
    /// cap is pinned without waiting for 20 runs.
    static func prune(baseURL: URL? = nil, cap: Int = maxFiles) {
        let folder: URL
        if let baseURL {
            folder = baseURL
        } else {
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return
            }
            folder = documents.appendingPathComponent(folderName)
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }
        let logs = files
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension == fileExtension }
            .sorted {
                ($0.contentModificationDate ?? .distantPast) < ($1.contentModificationDate ?? .distantPast)
            }
        guard logs.count > cap else {
            return
        }
        for url in logs.prefix(logs.count - cap) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private extension URL {
    var contentModificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
