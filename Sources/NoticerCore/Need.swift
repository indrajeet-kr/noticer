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
    /// Stable part ids for a compound need. Nil on old saved rows, which
    /// derive them from the AND/OR split when they load.
    public var parts: [NeedPart]?

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
        uiID: UUID = UUID(),
        parts: [NeedPart]? = nil
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
        self.parts = parts
    }

    /// Stored part ids, or derived from the AND/OR split for old rows.
    /// Non-compound needs have no parts.
    public var resolvedParts: [NeedPart] {
        parts ?? CompoundParts.derivedParts(for: self)
    }

    /// Equality is the need the engine stores. `uiID` is only how the editor
    /// tells rows apart while a UUID slug is being renamed. `parts` is
    /// excluded: it derives from the conditions, which are compared.
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
        case parts
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
        parts = try container.decodeIfPresent([NeedPart].self, forKey: .parts)
        if parts == nil, CompoundParts.isCompoundConditions(unknownCondition: unknownCondition) {
            parts = CompoundParts.derivedParts(
                handledCondition: handledCondition,
                visualCondition: visualCondition,
                unknownCondition: unknownCondition
            )
        }
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
        try container.encodeIfPresent(parts, forKey: .parts)
    }
}

/// One watchable part of a compound need: a stable short id plus the
/// part's handled and unmet condition texts, paired by position from
/// the AND/OR split.
public struct NeedPart: Equatable, Sendable, Codable {
    public var id: String
    public var handled: String
    public var unmet: String

    public init(id: String, handled: String, unmet: String) {
        self.id = id
        self.handled = handled
        self.unmet = unmet
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
        isCompoundConditions(unknownCondition: need.unknownCondition)
    }

    public static func isCompoundConditions(unknownCondition: String?) -> Bool {
        unknownCondition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Part ids for a need saved without them: the first significant word
    /// of each handled part, except the part the unknown condition talks
    /// about, which takes the unknown condition's first word. Short,
    /// snake_case, and stable for the saved conditions.
    public static func derivedParts(for need: Need) -> [NeedPart] {
        derivedParts(
            handledCondition: need.handledCondition,
            visualCondition: need.visualCondition,
            unknownCondition: need.unknownCondition
        )
    }

    public static func derivedParts(
        handledCondition: String?,
        visualCondition: String?,
        unknownCondition: String?
    ) -> [NeedPart] {
        let handled = handledParts(handledCondition ?? "")
        guard !handled.isEmpty else { return [] }
        let unmet = unmetParts(visualCondition ?? "")
        let unknownWords = contentWords(unknownCondition ?? "")
        let unknownID = firstSignificantWord(unknownCondition ?? "")
        var used: Set<String> = []
        var claimedUnknown = false
        return handled.enumerated().map { index, handledText in
            let unmetText = index < unmet.count ? unmet[index] : ""
            var id = firstSignificantWord(handledText) ?? "part\(index + 1)"
            if !claimedUnknown,
               let unknownID,
               !used.contains(unknownID),
               !contentWords(handledText).union(contentWords(unmetText)).isDisjoint(with: unknownWords) {
                id = unknownID
                claimedUnknown = true
            }
            if used.contains(id) {
                var counter = 2
                while used.contains("\(id)_\(counter)") { counter += 1 }
                id = "\(id)_\(counter)"
            }
            used.insert(id)
            return NeedPart(id: id, handled: handledText, unmet: unmetText)
        }
    }

    /// Every part handled. Part-id tokens (`<id>_handled`, `<id>_unmet`,
    /// `<id>_unknown`) decide when any is present: complete only when
    /// every part is `_handled` and none is `_unmet` or `_unknown`.
    /// Otherwise today's word matching applies. Any token that is neither
    /// a part-id token nor matched by the word fallback is reported via
    /// `onUnknownToken`. Non-compound needs always pass.
    public static func allHandled(
        need: Need,
        tokens: [String]?,
        onUnknownToken: (String) -> Void = { _ in }
    ) -> Bool {
        guard isCompound(need) else { return true }
        guard let tokens else { return false }
        let handled = handledParts(need.handledCondition ?? "").map(words)
        let unmet = unmetParts(need.visualCondition ?? "").map(words)
        func fallbackMatched(_ token: String) -> Bool {
            let tokenSet = words(token)
            guard !tokenSet.isEmpty else { return false }
            return handled.contains { tokenSet.isSubset(of: $0) }
                || unmet.contains { tokenSet.isSubset(of: $0) }
        }
        let ids = Set(need.resolvedParts.map(\.id))
        func partState(of token: String) -> (id: String, state: String)? {
            for id in ids where token.hasPrefix(id + "_") {
                let state = String(token.dropFirst(id.count + 1))
                if state == "handled" || state == "unmet" || state == "unknown" {
                    return (id, state)
                }
            }
            return nil
        }
        if tokens.contains(where: { partState(of: $0) != nil }) {
            var statesByID: [String: Set<String>] = [:]
            for token in tokens {
                if let (id, state) = partState(of: token) {
                    statesByID[id, default: []].insert(state)
                } else if !fallbackMatched(token) {
                    onUnknownToken(token)
                }
            }
            return ids.allSatisfy { statesByID[$0] == ["handled"] }
        }
        for token in tokens where !fallbackMatched(token) {
            onUnknownToken(token)
        }
        let tokenWords = tokens.map(words).filter { !$0.isEmpty }
        guard !tokenWords.isEmpty else { return false }
        if tokenWords.contains(where: { $0.contains("unknown") }) { return false }
        if tokenWords.contains(where: { token in unmet.contains { token.isSubset(of: $0) } }) { return false }
        return handled.allSatisfy { part in tokenWords.contains { $0.isSubset(of: part) } }
    }

    /// `lid:handled|unmet,placement:handled|unmet|unknown`: the reportable
    /// states per part. Parts the unknown condition touches may also be
    /// unknown.
    public static func partsSpec(parts: [NeedPart], unknownCondition: String) -> String {
        let unknownWords = contentWords(unknownCondition)
        return parts.map { part in
            var states = ["handled", "unmet"]
            let partWords = contentWords(part.handled).union(contentWords(part.unmet))
            if !partWords.isDisjoint(with: unknownWords) {
                states.append("unknown")
            }
            return "\(part.id):\(states.joined(separator: "|"))"
        }.joined(separator: ",")
    }

    /// Words carrying meaning: lowercased alphanumerics without fillers.
    public static func contentWords(_ text: String) -> Set<String> {
        words(text).subtracting(stopwords)
    }

    public static func firstSignificantWord(_ text: String) -> String? {
        let ordered = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return ordered.first { !stopwords.contains($0) } ?? ordered.first
    }

    private static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "cannot", "can", "could", "in", "on", "of", "to", "and", "or", "out",
        "when", "it", "its", "as", "for", "with", "by", "from", "that", "this",
        "not", "no", "any",
    ]

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
