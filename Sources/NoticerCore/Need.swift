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
    /// Visual condition from the compile step (the unmet problem state). Nil until that step exists.
    public var visualCondition: String?
    /// Observable state once the need has been handled. Nil until compiled or migrated.
    public var handledCondition: String?
    /// When a compound part cannot be judged (a corner out of view, no
    /// corner named). Nil for single-part needs; its presence marks a need
    /// compound, and resolution needs every part handled.
    public var unknownCondition: String?
    /// What counts as him noticing. Nil until the compile step exists.
    public var selfNoticeSignal: String?
    /// Dwell from the compile step. How this relates to the 90 s head start is undecided.
    public var dwellSeconds: TimeInterval?
    /// Mom's order. Lower comes first when only `SessionLimits.maxOpenNeeds` may be open.
    public var priority: Int
    /// Check-in wording is allowed only when a re-check is inconclusive and this is true.
    public var allowsCheckIn: Bool
    /// Safety needs cue immediately with zero head start and latch on one clear keyframe.
    public var isUrgent: Bool
    public var mastery: MasteryState

    public init(
        id: String,
        authorText: String,
        cueWording: String,
        visualCondition: String? = nil,
        handledCondition: String? = nil,
        unknownCondition: String? = nil,
        selfNoticeSignal: String? = nil,
        dwellSeconds: TimeInterval? = nil,
        priority: Int,
        allowsCheckIn: Bool = false,
        isUrgent: Bool = false,
        mastery: MasteryState = .initial,
        uiID: UUID = UUID()
    ) {
        self.id = id
        self.uiID = uiID
        self.authorText = authorText
        self.cueWording = cueWording
        self.visualCondition = visualCondition
        self.handledCondition = handledCondition
        self.unknownCondition = unknownCondition
        self.selfNoticeSignal = selfNoticeSignal
        self.dwellSeconds = dwellSeconds
        self.priority = priority
        self.allowsCheckIn = allowsCheckIn
        self.isUrgent = isUrgent
        self.mastery = mastery
    }

    /// Equality is the need the engine stores. `uiID` is only how the editor
    /// tells rows apart while a UUID slug is being renamed.
    public static func == (lhs: Need, rhs: Need) -> Bool {
        lhs.id == rhs.id
            && lhs.authorText == rhs.authorText
            && lhs.cueWording == rhs.cueWording
            && lhs.visualCondition == rhs.visualCondition
            && lhs.handledCondition == rhs.handledCondition
            && lhs.unknownCondition == rhs.unknownCondition
            && lhs.selfNoticeSignal == rhs.selfNoticeSignal
            && lhs.dwellSeconds == rhs.dwellSeconds
            && lhs.priority == rhs.priority
            && lhs.allowsCheckIn == rhs.allowsCheckIn
            && lhs.isUrgent == rhs.isUrgent
            && lhs.mastery == rhs.mastery
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case uiID = "ui_id"
        case authorText = "author_text"
        case cueWording = "cue_wording"
        case visualCondition = "visual_condition"
        case handledCondition = "handled_condition"
        case unknownCondition = "unknown_condition"
        case selfNoticeSignal = "self_notice_signal"
        case dwellSeconds = "dwell_seconds"
        case priority
        case allowsCheckIn = "allows_check_in"
        case isUrgent = "is_urgent"
        case mastery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        uiID = try container.decodeIfPresent(UUID.self, forKey: .uiID) ?? UUID()
        authorText = try container.decode(String.self, forKey: .authorText)
        cueWording = try container.decode(String.self, forKey: .cueWording)
        visualCondition = try container.decodeIfPresent(String.self, forKey: .visualCondition)
        handledCondition = try container.decodeIfPresent(String.self, forKey: .handledCondition)
        unknownCondition = try container.decodeIfPresent(String.self, forKey: .unknownCondition)
        selfNoticeSignal = try container.decodeIfPresent(String.self, forKey: .selfNoticeSignal)
        dwellSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .dwellSeconds)
        priority = try container.decode(Int.self, forKey: .priority)
        allowsCheckIn = try container.decodeIfPresent(Bool.self, forKey: .allowsCheckIn) ?? false
        isUrgent = try container.decodeIfPresent(Bool.self, forKey: .isUrgent) ?? false
        mastery = try container.decodeIfPresent(MasteryState.self, forKey: .mastery) ?? .initial
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(uiID, forKey: .uiID)
        try container.encode(authorText, forKey: .authorText)
        try container.encode(cueWording, forKey: .cueWording)
        try container.encodeIfPresent(visualCondition, forKey: .visualCondition)
        try container.encodeIfPresent(handledCondition, forKey: .handledCondition)
        try container.encodeIfPresent(unknownCondition, forKey: .unknownCondition)
        try container.encodeIfPresent(selfNoticeSignal, forKey: .selfNoticeSignal)
        try container.encodeIfPresent(dwellSeconds, forKey: .dwellSeconds)
        try container.encode(priority, forKey: .priority)
        try container.encode(allowsCheckIn, forKey: .allowsCheckIn)
        if isUrgent {
            try container.encode(isUrgent, forKey: .isUrgent)
        }
        try container.encode(mastery, forKey: .mastery)
    }
}

/// Compound chores: one need, several watchable parts. The compile step
/// writes the unmet condition as parts joined by OR and the handled
/// condition as parts joined by AND; the scene check reports each part's
/// state as a `partner_state_evidence` token. A part token matches a
/// condition part when every word in the token appears in the part, so
/// the distinguishing word (open vs closed, outside vs in) decides.
public enum CompoundParts {
    public static func isCompound(_ need: Need) -> Bool {
        need.unknownCondition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Every handled part matched, no part unknown, no part still unmet.
    /// Non-compound needs always pass; callers gate on `isCompound`.
    public static func allHandled(need: Need, tokens: [String]?) -> Bool {
        guard isCompound(need) else { return true }
        guard let tokens else { return false }
        let tokenWords = tokens.map(words).filter { !$0.isEmpty }
        guard !tokenWords.isEmpty else { return false }
        if tokenWords.contains(where: { $0.contains("unknown") }) { return false }
        let unmet = unmetParts(need.visualCondition ?? "").map(words)
        if tokenWords.contains(where: { token in unmet.contains { token.isSubset(of: $0) } }) { return false }
        let handled = handledParts(need.handledCondition ?? "").map(words)
        return handled.allSatisfy { part in tokenWords.contains { $0.isSubset(of: part) } }
    }

    /// A saved compound request with an old single-part condition gets an
    /// offer, not a silent rewrite. Nil for single needs, already-compound
    /// needs, and needs with nothing compiled yet (the normal turn
    /// compiles those).
    public static func recompileOffer(for need: Need) -> String? {
        guard !isCompound(need),
              !(need.visualCondition ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let halves = handledParts(need.authorText)
        guard halves.count >= 2 else { return nil }
        let first = halves[0]
        let rest = halves[1...].joined(separator: " and ")
        return "I can watch both parts of this: \(lowercasedFirst(first)) and \(lowercasedFirst(rest)). Update it?"
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let head = text.first else { return text }
        return head.lowercased() + text.dropFirst()
    }

    public static func unmetParts(_ text: String) -> [String] {
        split(text, pattern: "\\s*,?\\s+or\\s+")
    }

    public static func handledParts(_ text: String) -> [String] {
        split(text, pattern: "\\s+and\\s+")
    }

    public static func words(_ text: String) -> Set<String> {
        Set(
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        )
    }

    private static func split(_ text: String, pattern: String) -> [String] {
        var parts: [String] = []
        var rest = text[...]
        while let range = rest.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            parts.append(String(rest[..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }
        parts.append(String(rest))
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
