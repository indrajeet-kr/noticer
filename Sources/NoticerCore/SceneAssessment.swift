import Foundation

/// JSON names shared by the five tool argument objects.
public enum AssessmentField {
    public static let needID = "need_id"
    public static let sustainedAcrossStrip = "sustained_across_strip"
    public static let partnerStateEvidence = "partner_state_evidence"
    public static let wearerHandsOccupied = "wearer_hands_occupied"
    public static let resolution = "resolution"
    public static let actionCode = "action_code"
    public static let confidence = "confidence"

    public static let all = [
        needID,
        sustainedAcrossStrip,
        partnerStateEvidence,
        wearerHandsOccupied,
        resolution,
        actionCode,
        confidence,
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
    public var resolution: Resolution?
    public var actionCode: String?
    public var confidence: Double?

    public init(
        needID: String? = nil,
        sustainedAcrossStrip: Bool? = nil,
        partnerStateEvidence: [String]? = nil,
        wearerHandsOccupied: Bool? = nil,
        resolution: Resolution? = nil,
        actionCode: String? = nil,
        confidence: Double? = nil
    ) {
        self.needID = needID
        self.sustainedAcrossStrip = sustainedAcrossStrip
        self.partnerStateEvidence = partnerStateEvidence
        self.wearerHandsOccupied = wearerHandsOccupied
        self.resolution = resolution
        self.actionCode = actionCode
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case needID = "need_id"
        case sustainedAcrossStrip = "sustained_across_strip"
        case partnerStateEvidence = "partner_state_evidence"
        case wearerHandsOccupied = "wearer_hands_occupied"
        case resolution
        case actionCode = "action_code"
        case confidence
    }
}
