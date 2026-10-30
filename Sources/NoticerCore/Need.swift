import Foundation

/// One mom-authored need. Compiled watch-for fields stay empty until the
/// agent track's compile step fills them. This type does not compile or match.
public struct Need: Equatable, Sendable, Codable, Identifiable {
    /// Slug the engine and the model use. A brand-new row may still be a UUID
    /// until she leaves the card and the editor names it from her words.
    public var id: String
    /// Row identity for the editor only. Renaming `id` does not change this,
    /// so removing a card cannot leave the list pointing at a missing row.
    public var uiID: UUID
    /// Her words, before any model rewrite.
    public var authorText: String
    public var cueWording: String
    /// Visual condition from the compile step. Nil until that step exists.
    public var visualCondition: String?
    /// What counts as him noticing. Nil until the compile step exists.
    public var selfNoticeSignal: String?
    /// Dwell from the compile step. How this relates to the 90 s head start is undecided.
    public var dwellSeconds: TimeInterval?
    /// Mom's order. Lower comes first when only `SessionLimits.maxOpenNeeds` may be open.
    public var priority: Int
    /// Check-in wording is allowed only when a re-check is inconclusive and this is true.
    public var allowsCheckIn: Bool
    public var mastery: MasteryState

    public init(
        id: String,
        authorText: String,
        cueWording: String,
        visualCondition: String? = nil,
        selfNoticeSignal: String? = nil,
        dwellSeconds: TimeInterval? = nil,
        priority: Int,
        allowsCheckIn: Bool = false,
        mastery: MasteryState = .initial,
        uiID: UUID = UUID()
    ) {
        self.id = id
        self.uiID = uiID
        self.authorText = authorText
        self.cueWording = cueWording
        self.visualCondition = visualCondition
        self.selfNoticeSignal = selfNoticeSignal
        self.dwellSeconds = dwellSeconds
        self.priority = priority
        self.allowsCheckIn = allowsCheckIn
        self.mastery = mastery
    }

    /// Equality is the need the engine stores. `uiID` is only how the editor
    /// tells rows apart while a UUID slug is being renamed.
    public static func == (lhs: Need, rhs: Need) -> Bool {
        lhs.id == rhs.id
            && lhs.authorText == rhs.authorText
            && lhs.cueWording == rhs.cueWording
            && lhs.visualCondition == rhs.visualCondition
            && lhs.selfNoticeSignal == rhs.selfNoticeSignal
            && lhs.dwellSeconds == rhs.dwellSeconds
            && lhs.priority == rhs.priority
            && lhs.allowsCheckIn == rhs.allowsCheckIn
            && lhs.mastery == rhs.mastery
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case uiID = "ui_id"
        case authorText = "author_text"
        case cueWording = "cue_wording"
        case visualCondition = "visual_condition"
        case selfNoticeSignal = "self_notice_signal"
        case dwellSeconds = "dwell_seconds"
        case priority
        case allowsCheckIn = "allows_check_in"
        case mastery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        uiID = try container.decodeIfPresent(UUID.self, forKey: .uiID) ?? UUID()
        authorText = try container.decode(String.self, forKey: .authorText)
        cueWording = try container.decode(String.self, forKey: .cueWording)
        visualCondition = try container.decodeIfPresent(String.self, forKey: .visualCondition)
        selfNoticeSignal = try container.decodeIfPresent(String.self, forKey: .selfNoticeSignal)
        dwellSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .dwellSeconds)
        priority = try container.decode(Int.self, forKey: .priority)
        allowsCheckIn = try container.decodeIfPresent(Bool.self, forKey: .allowsCheckIn) ?? false
        mastery = try container.decodeIfPresent(MasteryState.self, forKey: .mastery) ?? .initial
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(uiID, forKey: .uiID)
        try container.encode(authorText, forKey: .authorText)
        try container.encode(cueWording, forKey: .cueWording)
        try container.encodeIfPresent(visualCondition, forKey: .visualCondition)
        try container.encodeIfPresent(selfNoticeSignal, forKey: .selfNoticeSignal)
        try container.encodeIfPresent(dwellSeconds, forKey: .dwellSeconds)
        try container.encode(priority, forKey: .priority)
        try container.encode(allowsCheckIn, forKey: .allowsCheckIn)
        try container.encode(mastery, forKey: .mastery)
    }
}
