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
    static let maxEntries = 10_000
    /// On-screen transcript lines. The full text still feeds Copy, Share,
    /// and the saved file.
    static let displayLineLimit = 1_500
    /// Fastest display rebuild while the log screen is open.
    static let displayRefreshInterval: TimeInterval = 0.5
    /// Header lines above the merged events in the full text.
    private static let headerLineCount = 2

    /// Rolling session transcript: newest `maxEntries` engine lines, oldest first.
    /// A new run starts with a fresh transcript.
    private(set) var entries: [ActivityEvent] = []
    private(set) var droppedCount = 0
    /// Bumps on every append to either buffer, so the display slice
    /// rebuilds only when something actually landed.
    private(set) var revision = 0
    /// Full-text builds, so tests can prove the display path skips them.
    private(set) var textBuildCount = 0
    private var cachedSlice: LogDisplaySlice?
    private var cachedRevision = -1
    private var cachedAt: Date = .distantPast
    /// App activity across launches: newest 20,000 lines, oldest first.
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
        revision += 1
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
        revision += 1
        activityBuffer.append(ActivityEvent(at: at, tag: tag, message: message))
        scheduleActivitySave()
    }

    var isEmpty: Bool {
        entries.isEmpty && activityBuffer.entries.isEmpty
    }

    /// Newest on-screen lines plus the full count, merged from the
    /// buffer tails without building the full `text`. Cached per
    /// revision and rebuilt at most every `displayRefreshInterval`; the
    /// view ticks on that cadence while visible. Copy and Share still
    /// use the full `text`.
    func displaySlice(now: Date = Date()) -> LogDisplaySlice {
        if let cached = cachedSlice,
           revision == cachedRevision || now.timeIntervalSince(cachedAt) < Self.displayRefreshInterval {
            return cached
        }
        let slice = buildDisplaySlice()
        cachedSlice = slice
        cachedRevision = revision
        cachedAt = now
        return slice
    }

    /// Newest merged events, oldest first. Both buffers read
    /// oldest-first; ties read activity first, like the export.
    private func buildDisplaySlice() -> LogDisplaySlice {
        let session = entries
        let activity = activityBuffer.entries
        let total = Self.headerLineCount + session.count + activity.count
        var taken: [ActivityEvent] = []
        taken.reserveCapacity(min(total, Self.displayLineLimit))
        var i = session.count
        var j = activity.count
        while taken.count < Self.displayLineLimit, i > 0 || j > 0 {
            if j == 0 || (i > 0 && session[i - 1].at >= activity[j - 1].at) {
                i -= 1
                taken.append(session[i])
            } else {
                j -= 1
                taken.append(activity[j])
            }
        }
        var lines = taken.reversed().map {
            ActivityRedaction.redact(ActivityExport.line(at: $0.at, tag: $0.tag, message: $0.message))
        }
        guard total > Self.displayLineLimit else {
            lines = headerLines(entryCount: session.count + activity.count) + lines
            return LogDisplaySlice(text: lines.joined(separator: "\n"), totalLines: total, note: nil)
        }
        return LogDisplaySlice(
            text: lines.joined(separator: "\n"),
            totalLines: total,
            note: "Showing the last 1,500 of \(total) lines. Share includes everything."
        )
    }

    /// The same two header lines the export starts with.
    private func headerLines(entryCount: Int) -> [String] {
        let dropped = activityBuffer.droppedCount + droppedCount
        return [
            "noticer log · \(entryCount) entries" + (dropped > 0 ? " (\(dropped) oldest dropped)" : ""),
            "app \(Self.appVersion()) (\(Self.appBuild())) · \(Self.deviceString()) · iOS \(UIDevice.current.systemVersion) · \(TimeZone.current.identifier) · sessions \(sessionCount)",
        ]
    }

    private static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private static func appBuild() -> String {
        Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "?"
    }

    /// Header plus activity and session lines interleaved by time, redacted.
    /// The lead-up before a session exports with the session itself.
    var text: String {
        textBuildCount += 1
        return ActivityExport.text(
            header: ActivityExportHeader(
                appVersion: Self.appVersion(),
                build: Self.appBuild(),
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
        revision += 1
    }

    /// A session started: bump the persisted counter the header reports.
    func noteSessionStart() {
        revision += 1
        sessionCount += 1
        scheduleActivitySave()
    }

    /// A new run starts with a fresh session transcript; activity persists.
    func clear() {
        revision += 1
        entries = []
        droppedCount = 0
        cachedSlice = nil
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

/// Newest on-screen transcript lines and the full line count.
struct LogDisplaySlice: Sendable {
    var text: String
    var totalLines: Int
    var note: String?
}

/// One shareable run transcript: the same redacted text as a `.txt`
/// file, so the share sheet attaches it instead of pasting it.
enum SessionLogExport {
    static let filePrefix = "noticer-log-"
    static let fileExtension = "txt"

    static func writeFile(text: String, date: Date = Date(), baseURL: URL? = nil) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(filePrefix)\(formatter.string(from: date)).\(fileExtension)"
        let url = (baseURL ?? FileManager.default.temporaryDirectory).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Deletes share files older than a day. Runs when the log screen opens.
    static func cleanupOldFiles(baseURL: URL? = nil, now: Date = Date()) {
        let folder = baseURL ?? FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }
        for url in files where url.lastPathComponent.hasPrefix(filePrefix)
            && url.pathExtension == fileExtension {
            let age = now.timeIntervalSince(url.contentModificationDate ?? now)
            if age > 86_400 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// One saved run read back: the full text plus its display slice.
struct PastRunContent: Sendable {
    var full: String
    var slice: LogDisplaySlice
}

enum PastRunLoader {
    /// Reads a saved run file. The slice shows the newest display lines
    /// with the same note as the live log; Share and Copy use `full`.
    static func load(url: URL) -> PastRunContent? {
        guard let full = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let lines = full.components(separatedBy: "\n")
        guard lines.count > SessionLog.displayLineLimit else {
            return PastRunContent(
                full: full,
                slice: LogDisplaySlice(text: full, totalLines: lines.count, note: nil)
            )
        }
        return PastRunContent(
            full: full,
            slice: LogDisplaySlice(
                text: lines.suffix(SessionLog.displayLineLimit).joined(separator: "\n"),
                totalLines: lines.count,
                note: "Showing the last 1,500 of \(lines.count) lines. Share includes everything."
            )
        )
    }
}

/// Session transcripts saved at stop/end, newest first.
enum SessionLogStore {
    static let folderName = "SessionLogs"
    static let filePrefix = "noticer-"
    static let fileExtension = "log"
    static let maxFiles = 50

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

    /// Saved runs, newest first. Only `noticer-*.log` files; anything
    /// else in the folder is ignored.
    static func runs(baseURL: URL? = nil) -> [SavedRun] {
        guard let folder = folder(baseURL: baseURL),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: folder,
                  includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                  options: .skipsHiddenFiles
              )
        else {
            return []
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(SavedRun.init(url:))
    }

    private static func folder(baseURL: URL?) -> URL? {
        if let baseURL {
            return baseURL
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent(folderName)
    }

    /// Captures the caller's text, then writes it on a background task.
    /// A serial queue keeps saves ordered: each save finishes before the
    /// next run's save starts. Awaiting the task waits for the write.
    @discardableResult
    static func save(_ text: String, at date: Date = Date(), baseURL: URL? = nil) -> Task<Void, Never> {
        Task {
            await SessionLogSaveQueue.shared.save(text, at: date, baseURL: baseURL)
        }
    }

    /// One save queue for the whole app, so concurrent stops can't
    /// interleave or prune each other's files.
    private actor SessionLogSaveQueue {
        static let shared = SessionLogSaveQueue()

        func save(_ text: String, at date: Date, baseURL: URL?) {
            guard let url = SessionLogStore.sessionURL(at: date, baseURL: baseURL) else {
                return
            }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? text.write(to: url, atomically: true, encoding: .utf8)
            SessionLogStore.prune(baseURL: baseURL)
        }
    }

    /// Deletes oldest `noticer-*.log` files past the cap. Test-visible so the
    /// cap is pinned without waiting for 50 runs.
    static func prune(baseURL: URL? = nil, cap: Int = maxFiles) {
        guard let folder = folder(baseURL: baseURL) else {
            return
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

/// One saved run transcript: its file, run date, and byte size.
struct SavedRun: Identifiable {
    var url: URL

    var id: URL { url }

    /// Parsed from the `noticer-YYYYMMDD-HHmmss.log` name, else the file's
    /// modification date.
    var date: Date? {
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix(SessionLogStore.filePrefix) {
            let stamp = name.dropFirst(SessionLogStore.filePrefix.count)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            if let parsed = formatter.date(from: String(stamp)) {
                return parsed
            }
        }
        return url.contentModificationDate
    }

    var size: Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    init(url: URL) {
        self.url = url
    }
}

private extension URL {
    var contentModificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
