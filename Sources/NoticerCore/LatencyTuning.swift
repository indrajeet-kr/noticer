import Foundation

/// Switches and bounds for the fast-cues path. Defaults keep every improvement
/// on while leaving `.standard` timing untouched; tests toggle individual
/// flags to verify each behavior in isolation.
public struct LatencyTuning: Equatable, Sendable {
    /// Publish each model reply immediately instead of looping into follow-up calls.
    public var oneReplyPerStep: Bool
    /// Share strip-identity and min-gap deduplication across latch, heartbeat, and recheck.
    public var dedupeAllPurposes: Bool
    /// Allow up to `maxInFlight` concurrent model calls when newer keyframes arrive.
    public var concurrentInFlight: Bool
    public var maxInFlight: Int
    /// Downsize upload JPEGs and send 2 keyframes on scouting/heartbeat strips.
    public var smallerPayloads: Bool
    public var uploadMaxEdge: Int
    public var jpegQuality: Double
    public var scoutingMaxKeyframes: Int
    public var confirmMaxKeyframes: Int
    /// Use `openAdmitInterval` in the session warmup window, quick 2 s idle admit, and `2 * interval` floor.
    public var admissionFloor: Bool
    public var sessionWarmupSeconds: TimeInterval
    public var alwaysAdmitMultiplier: Double
    /// Pre-warm speech and speak newly fired cues in the same step via a detached task.
    public var instantSpeech: Bool
    /// Zero head start, single-frame latch, and no stale-evidence recheck for urgent needs.
    public var urgentNeedsEnabled: Bool
    /// Use the 10 s adaptive quick head start (`m=0 -> 10s, m=0.5 -> 20s, cap 40s`).
    public var adaptiveQuickHeadStart: Bool
    /// Credit only matching `selfNoticeSignal` on intervention or `report_need_resolved`; hold out-of-view null turns.
    public var strictCredit: Bool
    /// Build `resolutionSignal` from `handledCondition` + `selfNoticeSignal` only (never `visualCondition`).
    public var polarityResolution: Bool
    /// Hold quick cued needs open for `postCueNoPersonGraceSeconds` before closing on no-person.
    public var postCueNoPersonGrace: Bool
    /// Emit `[TIMING]` metrics for calls, rate windows, and visible-to-speech latency.
    public var timingTelemetry: Bool
    /// Credit a recent matching wearer intervention when a need resolves as
    /// `resolved_by_partner` (or unknown) with no partner in view.
    public var creditRecentIntervention: Bool
    /// How long a matching intervention keeps a need creditable, in seconds.
    public var recentInterventionWindowSeconds: TimeInterval
    /// Let a scene change spend idle-bucket tokens for an early latch call.
    public var sceneChangeLatchBypass: Bool

    public init(
        oneReplyPerStep: Bool = true,
        dedupeAllPurposes: Bool = true,
        concurrentInFlight: Bool = true,
        maxInFlight: Int = 2,
        smallerPayloads: Bool = true,
        uploadMaxEdge: Int = 448,
        jpegQuality: Double = 0.55,
        scoutingMaxKeyframes: Int = 2,
        confirmMaxKeyframes: Int = 3,
        admissionFloor: Bool = true,
        sessionWarmupSeconds: TimeInterval = 6,
        alwaysAdmitMultiplier: Double = 2,
        instantSpeech: Bool = true,
        urgentNeedsEnabled: Bool = true,
        adaptiveQuickHeadStart: Bool = true,
        strictCredit: Bool = true,
        polarityResolution: Bool = true,
        postCueNoPersonGrace: Bool = true,
        timingTelemetry: Bool = true,
        creditRecentIntervention: Bool = true,
        recentInterventionWindowSeconds: TimeInterval = 30,
        sceneChangeLatchBypass: Bool = true
    ) {
        self.oneReplyPerStep = oneReplyPerStep
        self.dedupeAllPurposes = dedupeAllPurposes
        self.concurrentInFlight = concurrentInFlight
        self.maxInFlight = max(1, maxInFlight)
        self.smallerPayloads = smallerPayloads
        self.uploadMaxEdge = uploadMaxEdge
        self.jpegQuality = jpegQuality
        self.scoutingMaxKeyframes = max(1, scoutingMaxKeyframes)
        self.confirmMaxKeyframes = max(1, confirmMaxKeyframes)
        self.admissionFloor = admissionFloor
        self.sessionWarmupSeconds = sessionWarmupSeconds
        self.alwaysAdmitMultiplier = alwaysAdmitMultiplier
        self.instantSpeech = instantSpeech
        self.urgentNeedsEnabled = urgentNeedsEnabled
        self.adaptiveQuickHeadStart = adaptiveQuickHeadStart
        self.strictCredit = strictCredit
        self.polarityResolution = polarityResolution
        self.postCueNoPersonGrace = postCueNoPersonGrace
        self.timingTelemetry = timingTelemetry
        self.creditRecentIntervention = creditRecentIntervention
        self.recentInterventionWindowSeconds = recentInterventionWindowSeconds
        self.sceneChangeLatchBypass = sceneChangeLatchBypass
    }

    public static let `default` = LatencyTuning()

    public static let legacy = LatencyTuning(
        oneReplyPerStep: false,
        dedupeAllPurposes: false,
        concurrentInFlight: false,
        maxInFlight: 1,
        smallerPayloads: false,
        uploadMaxEdge: SignalGateTuning.uploadMaxEdge,
        jpegQuality: SignalGateTuning.jpegQuality,
        scoutingMaxKeyframes: 3,
        confirmMaxKeyframes: 3,
        admissionFloor: false,
        instantSpeech: false,
        urgentNeedsEnabled: false,
        adaptiveQuickHeadStart: false,
        strictCredit: false,
        polarityResolution: false,
        postCueNoPersonGrace: false,
        timingTelemetry: false,
        creditRecentIntervention: false,
        sceneChangeLatchBypass: false
    )
}
