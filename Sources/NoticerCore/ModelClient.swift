import Foundation

/// What a model client needs from the phone. Prompt text and HTTP bodies are the agent track's.
/// Whether `needs` is the full list or only open needs is not decided here.
public struct ModelRequest: Equatable, Sendable {
    public var keyframes: [Keyframe]
    public var needs: [Need]
    /// Needs the engine currently holds open. Empty for callers that predate it.
    public var openNeeds: [OpenNeedContext]
    /// Engine call purpose (`latch`, `heartbeat`, `recheck`, `confirm`) for logging and telemetry.
    public var purpose: ModelCallPurpose?
    /// Confirm calls check only this need. Nil for every other purpose.
    public var focusNeedID: String?
    /// Needs with an armed unprompted start. The model may close one by
    /// naming it on `report_need_resolved` when its handled state is true.
    public var unpromptedStartedIDs: [String]

    public init(
        keyframes: [Keyframe],
        needs: [Need],
        openNeeds: [OpenNeedContext] = [],
        purpose: ModelCallPurpose? = nil,
        focusNeedID: String? = nil,
        unpromptedStartedIDs: [String] = []
    ) {
        self.keyframes = keyframes
        self.needs = needs
        self.openNeeds = openNeeds
        self.purpose = purpose
        self.focusNeedID = focusNeedID
        self.unpromptedStartedIDs = unpromptedStartedIDs
    }
}

/// One open need, as the scene checker sees it. Tells the model what is
/// already open so it reports "handled" or "still open" instead of answering
/// `unknown` or re-latching.
public struct OpenNeedContext: Equatable, Sendable {
    public var needID: String
    public var latchedSecondsAgo: TimeInterval
    public var cueSpoken: Bool
    /// The unmet problem state that opened this need.
    public var problemCondition: String
    /// What counts as handled, from `handledCondition` and `selfNoticeSignal` (never `visualCondition`).
    public var resolutionSignal: String
    /// Seconds since his last matching intervention, when he recently acted on this need.
    public var wearerActedSecondsAgo: TimeInterval?

    public init(
        needID: String,
        latchedSecondsAgo: TimeInterval,
        cueSpoken: Bool,
        problemCondition: String = "",
        resolutionSignal: String,
        wearerActedSecondsAgo: TimeInterval? = nil
    ) {
        self.needID = needID
        self.latchedSecondsAgo = latchedSecondsAgo
        self.cueSpoken = cueSpoken
        self.problemCondition = problemCondition
        self.resolutionSignal = resolutionSignal
        self.wearerActedSecondsAgo = wearerActedSecondsAgo
    }
}

/// Live Muse Spark, a recorded tape, or a later backend. All three return a `ModelVerdict`.
public protocol ModelClient: Sendable {
    func complete(_ request: ModelRequest) async throws -> ModelVerdict
}
