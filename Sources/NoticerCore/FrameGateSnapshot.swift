import Foundation

/// Normalized image rect in the caller's coordinate space. This package does not
/// convert units, and it does not detect the rect.
public struct NormalizedRect: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One person rectangle supplied by the caller.
/// Size and aspect are inputs. This type does not decide adult versus baby.
/// Live sessions leave this empty. Partner presence comes back from Muse Spark.
/// Replay and tests still pass rects so the visitor rule can run without a model.
public struct ObservedPerson: Equatable, Sendable, Codable {
    public var boundingBox: NormalizedRect
    /// Width divided by height of `boundingBox`.
    public var aspectRatio: Double

    public init(boundingBox: NormalizedRect, aspectRatio: Double) {
        self.boundingBox = boundingBox
        self.aspectRatio = aspectRatio
    }

    private enum CodingKeys: String, CodingKey {
        case boundingBox = "bounding_box"
        case aspectRatio = "aspect_ratio"
    }
}

/// What one frame tells the engine.
///
/// `people` and `handGateRisingEdge` are scripted or test inputs. The live gate
/// leaves them empty and sets `sceneActive` / `activityEdge` from luma motion
/// and Laplacian sharpness. Partner in view and wearer hands come back on the
/// model assessment, not from this snapshot.
public struct FrameGateSnapshot: Equatable, Sendable, Codable {
    public var capturedAt: Date
    public var people: [ObservedPerson]
    public var wearerHandsVisible: Bool
    /// Set by a scripted gate or a test. The live signal gate leaves this false.
    public var handGateRisingEdge: Bool
    /// Mean absolute luma change, 0...1. Nil when the frame was not measured.
    public var motionScore: Double?
    /// Laplacian variance of the downsampled luma. Nil when the frame was not measured.
    public var sharpness: Double?
    /// The signal gate wants this frame in the keyframe strip.
    public var sceneActive: Bool
    /// Strong motion while a need is open. The engine may heartbeat early.
    public var activityEdge: Bool

    public init(
        capturedAt: Date,
        people: [ObservedPerson],
        wearerHandsVisible: Bool,
        handGateRisingEdge: Bool,
        motionScore: Double? = nil,
        sharpness: Double? = nil,
        sceneActive: Bool = false,
        activityEdge: Bool = false
    ) {
        self.capturedAt = capturedAt
        self.people = people
        self.wearerHandsVisible = wearerHandsVisible
        self.handGateRisingEdge = handGateRisingEdge
        self.motionScore = motionScore
        self.sharpness = sharpness
        self.sceneActive = sceneActive
        self.activityEdge = activityEdge
    }

    private enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case people
        case wearerHandsVisible = "wearer_hands_visible"
        case handGateRisingEdge = "hand_gate_rising_edge"
        case motionScore = "motion_score"
        case sharpness
        case sceneActive = "scene_active"
        case activityEdge = "activity_edge"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        people = try container.decode([ObservedPerson].self, forKey: .people)
        wearerHandsVisible = try container.decode(Bool.self, forKey: .wearerHandsVisible)
        handGateRisingEdge = try container.decode(Bool.self, forKey: .handGateRisingEdge)
        motionScore = try container.decodeIfPresent(Double.self, forKey: .motionScore)
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness)
        sceneActive = try container.decodeIfPresent(Bool.self, forKey: .sceneActive) ?? false
        activityEdge = try container.decodeIfPresent(Bool.self, forKey: .activityEdge) ?? false
    }
}
