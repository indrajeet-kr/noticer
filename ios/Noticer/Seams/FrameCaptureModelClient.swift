import Foundation
import NoticerCore
import UIKit

/// Decorator that saves each Muse call's exact input and answer for
/// offline eval. Without a store it passes everything through with a
/// single flag check. With one, saves run on the store actor after the
/// verdict (or error) returns, never blocking the call path. Cancellation
/// records nothing. Neither side ever carries the API key.
struct FrameCaptureModelClient: ModelClient {
    var inner: any ModelClient
    var store: FrameCaptureStore?
    var model: String
    var promptHash: String

    func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        guard let store else {
            return try await inner.complete(request)
        }
        let start = Date()
        do {
            let verdict = try await inner.complete(request)
            let ms = Date().timeIntervalSince(start) * 1000
            if let number = await store.reserveCall(estimatedBytes: Self.estimate(request)) {
                Task {
                    await store.writeVerdict(
                        callNumber: number,
                        request: request,
                        verdict: verdict,
                        latencyMs: ms,
                        model: model,
                        promptHash: promptHash
                    )
                }
            }
            return verdict
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            let description = String(describing: error)
            if let number = await store.reserveCall(estimatedBytes: Self.estimate(request)) {
                Task {
                    await store.writeError(
                        callNumber: number,
                        request: request,
                        error: description,
                        model: model,
                        promptHash: promptHash
                    )
                }
            }
            throw error
        }
    }

    private static func estimate(_ request: ModelRequest) -> Int {
        request.keyframes.reduce(0) { $0 + $1.jpegData.count }
    }
}

/// Stable 16-hex-char FNV-1a hash of the developer prompt, so a saved
/// call says which prompt produced its answer.
enum FrameCapturePrompt {
    static func hash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_037_393_879_535
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

/// One session's frame capture: call folders under
/// `Documents/FrameCapture/<sessionStart>/`. Every save runs here, off
/// the call path and off the main thread, strictly ordered. Stops at
/// 600 calls or 60 MB, logging the cap once.
actor FrameCaptureStore {
    static let folderName = "FrameCapture"
    static let maxCalls = 600
    static let maxBytes = 60_000_000
    static let maxSessions = 10

    private let root: URL?
    private var sessionDir: URL?
    private let sessionName: String
    private let mode: String
    private let startNeeds: [Need]
    private let log: @Sendable (String, String) -> Void
    private let callCap: Int
    private let byteCap: Int
    private var nextCallNumber = 1
    private var bytesWritten = 0
    private var didLogCap = false
    private var pendingWrites = 0

    init(
        sessionStart: Date = Date(),
        mode: String,
        needs: [Need],
        log: @escaping @Sendable (String, String) -> Void,
        baseURL: URL? = nil,
        callCap: Int = maxCalls,
        byteCap: Int = maxBytes
    ) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        sessionName = formatter.string(from: sessionStart)
        if let baseURL {
            root = baseURL.appendingPathComponent(Self.folderName)
        } else {
            root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent(Self.folderName)
        }
        self.mode = mode
        startNeeds = needs
        self.log = log
        self.callCap = callCap
        self.byteCap = byteCap
    }

    /// Test seam: waits out every reserved write.
    func drain() async {
        while pendingWrites > 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Session start: root + session folder, backup exclusion, prune to
    /// the newest sessions, `session.json`, and the `[CAPTURE] on` line.
    func begin() {
        guard let root else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var mutableRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableRoot.setResourceValues(values)
        var dir = root.appendingPathComponent(sessionName)
        var counter = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = root.appendingPathComponent("\(sessionName)-\(counter)")
            counter += 1
        }
        sessionDir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prune(root: root, keeping: dir)
        let session = CapturedSession(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            deviceModel: Self.deviceString(),
            systemVersion: UIDevice.current.systemVersion,
            mode: mode,
            needs: startNeeds
        )
        if let data = try? CapturedCall.jsonEncoder().encode(session) {
            try? data.write(to: dir.appendingPathComponent("session.json"))
        }
        log("CAPTURE", "on dir=\(Self.folderName)/\(dir.lastPathComponent)")
    }

    /// Reserves the next call number, or nil at the cap (logged once).
    /// Fast: no file I/O. Numbers follow reservation order, so call
    /// numbers increase down the call path.
    func reserveCall(estimatedBytes: Int) -> Int? {
        if nextCallNumber > callCap || bytesWritten + estimatedBytes > byteCap {
            if !didLogCap {
                didLogCap = true
                log("CAPTURE", "cap reached")
            }
            return nil
        }
        let number = nextCallNumber
        nextCallNumber += 1
        pendingWrites += 1
        return number
    }

    func save(
        request: ModelRequest,
        verdict: ModelVerdict,
        latencyMs: Double,
        model: String,
        promptHash: String
    ) {
        guard let number = reserveCall(estimatedBytes: request.keyframes.reduce(0) { $0 + $1.jpegData.count }) else {
            return
        }
        writeVerdict(
            callNumber: number,
            request: request,
            verdict: verdict,
            latencyMs: latencyMs,
            model: model,
            promptHash: promptHash
        )
    }

    func save(request: ModelRequest, error: String, model: String, promptHash: String) {
        guard let number = reserveCall(estimatedBytes: request.keyframes.reduce(0) { $0 + $1.jpegData.count }) else {
            return
        }
        writeError(callNumber: number, request: request, error: error, model: model, promptHash: promptHash)
    }

    func writeVerdict(
        callNumber: Int,
        request: ModelRequest,
        verdict: ModelVerdict,
        latencyMs: Double,
        model: String,
        promptHash: String
    ) {
        write(callNumber: callNumber, request: request, model: model, promptHash: promptHash) { dir, encoder in
            var bytes = 0
            if let data = try? encoder.encode(CapturedVerdict(verdict: verdict, latencyMs: latencyMs)) {
                try? data.write(to: dir.appendingPathComponent("verdict.json"))
                bytes += data.count
            }
            return bytes
        }
    }

    func writeError(callNumber: Int, request: ModelRequest, error: String, model: String, promptHash: String) {
        write(callNumber: callNumber, request: request, model: model, promptHash: promptHash) { dir, encoder in
            var bytes = 0
            if let data = try? encoder.encode(CapturedError(error: error)) {
                try? data.write(to: dir.appendingPathComponent("error.json"))
                bytes += data.count
            }
            return bytes
        }
    }

    private func write(
        callNumber: Int,
        request: ModelRequest,
        model: String,
        promptHash: String,
        writeAnswer: (URL, JSONEncoder) throws -> Int
    ) {
        defer { pendingWrites -= 1 }
        guard let sessionDir else { return }
        let name = String(format: "call-%04d", callNumber)
        let dir = sessionDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = CapturedCall.jsonEncoder()
        let captured = CapturedRequest(request: request, model: model, promptHash: promptHash)
        var bytes = request.keyframes.reduce(0) { $0 + $1.jpegData.count }
        if let data = try? encoder.encode(captured) {
            try? data.write(to: dir.appendingPathComponent("request.json"))
            bytes += data.count
        }
        for frame in request.keyframes {
            try? frame.jpegData.write(to: dir.appendingPathComponent("kf-\(frame.id).jpg"))
        }
        bytes += (try? writeAnswer(dir, encoder)) ?? 0
        bytesWritten += bytes
        log("CAPTURE", "saved \(name) kf=\(request.keyframes.count) bytes=\(bytes / 1024)KB")
    }

    private func prune(root: URL, keeping current: URL) {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return
        }
        let sessions = folders
            .filter { $0.lastPathComponent != current.lastPathComponent }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard sessions.count + 1 > Self.maxSessions else {
            return
        }
        for url in sessions.prefix(sessions.count + 1 - Self.maxSessions) {
            try? FileManager.default.removeItem(at: url)
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

    // MARK: - Settings

    static func rootURL(baseURL: URL? = nil) -> URL? {
        if let baseURL {
            return baseURL.appendingPathComponent(folderName)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folderName)
    }

    /// Saved sessions and their total bytes, for the settings row.
    static func usage(baseURL: URL? = nil) -> (sessions: Int, bytes: Int) {
        guard let root = rootURL(baseURL: baseURL),
              let folders = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: nil,
                  options: .skipsHiddenFiles
              )
        else {
            return (0, 0)
        }
        return (folders.count, Self.sizes(at: root))
    }

    private static func sizes(at url: URL) -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else {
            return 0
        }
        var total = 0
        for entry in contents {
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                total += sizes(at: entry)
            } else {
                total += values?.fileSize ?? 0
            }
        }
        return total
    }

    static func deleteAll(baseURL: URL? = nil) {
        guard let root = rootURL(baseURL: baseURL) else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
