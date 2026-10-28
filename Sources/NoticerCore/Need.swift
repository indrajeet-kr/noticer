import Foundation

/// One mom-authored need. Compiled watch-for fields stay empty until the
/// agent track's compile step fills them. This type does not compile or match.
public struct Need: Equatable, Sendable, Codable, Identifiable {
    public var id: String
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
        mastery: MasteryState = .initial
    ) {
        self.id = id
        self.authorText = authorText
        self.cueWording = cueWording
        self.visualCondition = visualCondition
        self.selfNoticeSignal = selfNoticeSignal
        self.dwellSeconds = dwellSeconds
        self.priority = priority
        self.allowsCheckIn = allowsCheckIn
        self.mastery = mastery
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case authorText = "author_text"
        case cueWording = "cue_wording"
        case visualCondition = "visual_condition"
        case selfNoticeSignal = "self_notice_signal"
        case dwellSeconds = "dwell_seconds"
        case priority
        case allowsCheckIn = "allows_check_in"
        case mastery
    }
}
