import Foundation

/// Numbers the PRD states outright. Tracks share these so the engine,
/// the agent caps, and the app don't each pick a different value.
/// Nothing here advances a timer or changes mastery.
public enum SessionLimits {
    /// Mom can author this many needs. The demo cut list ships two of them.
    public static let maxAuthoredNeeds = 6
    /// How many needs may be open at once, in mom's priority order.
    public static let maxOpenNeeds = 2
    public static let maxSessionSeconds: TimeInterval = 30 * 60
    public static let maxModelCallsPerSession = 300
    /// At most one cue across all needs in this window.
    public static let cueRateLimitSeconds: TimeInterval = 3 * 60
    public static let relatchCooldownSeconds: TimeInterval = 5 * 60
    /// Latch calls are at least this far apart.
    public static let latchMinIntervalSeconds: TimeInterval = 10
    /// No cue from evidence older than this without a re-check.
    public static let staleEvidenceSeconds: TimeInterval = 30
    /// No person keyframe for this long closes the need as unknown,
    /// unless the core track decides he is still at the same chore.
    public static let noPersonKeyframeCloseSeconds: TimeInterval = 45
    public static let keyframeBufferSeconds: TimeInterval = 60
    /// A glance episode starts on a rising edge after the partner has been absent this long.
    public static let glanceAbsentSeconds: TimeInterval = 2
    /// Also keep one sharp frame every this often while she stays in view.
    public static let continuousPresenceKeyframeSeconds: TimeInterval = 4
    public static let latchMinKeyframes = 2
    public static let latchMinKeyframeSpacingSeconds: TimeInterval = 4
    public static let heartbeatSeconds: TimeInterval = 8
    /// Second person must persist this many consecutive frames before upload pauses.
    public static let visitorPersistenceFrames = 3
    public static let defaultHeadStartSeconds: TimeInterval = 90
    public static let headStartCapSeconds: TimeInterval = 120
    /// DAT allows 2, 7, 15, 24, or 30. The product asks for 2.
    public static let requestedFramesPerSecond = 2
}

/// Fade constants. Applying them (updating a score, retiring a need) is core-track work.
///
/// Head start: `H = H0 * (1 + headStartMasteryCoefficient * m)`, then the session cap.
/// Self-notice inside the window: `m = m + selfNoticeStep * (1 - m)`.
/// Cue fired: `m = cueFiredMultiplier * m`.
/// A dismissed false cue does not change `m`.
/// `resolved_by_partner` does not change `m`.
public enum CueFadeSpec {
    public static let initialScore = 0.0
    public static let selfNoticeStep = 0.25
    public static let cueFiredMultiplier = 0.85
    public static let quietThreshold = 0.5
    public static let retireSelfNoticeStreak = 3
    public static let unretireMissStreak = 2
    public static let headStartMasteryCoefficient = 2.0
}

/// Repo-relative drop folders. Clips and cached model bodies stay out of Swift code.
public enum FixtureLayout {
    public static let clipsDirectory = "fixtures/clips"
    public static let modelResponsesDirectory = "fixtures/model-responses"
}
