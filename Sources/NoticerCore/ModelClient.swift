import Foundation

/// What a model client needs from the phone. Prompt text and HTTP bodies are the agent track's.
/// Whether `needs` is the full list or only open needs is not decided here.
public struct ModelRequest: Equatable, Sendable {
    public var keyframes: [Keyframe]
    public var needs: [Need]
    /// Needs the engine currently holds open. Empty for callers that predate it.
    public var openNeeds: [OpenNeedContext]

    public init(keyframes: [Keyframe], needs: [Need], openNeeds: [OpenNeedContext] = []) {
        self.keyframes = keyframes
        self.needs = needs
        self.openNeeds = openNeeds
    }
}

/// One open need, as the scene checker sees it. Tells the model what is
/// already open so it reports "handled" or "still open" instead of answering
/// `unknown` or re-latching.
public struct OpenNeedContext: Equatable, Sendable {
    public var needID: String
    public var latchedSecondsAgo: TimeInterval
    public var cueSpoken: Bool
    /// What counts as handled, from the need's self-notice signal and visual condition.
    public var resolutionSignal: String

    public init(needID: String, latchedSecondsAgo: TimeInterval, cueSpoken: Bool, resolutionSignal: String) {
        self.needID = needID
        self.latchedSecondsAgo = latchedSecondsAgo
        self.cueSpoken = cueSpoken
        self.resolutionSignal = resolutionSignal
    }
}

/// Live Muse Spark, a recorded tape, or a later backend. All three return a `ModelVerdict`.
public protocol ModelClient: Sendable {
    func complete(_ request: ModelRequest) async throws -> ModelVerdict
}
