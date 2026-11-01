import Foundation

/// The line that goes in his ear. Mom's longer wording stays on the need;
/// this derives a short action from it (and from her own words when the
/// compiled line is only a reason). Deterministic: no model call.
public enum SpokenCueForm {
    /// Action first, about three to five words. Empty when both inputs are blank.
    public static func line(cueWording: String, authorText: String = "") -> String {
        let cue = normalize(cueWording)
        let author = normalize(authorText)
        if let spoken = imperative(in: cue) ?? imperative(in: author) {
            return spoken
        }
        let combined = [cue, author].filter { !$0.isEmpty }.joined(separator: " ")
        if let state = stateLine(in: combined) {
            return state
        }
        let fallback = cue.isEmpty ? author : cue
        return limit(fallback)
    }

    public static func repeatLine(_ spoken: String) -> String {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return CueSpeechTuning.repeatPrefix
        }
        if isRepeat(trimmed) {
            return trimmed
        }
        return "\(CueSpeechTuning.repeatPrefix) \(trimmed)"
    }

    public static func isRepeat(_ spoken: String) -> Bool {
        spoken.hasPrefix(CueSpeechTuning.repeatPrefix)
    }

    // MARK: - Imperative

    /// Last imperative clause wins. A reason usually comes first
    /// ("Her plate's getting cold, maybe take the baby").
    private static func imperative(in text: String) -> String? {
        let clauses = text.split { character in
            character == "," || character == "." || character == ";" || character == "?" || character == "!" || character == "—"
        }
        var found: String?
        for clause in clauses {
            let stripped = stripPoliteness(String(clause))
            let words = tokens(stripped)
            guard let first = words.first?.lowercased(), actionVerbs.contains(first) else {
                continue
            }
            let spoken = limit(words.joined(separator: " "))
            if !spoken.isEmpty {
                found = spoken
            }
        }
        return found
    }

    private static let actionVerbs: Set<String> = [
        "take", "refill", "grab", "bring", "hand", "pass", "set", "put", "move", "clear",
        "pick", "check", "get", "give", "fill", "hold", "cover", "wipe", "change", "feed",
        "burp", "soothe", "rock", "help", "adjust", "turn", "open", "close", "wash", "dry",
        "fetch", "carry", "remove", "tidy", "clean", "pour", "warm", "cool", "switch",
        "lower", "raise", "find", "replace", "restock", "dim", "offer", "fold", "start",
        "stop", "lift", "lay", "tuck",
    ]

    private static func stripPoliteness(_ clause: String) -> String {
        var text = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "maybe ", "please ", "could you ", "can you ", "would you ", "will you ",
            "hey ", "just ", "quickly ", "kindly ", "offer to ",
        ]
        var changed = true
        while changed {
            changed = false
            let lower = text.lowercased()
            for prefix in prefixes where lower.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return text
    }

    // MARK: - State to action

    /// When neither line starts with a verb, a small map turns the situation
    /// into the action. The ear should not hear "her water's empty".
    private static func stateLine(in text: String) -> String? {
        let t = text.lowercased()
        guard !t.isEmpty else { return nil }
        let water = t.contains("water") || t.contains("bottle")
        let waterNeeded = t.contains("empty") || t.contains("low") || t.contains("no water")
            || t.contains("nursing") || t.contains("out of")
        if water && waterNeeded {
            return "Refill her water"
        }
        if water && (t.contains("table") || t.contains("dining")) {
            return "Set water on the table"
        }
        if water {
            return "Refill her water"
        }
        // A roaming kid is a toddler, not the baby. "roamer" must not match "roam".
        if hasWord(t, "roam") || hasWord(t, "roaming") || hasWord(t, "kid") || hasWord(t, "kids")
            || hasWord(t, "toddler") || hasWord(t, "toddlers") {
            return "Pick up the kid"
        }
        if hasWord(t, "baby") || hasWord(t, "infant") || hasWord(t, "newborn") {
            return "Take the baby"
        }
        if hasWord(t, "mat") || hasWord(t, "mats") {
            return "Fold the mat"
        }
        if t.contains("burp") {
            return "Hand her a burp cloth"
        }
        if t.contains("toy") && t.contains("floor") {
            return "Pick up the toys"
        }
        if t.contains("toy") {
            return "Pick up the toys"
        }
        if t.contains("glasses") {
            return "Clear the glasses"
        }
        if t.contains("glass") {
            return "Clear the glass"
        }
        if t.contains("sink") || t.contains("dish") {
            return "Clear the sink"
        }
        if t.contains("thermostat") || t.contains("hallway") || t.contains("lamp") {
            return "Check the hallway"
        }
        if t.contains("use a hand") || t.contains("could use") {
            return "Lend a hand"
        }
        return nil
    }

    // MARK: - Words

    private static func limit(_ text: String) -> String {
        var words = tokens(stripPoliteness(text))
        // Drop the reason clause before counting, so "if on the floor" cannot
        // eat the word budget and leave "Fold the mat if".
        words = cutAtClauseBreak(words)
        if words.count >= 2, words.suffix(2).map({ $0.lowercased() }) == ["a", "bit"] {
            words.removeLast(2)
        }
        let pairHedges: Set<[String]> = [["right", "now"], ["for", "her"], ["for", "me"], ["for", "him"]]
        if words.count >= 2, pairHedges.contains(words.suffix(2).map { $0.lowercased() }) {
            words.removeLast(2)
        }
        let hedges: Set<String> = ["please", "now", "okay", "ok"]
        while let last = words.last?.lowercased(), hedges.contains(last) {
            words.removeLast()
        }
        if words.count > CueSpeechTuning.spokenWordLimit {
            words = Array(words.prefix(CueSpeechTuning.spokenWordLimit))
        }
        while words.count > 1, let last = words.last?.lowercased(), dangling.contains(last) {
            words.removeLast()
        }
        return capitalize(words)
    }

    /// Subordinators and conjunctions. The action is the words before the first one.
    private static let clauseBreaks: Set<String> = [
        "if", "when", "while", "because", "so", "but", "he", "she", "it", "is",
        "that's", "thats", "who", "which", "since", "until", "before", "after",
    ]

    private static func cutAtClauseBreak(_ words: [String]) -> [String] {
        guard let index = words.firstIndex(where: { clauseBreaks.contains($0.lowercased()) }), index > 0 else {
            return words
        }
        return Array(words.prefix(index))
    }

    /// Words a spoken line must not end on. Includes the clause breaks, so a
    /// cut that still lands on one loses that word too.
    private static let dangling: Set<String> = [
        "a", "an", "the", "her", "his", "some", "that", "to", "of", "from", "for",
        "on", "in", "with", "and", "or", "at", "by",
        "if", "when", "while", "because", "so", "but", "he", "she", "it", "is",
        "that's", "thats", "who", "which", "since", "until", "before", "after",
    ]

    /// Whole word, so "roam" does not match "roamer" and "water" still matches "water's".
    private static func hasWord(_ text: String, _ word: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: word, range: start..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex
                || !text[text.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == text.endIndex
                || !text[range.upperBound].isLetter
            if beforeOK && afterOK {
                return true
            }
            start = range.upperBound
        }
        return false
    }

    private static func tokens(_ text: String) -> [String] {
        text.split { character in
            character.isWhitespace || character == "?" || character == "!" || character == "\""
                || character == "“" || character == "”" || character == ":"
        }
        .map(String.init)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;")) }
        .filter { !$0.isEmpty }
    }

    private static func capitalize(_ words: [String]) -> String {
        guard var first = words.first else { return "" }
        if let character = first.first {
            first = String(character).uppercased() + first.dropFirst()
        }
        return ([first] + words.dropFirst()).joined(separator: " ")
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// "Refill her water · 12s ago" on the session screen. Wall-clock seconds,
/// floored, so a one-second tick does not round up early.
public enum CueRecency {
    public static func phrase(secondsAgo: TimeInterval) -> String {
        let seconds = max(0, Int(secondsAgo.rounded(.down)))
        if seconds < 1 {
            return "just now"
        }
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        return "\(minutes / 60)h ago"
    }

    public static func line(spoken: String, secondsAgo: TimeInterval) -> String {
        "\(spoken) · \(phrase(secondsAgo: secondsAgo))"
    }

    public static func line(spoken: String, at: Date, now: Date) -> String {
        line(spoken: spoken, secondsAgo: now.timeIntervalSince(at))
    }
}
