import Foundation

/// Normalized image rect. Origin and units are the Vision request's coordinate space;
/// this package does not convert them.
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

/// One person rectangle from the on-device gate.
/// Size and aspect are inputs. This type does not decide adult versus baby.
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

/// What the iOS Vision gate reports for one frame.
/// Counting glances, hands, and visitors belongs to the core track.
/// A person count here includes anyone Vision marks, baby and screen included.
public struct FrameGateSnapshot: Equatable, Sendable, Codable {
    public var capturedAt: Date
    public var people: [ObservedPerson]
    public var wearerHandsVisible: Bool
    /// Set by the iOS track on the frame a wearer hand newly appears. Not computed here.
    public var handGateRisingEdge: Bool

    public init(
        capturedAt: Date,
        people: [ObservedPerson],
        wearerHandsVisible: Bool,
        handGateRisingEdge: Bool
    ) {
        self.capturedAt = capturedAt
        self.people = people
        self.wearerHandsVisible = wearerHandsVisible
        self.handGateRisingEdge = handGateRisingEdge
    }

    private enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case people
        case wearerHandsVisible = "wearer_hands_visible"
        case handGateRisingEdge = "hand_gate_rising_edge"
    }
}
