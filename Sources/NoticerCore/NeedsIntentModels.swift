import Foundation

// MARK: - Mom's-list intent models (pure logic, shared with Linux tests)

/// The model's priority word. The engine stores mom's order as an `Int`
/// where lower comes first, so the mapping is fixed: important 0,
/// normal 1, gentle 2. Ties keep the model's list order and the engine
/// breaks them by latch time.
public enum NeedsIntentPriority: String, Sendable, Equatable, Codable {
    case gentle
    case normal
    case important

    public var needPriority: Int {
        switch self {
        case .important: return 0
        case .normal: return 1
        case .gentle: return 2
        }
    }

    public static func word(forNeedPriority value: Int) -> NeedsIntentPriority {
        switch value {
        case ...0: return .important
        case 1: return .normal
        default: return .gentle
        }
    }

    /// Unknown words from the model read as normal rather than failing the turn.
    public static func lenient(_ raw: String) -> NeedsIntentPriority {
        NeedsIntentPriority(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? .normal
    }
}

/// One validated need from a `set_needs` call. Ids are normalized slugs.
public struct NeedsIntentDraft: Sendable, Equatable {
    public var id: String
    public var authorText: String
    public var whisper: String
    public var priority: NeedsIntentPriority
    public var allowsCheckIn: Bool
    /// Stores `problem_visual` (kept under the `visualCue` property name for source compatibility).
    public var visualCue: String
    public var handledVisual: String
    /// Stores `unknown_visual`: when a compound part cannot be judged.
    /// Empty for single-part needs.
    public var unknownVisual: String
    public var wearerSignal: String
    public var isUrgent: Bool

    public var problemVisual: String {
        get { visualCue }
        set { visualCue = newValue }
    }

    public init(
        id: String,
        authorText: String,
        whisper: String,
        priority: NeedsIntentPriority,
        allowsCheckIn: Bool,
        visualCue: String,
        handledVisual: String = "",
        unknownVisual: String = "",
        wearerSignal: String = "",
        isUrgent: Bool = false
    ) {
        self.id = id
        self.authorText = authorText
        self.whisper = whisper
        self.priority = priority
        self.allowsCheckIn = allowsCheckIn
        self.visualCue = visualCue
        self.handledVisual = handledVisual
        self.unknownVisual = unknownVisual
        self.wearerSignal = wearerSignal
        self.isUrgent = isUrgent
    }
}

/// Normalizes model ids to `^[a-z0-9]+(-[a-z0-9]+)*$`. Known phrasings of
/// the MVP pair map to their canonical ids so edits keep matching.
public enum NeedsIntentSlug {
    public static let takeBaby = "take-baby"
    public static let refillWater = "refill-water"

    private static let aliases: [String: String] = [
        "take-the-baby": takeBaby,
        "take-baby-from-her": takeBaby,
        "hold-the-baby": takeBaby,
        "take-her": takeBaby,
        "take-her-so-she-can-eat": takeBaby,
        "refill-my-water": refillWater,
        "refill-her-water": refillWater,
        "refill-the-water": refillWater,
        "water-bottle-full": refillWater,
        "keep-water-full": refillWater,
        "keep-my-water-full": refillWater,
        "fill-her-water": refillWater,
        "fill-water-bottle": refillWater,
        "water-refill": refillWater,
        "get-her-water": refillWater,
    ]

    public static func normalize(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var slug = lowered
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        if slug.isEmpty {
            return "need"
        }
        return aliases[slug] ?? slug
    }

    public static func isValid(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= 64 else { return false }
        return slug.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    /// Snaps a slug to an existing id when it differs by a single typo
    /// (one insert, delete, substitute, or transpose, e.g. "takeq-baby").
    /// Exact matches pass through, and ambiguity never guesses: two
    /// candidates within range keep the slug as-is.
    public static func repair(_ slug: String, against existing: [String]) -> String {
        if existing.contains(slug) {
            return slug
        }
        let candidates = existing.filter { editDistance($0, slug) <= 1 }
        return candidates.count == 1 ? candidates[0] : slug
    }

    /// Optimal string alignment distance. Strings here are short slugs.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a == b {
            return 0
        }
        if a.isEmpty {
            return b.count
        }
        if b.isEmpty {
            return a.count
        }
        if abs(a.count - b.count) > 1 {
            return 2
        }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count {
            d[i][0] = i
        }
        for j in 0...b.count {
            d[0][j] = j
        }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + cost)
                }
            }
        }
        return d[a.count][b.count]
    }
}

public enum NeedsIntentConversion {
    /// Drafts become engine needs. Ids that already exist keep their row
    /// identity, mastery, self-notice signal, and dwell override. A draft id
    /// that differs from a saved id by a single typo snaps to it, so a
    /// "takeq-baby" turn edits take-baby instead of adding a stranger.
    public static func toNeeds(_ drafts: [NeedsIntentDraft], current: [Need]) -> [Need] {
        let existing = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let currentIDs = current.map(\.id)
        var taken = Set<String>()
        return drafts.map { draft in
            var id = NeedsIntentSlug.repair(draft.id, against: currentIDs)
            if taken.contains(id) {
                // Two drafts resolving to one id: keep the model's slug so
                // no need is lost to a merge.
                id = draft.id
            }
            taken.insert(id)
            let old = existing[id]
            let handled = draft.handledVisual.trimmingCharacters(in: .whitespacesAndNewlines)
            let unknown = draft.unknownVisual.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSignal = draft.wearerSignal.trimmingCharacters(in: .whitespacesAndNewlines)
            let signal: String
            if trimmedSignal.range(of: #"^wearer_[a-z0-9_]+$"#, options: .regularExpression) != nil {
                signal = trimmedSignal
            } else {
                signal = ""
            }
            return Need(
                id: id,
                authorText: draft.authorText,
                cueWording: draft.whisper,
                visualCondition: draft.visualCue.isEmpty ? old?.visualCondition : draft.visualCue,
                handledCondition: handled.isEmpty ? old?.handledCondition : handled,
                unknownCondition: unknown.isEmpty ? old?.unknownCondition : unknown,
                selfNoticeSignal: signal.isEmpty ? old?.selfNoticeSignal : signal,
                dwellSeconds: old?.dwellSeconds,
                priority: draft.priority.needPriority,
                allowsCheckIn: draft.allowsCheckIn,
                isUrgent: draft.isUrgent || (old?.isUrgent ?? false),
                mastery: old?.mastery ?? .initial,
                uiID: old?.uiID ?? UUID()
            )
        }
    }

    /// Saved needs back into drafts, so the open screen can seed one
    /// "Your list tonight" card from the stored or default list. Inverse of
    /// `toNeeds` for the authored fields; mastery and row identity stay with
    /// the saved need and are re-attached on accept.
    public static func fromNeeds(_ needs: [Need]) -> [NeedsIntentDraft] {
        needs.map {
            NeedsIntentDraft(
                id: $0.id,
                authorText: $0.authorText,
                whisper: $0.cueWording,
                priority: NeedsIntentPriority.word(forNeedPriority: $0.priority),
                allowsCheckIn: $0.allowsCheckIn,
                visualCue: $0.visualCondition ?? "",
                handledVisual: $0.handledCondition ?? "",
                unknownVisual: $0.unknownCondition ?? "",
                wearerSignal: $0.selfNoticeSignal ?? "",
                isUrgent: $0.isUrgent
            )
        }
    }

    /// Compact CURRENT_LIST payload: only what the model needs to apply an edit.
    public static func currentListJSON(_ needs: [Need]) -> String {
        struct Entry: Encodable {
            var id: String
            var authorText: String
            var whisper: String
            var priority: String
            var allowsCheckIn: Bool
            var problemVisual: String
            var handledVisual: String
            var unknownVisual: String
            var wearerSignal: String
            var urgent: Bool

            private enum CodingKeys: String, CodingKey {
                case id
                case authorText
                case whisper
                case priority
                case allowsCheckIn
                case problemVisual = "problem_visual"
                case handledVisual = "handled_visual"
                case unknownVisual = "unknown_visual"
                case wearerSignal = "wearer_signal"
                case urgent
            }
        }
        let entries = needs.map { need in
            Entry(
                id: need.id,
                authorText: need.authorText,
                whisper: need.cueWording,
                priority: NeedsIntentPriority.word(forNeedPriority: need.priority).rawValue,
                allowsCheckIn: need.allowsCheckIn,
                problemVisual: need.visualCondition ?? "",
                handledVisual: need.handledCondition ?? "",
                unknownVisual: need.unknownCondition ?? "",
                wearerSignal: need.selfNoticeSignal ?? "",
                urgent: need.isUrgent
            )
        }
        guard let data = try? JSONEncoder().encode(entries),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
