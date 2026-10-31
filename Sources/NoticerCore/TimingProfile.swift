import Foundation

/// Timing numbers the engine, the session pipeline, and the cap gate read.
/// `.standard` is today's product timing. `.quick` is the same session with
/// shorter waits, for a test or a demo. Fade math and the per-session call
/// cap stay in `CueFadeSpec` and `SessionLimits`.
public struct TimingProfile: Equatable, Sendable {
    public var latchMinIntervalSeconds: TimeInterval
    public var latchMinKeyframes: Int
    public var latchMinKeyframeSpacingSeconds: TimeInterval
    public var heartbeatSeconds: TimeInterval
    public var defaultHeadStartSeconds: TimeInterval
    public var headStartCapSeconds: TimeInterval
    public var cueRateLimitSeconds: TimeInterval
    public var relatchCooldownSeconds: TimeInterval
    public var staleEvidenceSeconds: TimeInterval
    public var noPersonKeyframeCloseSeconds: TimeInterval
    public var glanceAbsentSeconds: TimeInterval
    public var continuousPresenceKeyframeSeconds: TimeInterval
    public var keyframeBufferSeconds: TimeInterval
    public var maxSessionSeconds: TimeInterval
    public var idleAdmitIntervalSeconds: TimeInterval
    public var minCallGapSeconds: TimeInterval
    public var postCueNoPersonGraceSeconds: TimeInterval

    public init(
        latchMinIntervalSeconds: TimeInterval,
        latchMinKeyframes: Int,
        latchMinKeyframeSpacingSeconds: TimeInterval,
        heartbeatSeconds: TimeInterval,
        defaultHeadStartSeconds: TimeInterval,
        headStartCapSeconds: TimeInterval,
        cueRateLimitSeconds: TimeInterval,
        relatchCooldownSeconds: TimeInterval,
        staleEvidenceSeconds: TimeInterval,
        noPersonKeyframeCloseSeconds: TimeInterval,
        glanceAbsentSeconds: TimeInterval,
        continuousPresenceKeyframeSeconds: TimeInterval,
        keyframeBufferSeconds: TimeInterval,
        maxSessionSeconds: TimeInterval,
        idleAdmitIntervalSeconds: TimeInterval = SignalGateTuning.idleAdmitInterval,
        minCallGapSeconds: TimeInterval = 0,
        postCueNoPersonGraceSeconds: TimeInterval = 0
    ) {
        self.latchMinIntervalSeconds = latchMinIntervalSeconds
        self.latchMinKeyframes = latchMinKeyframes
        self.latchMinKeyframeSpacingSeconds = latchMinKeyframeSpacingSeconds
        self.heartbeatSeconds = heartbeatSeconds
        self.defaultHeadStartSeconds = defaultHeadStartSeconds
        self.headStartCapSeconds = headStartCapSeconds
        self.cueRateLimitSeconds = cueRateLimitSeconds
        self.relatchCooldownSeconds = relatchCooldownSeconds
        self.staleEvidenceSeconds = staleEvidenceSeconds
        self.noPersonKeyframeCloseSeconds = noPersonKeyframeCloseSeconds
        self.glanceAbsentSeconds = glanceAbsentSeconds
        self.continuousPresenceKeyframeSeconds = continuousPresenceKeyframeSeconds
        self.keyframeBufferSeconds = keyframeBufferSeconds
        self.maxSessionSeconds = maxSessionSeconds
        self.idleAdmitIntervalSeconds = idleAdmitIntervalSeconds
        self.minCallGapSeconds = minCallGapSeconds
        self.postCueNoPersonGraceSeconds = postCueNoPersonGraceSeconds
    }

    public static let standard = TimingProfile(
        latchMinIntervalSeconds: SessionLimits.latchMinIntervalSeconds,
        latchMinKeyframes: SessionLimits.latchMinKeyframes,
        latchMinKeyframeSpacingSeconds: SessionLimits.latchMinKeyframeSpacingSeconds,
        heartbeatSeconds: SessionLimits.heartbeatSeconds,
        defaultHeadStartSeconds: SessionLimits.defaultHeadStartSeconds,
        headStartCapSeconds: SessionLimits.headStartCapSeconds,
        cueRateLimitSeconds: SessionLimits.cueRateLimitSeconds,
        relatchCooldownSeconds: SessionLimits.relatchCooldownSeconds,
        staleEvidenceSeconds: SessionLimits.staleEvidenceSeconds,
        noPersonKeyframeCloseSeconds: SessionLimits.noPersonKeyframeCloseSeconds,
        glanceAbsentSeconds: SessionLimits.glanceAbsentSeconds,
        continuousPresenceKeyframeSeconds: SessionLimits.continuousPresenceKeyframeSeconds,
        keyframeBufferSeconds: SessionLimits.keyframeBufferSeconds,
        maxSessionSeconds: SessionLimits.maxSessionSeconds
    )

    /// Adaptive quick profile: 10 s base head start (`m=0 -> 10s, m=0.5 -> 20s, cap 40s`),
    /// 2 s idle admit, 2 s min call gap, and 30 s post-cue grace before no-person close.
    public static let quick = TimingProfile(
        latchMinIntervalSeconds: 4,
        latchMinKeyframes: 2,
        latchMinKeyframeSpacingSeconds: 2,
        heartbeatSeconds: 8,
        defaultHeadStartSeconds: 10,
        headStartCapSeconds: 40,
        cueRateLimitSeconds: 30,
        relatchCooldownSeconds: 60,
        staleEvidenceSeconds: 15,
        noPersonKeyframeCloseSeconds: 20,
        glanceAbsentSeconds: 1,
        continuousPresenceKeyframeSeconds: 2,
        keyframeBufferSeconds: SessionLimits.keyframeBufferSeconds,
        maxSessionSeconds: SessionLimits.maxSessionSeconds,
        idleAdmitIntervalSeconds: 2,
        minCallGapSeconds: 2,
        postCueNoPersonGraceSeconds: 30
    )

    public var name: String {
        self == .quick ? "quick" : "standard"
    }
}
