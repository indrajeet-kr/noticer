import Foundation

// MARK: - Saved Muse calls (pure models, Linux-safe)

// A `request.json` keyframe row: everything but the bytes, which live in
// `kf-<id>.jpg` next to it and are read back on load.
public struct CapturedKeyframe: Codable, Equatable, Sendable {
    public var id: String
    public var capturedAt: Date
    public var ageSeconds: TimeInterval
    public var episodeID: String
    public var sharpness: Double?
    public var fileName: String
    public var byteCount: Int

    public init(
        id: String,
        capturedAt: Date,
        ageSeconds: TimeInterval,
        episodeID: String,
        sharpness: Double? = nil,
        fileName: String,
        byteCount: Int
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.ageSeconds = ageSeconds
        self.episodeID = episodeID
        self.sharpness = sharpness
        self.fileName = fileName
        self.byteCount = byteCount
    }

    public init(keyframe: Keyframe) {
        self.init(
            id: keyframe.id,
            capturedAt: keyframe.capturedAt,
            ageSeconds: keyframe.ageSeconds,
            episodeID: keyframe.episodeID,
            sharpness: keyframe.sharpness,
            fileName: "kf-\(keyframe.id).jpg",
            byteCount: keyframe.jpegData.count
        )
    }
}

// `request.json`: the exact model input, minus inline bytes.
public struct CapturedRequest: Codable, Equatable, Sendable {
    public var purpose: ModelCallPurpose?
    public var keyframes: [CapturedKeyframe]
    public var needs: [Need]
    public var openNeeds: [OpenNeedContext]
    public var focusNeedID: String?
    public var unpromptedStartedIDs: [String]
    public var model: String
    public var promptHash: String
    public var capturedAt: Date

    public init(
        purpose: ModelCallPurpose?,
        keyframes: [CapturedKeyframe],
        needs: [Need],
        openNeeds: [OpenNeedContext],
        focusNeedID: String?,
        unpromptedStartedIDs: [String],
        model: String,
        promptHash: String,
        capturedAt: Date
    ) {
        self.purpose = purpose
        self.keyframes = keyframes
        self.needs = needs
        self.openNeeds = openNeeds
        self.focusNeedID = focusNeedID
        self.unpromptedStartedIDs = unpromptedStartedIDs
        self.model = model
        self.promptHash = promptHash
        self.capturedAt = capturedAt
    }

    public init(request: ModelRequest, model: String, promptHash: String, capturedAt: Date = Date()) {
        self.init(
            purpose: request.purpose,
            keyframes: request.keyframes.map(CapturedKeyframe.init(keyframe:)),
            needs: request.needs,
            openNeeds: request.openNeeds,
            focusNeedID: request.focusNeedID,
            unpromptedStartedIDs: request.unpromptedStartedIDs,
            model: model,
            promptHash: promptHash,
            capturedAt: capturedAt
        )
    }
}

// `verdict.json`: the answer plus its latency.
public struct CapturedVerdict: Codable, Equatable, Sendable {
    public var verdict: ModelVerdict
    public var latencyMs: Double

    public init(verdict: ModelVerdict, latencyMs: Double) {
        self.verdict = verdict
        self.latencyMs = latencyMs
    }
}

// `error.json`: the failure description when no verdict came back.
public struct CapturedError: Codable, Equatable, Sendable {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}

// `session.json`: what the run was.
public struct CapturedSession: Codable, Equatable, Sendable {
    public var appVersion: String
    public var deviceModel: String
    public var systemVersion: String
    public var mode: String
    public var needs: [Need]

    public init(appVersion: String, deviceModel: String, systemVersion: String, mode: String, needs: [Need]) {
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.mode = mode
        self.needs = needs
    }
}

// One saved call: the request rebuilt with its JPEG bytes, plus the
// answer when one came back. Folders with only `error.json`, or with
// no verdict at all, load with `verdict == nil`.
public struct CapturedCall: Equatable, Sendable {
    public var name: String
    public var request: CapturedRequest
    public var verdict: CapturedVerdict?
    public var error: CapturedError?
    public var modelRequest: ModelRequest

    public static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func jsonDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Loads every `call-*` folder under a session directory, oldest
    /// first. A folder without `request.json`, or whose JPEG bytes are
    /// missing, is skipped; a present-but-undecodable file throws.
    public static func load(directory: URL) throws -> [CapturedCall] {
        let folders = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        .filter { $0.lastPathComponent.hasPrefix("call-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = jsonDecoder()
        var calls: [CapturedCall] = []
        for folder in folders {
            guard let captured = try loadOne(folder: folder, decoder: decoder) else {
                continue
            }
            calls.append(captured)
        }
        return calls
    }

    private static func loadOne(folder: URL, decoder: JSONDecoder) throws -> CapturedCall? {
        guard let requestData = try? Data(contentsOf: folder.appendingPathComponent("request.json")) else {
            return nil
        }
        let request = try decoder.decode(CapturedRequest.self, from: requestData)
        var keyframes: [Keyframe] = []
        for row in request.keyframes {
            guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(row.fileName)),
                  bytes.count == row.byteCount
            else {
                return nil
            }
            keyframes.append(Keyframe(
                id: row.id,
                capturedAt: row.capturedAt,
                ageSeconds: row.ageSeconds,
                episodeID: row.episodeID,
                sharpness: row.sharpness,
                jpegData: bytes
            ))
        }
        let verdict: CapturedVerdict?
        if let data = try? Data(contentsOf: folder.appendingPathComponent("verdict.json")) {
            verdict = try decoder.decode(CapturedVerdict.self, from: data)
        } else {
            verdict = nil
        }
        let error: CapturedError?
        if let data = try? Data(contentsOf: folder.appendingPathComponent("error.json")) {
            error = try decoder.decode(CapturedError.self, from: data)
        } else {
            error = nil
        }
        return CapturedCall(
            name: folder.lastPathComponent,
            request: request,
            verdict: verdict,
            error: error,
            modelRequest: ModelRequest(
                keyframes: keyframes,
                needs: request.needs,
                openNeeds: request.openNeeds,
                purpose: request.purpose,
                focusNeedID: request.focusNeedID,
                unpromptedStartedIDs: request.unpromptedStartedIDs
            )
        )
    }
}
