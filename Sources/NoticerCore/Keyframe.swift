import Foundation

/// One sharp frame chosen for a model strip.
///
/// `ageSeconds` is how far this frame sits behind the newest frame in the strip
/// (the PRD's t-28s, t-9s, t=0). Bytes stay in memory.
public struct Keyframe: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var capturedAt: Date
    public var ageSeconds: TimeInterval
    public var episodeID: String
    /// Laplacian variance, once something measures it. Nil in Step 0.
    public var sharpness: Double?
    public var jpegData: Data

    public init(
        id: String,
        capturedAt: Date,
        ageSeconds: TimeInterval,
        episodeID: String,
        sharpness: Double? = nil,
        jpegData: Data
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.ageSeconds = ageSeconds
        self.episodeID = episodeID
        self.sharpness = sharpness
        self.jpegData = jpegData
    }

    public init(
        id: String,
        frame: CameraFrame,
        ageSeconds: TimeInterval,
        episodeID: String,
        sharpness: Double? = nil
    ) {
        self.init(
            id: id,
            capturedAt: frame.capturedAt,
            ageSeconds: ageSeconds,
            episodeID: episodeID,
            sharpness: sharpness,
            jpegData: frame.jpegData
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case ageSeconds = "age_seconds"
        case episodeID = "episode_id"
        case sharpness
        case jpegData = "jpeg_data"
    }
}
