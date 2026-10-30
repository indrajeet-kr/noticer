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
        maxSessionSeconds: TimeInterval
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

    /// First cue around half a minute: a latch inside a few seconds, then the 20 s head start.
    public static let quick = TimingProfile(
        latchMinIntervalSeconds: 4,
        latchMinKeyframes: 2,
        latchMinKeyframeSpacingSeconds: 2,
        heartbeatSeconds: 4,
        defaultHeadStartSeconds: 20,
        headStartCapSeconds: 40,
        cueRateLimitSeconds: 30,
        relatchCooldownSeconds: 60,
        staleEvidenceSeconds: 15,
        noPersonKeyframeCloseSeconds: 20,
        glanceAbsentSeconds: 1,
        continuousPresenceKeyframeSeconds: 2,
        keyframeBufferSeconds: SessionLimits.keyframeBufferSeconds,
        maxSessionSeconds: SessionLimits.maxSessionSeconds
    )

    public var name: String {
        self == .quick ? "quick" : "standard"
    }
}
