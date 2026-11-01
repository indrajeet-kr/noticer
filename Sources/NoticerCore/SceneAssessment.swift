import Foundation

/// JSON names shared by the five tool argument objects.
public enum AssessmentField {
    public static let needID = "need_id"
    public static let sustainedAcrossStrip = "sustained_across_strip"
    public static let partnerStateEvidence = "partner_state_evidence"
    public static let wearerHandsOccupied = "wearer_hands_occupied"
    public static let partnerInView = "partner_in_view"
    public static let wearerHandsVisible = "wearer_hands_visible"
    public static let resolution = "resolution"
    public static let actionCode = "action_code"
    public static let confidence = "confidence"
    public static let partnerAsleep = "partner_asleep"
    public static let evidenceKeyframeIDs = "evidence_keyframe_ids"
    public static let newestAnchorState = "newest_anchor_state"

    public static let all = [
        needID,
        sustainedAcrossStrip,
        partnerStateEvidence,
        wearerHandsOccupied,
        partnerInView,
        wearerHandsVisible,
        resolution,
        actionCode,
        confidence,
        partnerAsleep,
        evidenceKeyframeIDs,
        newestAnchorState,
    ]
}

/// Known `resolution` strings from the PRD, plus any other string the model sends.
/// Decoding does not drop unknown values. The core validator does that later.
public struct Resolution: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let caughtHimself = Resolution(rawValue: "caught_himself")
    public static let resolvedByPartner = Resolution(rawValue: "resolved_by_partner")
    public static let unknown = Resolution(rawValue: "unknown")

    public static let recognized: [Resolution] = [
        .caughtHimself,
        .resolvedByPartner,
        .unknown,
    ]
}

/// The named need's anchor state in the newest keyframe only. Any other
/// string the model sends decodes but never matches a known state.
public struct AnchorState: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let unmet = AnchorState(rawValue: "unmet")
    public static let handled = AnchorState(rawValue: "handled")
    public static let notVisible = AnchorState(rawValue: "not_visible")
    public static let unclear = AnchorState(rawValue: "unclear")

    public static let recognized: [AnchorState] = [
        .unmet,
        .handled,
        .notVisible,
        .unclear,
    ]
}

/// The urgent single-frame rule, shared by the engine and the hard-cap
/// gate so the two can never disagree: the newest strip frame cited as
/// evidence, fresh at verdict time, anchor unmet, confidence on top.
public enum UrgentEvidence {
    public static func freshFrame(
        assessment: SceneAssessment,
        callKeyframes: [Keyframe],
        now: Date
    ) -> (frame: Keyframe, confidence: Double)? {
        guard assessment.newestAnchorState == .unmet else { return nil }
        guard let confidence = assessment.confidence,
              confidence >= EngineTuning.urgentSingleFrameMinConfidence else { return nil }
        guard let newest = callKeyframes.max(by: { $0.capturedAt < $1.capturedAt }) else { return nil }
        // Recomputed from capture time: the strip's stored ages are stale
        // by the time the verdict lands.
        let age = max(0, now.timeIntervalSince(newest.capturedAt))
        guard age <= EngineTuning.urgentFreshFrameMaxAgeSeconds else { return nil }
        guard let cited = assessment.evidenceKeyframeIDs, cited.contains(newest.id) else { return nil }
        return (newest, confidence)
    }
}

/// Action-code strings the PRD actually names. This is not a closed catalog.
public enum ActionCodeExamples {
    public static let wearerHandsReceivingBaby = "wearer_hands_receiving_baby"
    public static let wearerCarryingWaterTowardPartner = "wearer_carrying_water_toward_partner"
    /// Passive scene state. A self-notice must not be credited from this alone.
    public static let waterGlassPresent = "water_glass_present"
}

/// Assessment fields carried inside a tool call. Every field is optional because
/// each tool fills a different subset. Confidence is stored and never treated as a gate here.
public struct SceneAssessment: Equatable, Sendable, Codable {
    public var needID: String?
    public var sustainedAcrossStrip: Bool?
    public var partnerStateEvidence: [String]?
    public var wearerHandsOccupied: Bool?
    /// Partner visible in the strip. The phone used to read this from an on-device
    /// person detector. Muse Spark sets it now. Nil means the model did not say.
    public var partnerInView: Bool?
    /// Wearer's own hands in frame. Busy versus free is `wearerHandsOccupied`.
    public var wearerHandsVisible: Bool?
    public var resolution: Resolution?
    public var actionCode: String?
    public var confidence: Double?
    /// She is visibly asleep or her eyes are closed. Check-in needs stay
    /// quiet; chores still cue. Nil means the model did not say.
    public var partnerAsleep: Bool?
    /// Keyframe ids that clearly show the named need's anchor AND its
    /// unmet condition. Empty or omitted when no frame shows both.
    public var evidenceKeyframeIDs: [String]?
    /// The named need's anchor state in the newest keyframe only.
    public var newestAnchorState: AnchorState?

    public init(
        needID: String? = nil,
        sustainedAcrossStrip: Bool? = nil,
        partnerStateEvidence: [String]? = nil,
        wearerHandsOccupied: Bool? = nil,
        partnerInView: Bool? = nil,
        wearerHandsVisible: Bool? = nil,
        resolution: Resolution? = nil,
        actionCode: String? = nil,
        confidence: Double? = nil,
        partnerAsleep: Bool? = nil,
        evidenceKeyframeIDs: [String]? = nil,
        newestAnchorState: AnchorState? = nil
    ) {
        self.needID = needID
        self.sustainedAcrossStrip = sustainedAcrossStrip
        self.partnerStateEvidence = partnerStateEvidence
        self.wearerHandsOccupied = wearerHandsOccupied
        self.partnerInView = partnerInView
        self.wearerHandsVisible = wearerHandsVisible
        self.resolution = resolution
        self.actionCode = actionCode
        self.confidence = confidence
        self.partnerAsleep = partnerAsleep
        self.evidenceKeyframeIDs = evidenceKeyframeIDs
        self.newestAnchorState = newestAnchorState
    }

    private enum CodingKeys: String, CodingKey {
        case needID = "need_id"
        case sustainedAcrossStrip = "sustained_across_strip"
        case partnerStateEvidence = "partner_state_evidence"
        case wearerHandsOccupied = "wearer_hands_occupied"
        case partnerInView = "partner_in_view"
        case wearerHandsVisible = "wearer_hands_visible"
        case resolution
        case actionCode = "action_code"
        case confidence
        case partnerAsleep = "partner_asleep"
        case evidenceKeyframeIDs = "evidence_keyframe_ids"
        case newestAnchorState = "newest_anchor_state"
    }
}
