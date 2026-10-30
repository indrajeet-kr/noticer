import Foundation

/// Downsampled luma. Samples are row-major, 0...255. The gate never decodes JPEG;
/// the phone fills this from a frame and discards the bitmap afterward.
public struct LumaPlane: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var samples: [UInt8]

    public init(width: Int, height: Int, samples: [UInt8]) {
        self.width = width
        self.height = height
        self.samples = samples
    }
}

/// Knobs for the on-phone signal gate. These are not model calls and not the
/// head-start, mastery, or cap numbers in `SessionLimits`.
public enum SignalGateTuning {
    /// Longest side of the luma plane used for motion and sharpness.
    public static let analysisMaxEdge = 64
    /// Longest side of a JPEG sent to Muse Spark.
    public static let uploadMaxEdge = 512
    /// JPEG quality for frames that leave the phone for Muse Spark.
    public static let jpegQuality = 0.65
    /// Mean absolute luma change, 0...1, that counts as scene motion.
    public static let motionThreshold = 0.03
    /// A larger jump. While a need is open this can ask for an early heartbeat.
    public static let activityEdgeMotion = 0.12
    /// Laplacian variance below this is a flat frame. A periodic sample skips it.
    public static let flatSharpness = 0.000_4
    /// No open need: admit a still scene at most this often, plus one rising glance.
    /// Short enough that a static scene reaches latch eligibility in seconds;
    /// latch calls stay rate-limited by the timing profile and the call budget.
    public static let idleAdmitInterval: TimeInterval = 8
    /// Open need: a changed or due frame may enter the strip this often.
    /// The engine still heartbeats on `SessionLimits.heartbeatSeconds` (8 s).
    public static let openAdmitInterval: TimeInterval = 4
    /// Rising-edge admits are at least this far apart.
    public static let activityEdgeMinInterval: TimeInterval = 4
}

/// One measurement of a luma plane against the previous plane.
public struct SignalReading: Equatable, Sendable {
    public var motionScore: Double
    public var sharpness: Double

    public init(motionScore: Double, sharpness: Double) {
        self.motionScore = motionScore
        self.sharpness = sharpness
    }
}

/// What the signal gate wants the engine to do with this frame.
/// `sceneActive` admits a keyframe. `activityEdge` may ask for an early
/// heartbeat while a need is open. Neither one is a person or a hand.
public struct SignalDecision: Equatable, Sendable {
    public var motionScore: Double
    public var sharpness: Double
    public var sceneActive: Bool
    public var activityEdge: Bool

    public init(motionScore: Double, sharpness: Double, sceneActive: Bool, activityEdge: Bool) {
        self.motionScore = motionScore
        self.sharpness = sharpness
        self.sceneActive = sceneActive
        self.activityEdge = activityEdge
    }

    /// The frame is worth handing on: it enters the strip, or it asks for an early check.
    public var passes: Bool { sceneActive || activityEdge }
}

/// Reused across frames. The previous luma buffer keeps its storage when the size matches.
public struct SignalGateState: Sendable {
    public var previousSamples: [UInt8]
    public var previousWidth: Int
    public var previousHeight: Int
    public var hasPrevious: Bool
    public var lastAdmitAt: Date?
    public var lastEdgeAt: Date?
    public var previousMotion: Double

    public init() {
        previousSamples = []
        previousWidth = 0
        previousHeight = 0
        hasPrevious = false
        lastAdmitAt = nil
        lastEdgeAt = nil
        previousMotion = 0
    }

    public mutating func reset() {
        self = SignalGateState()
    }

    mutating func store(_ plane: LumaPlane) {
        if previousSamples.count == plane.samples.count {
            for index in plane.samples.indices {
                previousSamples[index] = plane.samples[index]
            }
        } else {
            previousSamples = plane.samples
        }
        previousWidth = plane.width
        previousHeight = plane.height
        hasPrevious = true
    }
}

/// Deterministic frame gate. Mean absolute luma difference, plus Laplacian variance.
/// No model, no Vision request, no Core ML.
public enum SignalGate {
    public static func measure(current: LumaPlane, previous: LumaPlane?) -> SignalReading {
        let sharpness = laplacianVariance(current)
        guard let previous, sameShape(current, previous) else {
            return SignalReading(motionScore: 1, sharpness: sharpness)
        }
        return SignalReading(motionScore: motionScore(current: current, previous: previous), sharpness: sharpness)
    }

    /// `plane` nil means the frame could not be read. That frame is held.
    public static func evaluate(
        plane: LumaPlane?,
        at time: Date,
        needOpen: Bool,
        state: inout SignalGateState
    ) -> SignalDecision {
        guard let plane else {
            return SignalDecision(motionScore: 0, sharpness: 0, sceneActive: false, activityEdge: false)
        }

        let reading = measure(current: plane, previous: storedPlane(state))
        let changed = reading.motionScore >= SignalGateTuning.motionThreshold
        let informative = reading.sharpness >= SignalGateTuning.flatSharpness || changed
        let interval = needOpen ? SignalGateTuning.openAdmitInterval : SignalGateTuning.idleAdmitInterval
        let periodic: Bool
        if let lastAdmitAt = state.lastAdmitAt {
            periodic = time.timeIntervalSince(lastAdmitAt) >= interval
        } else {
            periodic = true
        }
        let rising = reading.motionScore >= SignalGateTuning.activityEdgeMotion
            && state.previousMotion < SignalGateTuning.activityEdgeMotion
        let edgeAllowed: Bool
        if let lastEdgeAt = state.lastEdgeAt {
            edgeAllowed = time.timeIntervalSince(lastEdgeAt) >= SignalGateTuning.activityEdgeMinInterval
        } else {
            edgeAllowed = true
        }
        let risingAllowed = rising && edgeAllowed

        let sceneActive: Bool
        let activityEdge: Bool
        if needOpen {
            sceneActive = (changed || periodic) && informative
            activityEdge = risingAllowed
        } else {
            // Idle calls stay sparse: a slow sample, or one frame when motion jumps.
            // Sustained motion does not admit every frame, so a latch cannot fire at 2 fps.
            sceneActive = (periodic && informative) || risingAllowed
            activityEdge = false
        }

        if sceneActive {
            state.lastAdmitAt = time
        }
        if risingAllowed {
            state.lastEdgeAt = time
        }
        state.previousMotion = reading.motionScore
        state.store(plane)
        return SignalDecision(
            motionScore: reading.motionScore,
            sharpness: reading.sharpness,
            sceneActive: sceneActive,
            activityEdge: activityEdge
        )
    }

    public static func laplacianVariance(_ plane: LumaPlane) -> Double {
        let width = plane.width
        let height = plane.height
        guard width >= 3, height >= 3, plane.samples.count == width * height else {
            return 0
        }
        let samples = plane.samples
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let center = Double(samples[index])
                let response = Double(samples[index - width])
                    + Double(samples[index + width])
                    + Double(samples[index - 1])
                    + Double(samples[index + 1])
                    - 4 * center
                let normalized = response / 255.0
                sum += normalized
                sumSquares += normalized * normalized
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        let variance = sumSquares / count - mean * mean
        return variance > 0 ? variance : 0
    }

    public static func motionScore(current: LumaPlane, previous: LumaPlane) -> Double {
        guard sameShape(current, previous), !current.samples.isEmpty else {
            return 0
        }
        var total = 0.0
        for index in current.samples.indices {
            total += abs(Double(current.samples[index]) - Double(previous.samples[index]))
        }
        return (total / Double(current.samples.count)) / 255.0
    }

    private static func sameShape(_ lhs: LumaPlane, _ rhs: LumaPlane) -> Bool {
        lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.samples.count == rhs.samples.count
            && lhs.samples.count == lhs.width * lhs.height
    }

    private static func storedPlane(_ state: SignalGateState) -> LumaPlane? {
        guard state.hasPrevious else { return nil }
        return LumaPlane(width: state.previousWidth, height: state.previousHeight, samples: state.previousSamples)
    }
}
