import Foundation

/// The line that goes in his ear. Mom's longer wording stays on the need;
/// this derives a short action from it (and from her own words when the
/// compiled line is only a reason). Deterministic: no model call.
public enum SpokenCueForm {
    /// The smallest speakable line: a verb and an object, two to eight words.
    /// Every candidate below that floor is skipped, so the ear never hears
    /// a bare "Ask". Empty only when both inputs are blank or single words.
    public static let spokenWordFloor = 2

    /// Action first, two to eight words. First-person author text ("ask me
    /// for X") is rewritten to her before cutting, so "me" never truncates
    /// the line. Empty when both inputs are blank.
    public static func line(cueWording: String = "", authorText: String = "") -> String {
        let cue = rewritePerson(normalize(cueWording))
        let author = rewritePerson(normalize(authorText))
        let combined = [cue, author].filter { !$0.isEmpty }.joined(separator: " ")
        let candidates = [
            imperative(in: cue),
            imperative(in: author),
            stateLine(in: combined),
            askOffer(in: cue),
            askOffer(in: author),
            firstWords(cue),
            firstWords(author),
        ]
        for candidate in candidates {
            if let candidate, wordCount(candidate) >= spokenWordFloor {
                return candidate
            }
        }
        return ""
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
        if t.contains("heat pack") || t.contains("heating pad") || t.contains("warm compress") {
            return "Offer her the heat pack"
        }
        if hasWord(t, "blanket") || hasWord(t, "blankets") {
            return "Bring her a blanket"
        }
        if hasWord(t, "snack") || hasWord(t, "snacks") || hasWord(t, "food") || hasWord(t, "foods") {
            return "Bring her a snack"
        }
        if hasWord(t, "diaper") || hasWord(t, "diapers") {
            return "Change the diaper"
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
            return "Burp the baby"
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

    // MARK: - Ask pattern and fallbacks

    /// Mom says "ask me for X" and the model says "ask if she wants X".
    /// Both mean one action: offer her X (the noun phrase, at most 3 words).
    private static func askOffer(in text: String) -> String? {
        let words = tokens(text)
        let lower = words.map { $0.lowercased() }
        let markers: [[String]] = [
            ["ask", "her", "for"],
            ["ask", "me", "for"],
            ["ask", "if", "she", "wants"],
        ]
        for marker in markers {
            guard let end = endOfMarker(marker, in: lower) else {
                continue
            }
            var object = cutAtClauseBreak(Array(words[end...]))
            object = trimTail(object)
            object = Array(object.prefix(3))
            object = trimTail(object)
            if !object.isEmpty {
                return "Offer her \(object.joined(separator: " "))"
            }
        }
        return nil
    }

    /// Offset just past the marker's first run, or nil when absent.
    private static func endOfMarker(_ marker: [String], in words: [String]) -> Int? {
        guard marker.count <= words.count else {
            return nil
        }
        for start in 0...(words.count - marker.count) {
            if words[start..<(start + marker.count)].elementsEqual(marker) {
                return start + marker.count
            }
        }
        return nil
    }

    /// First ≤8 words with leading hedges gone: the whisper before the need
    /// name. Clause-cut like every other fallback so a reason cannot eat
    /// the budget.
    private static func firstWords(_ text: String) -> String? {
        var words = tokens(stripPoliteness(text))
        while let first = words.first?.lowercased(), leadingHedges.contains(first) {
            words.removeFirst()
        }
        words = cutAtClauseBreak(words)
        if words.count > CueSpeechTuning.spokenWordLimit {
            words = Array(words.prefix(CueSpeechTuning.spokenWordLimit))
        }
        words = trimTail(words)
        if words.isEmpty {
            return nil
        }
        return capitalize(words)
    }

    private static let leadingHedges: Set<String> = ["maybe", "might", "could"]

    private static func trimTail(_ words: [String]) -> [String] {
        var words = words
        while let last = words.last?.lowercased(), trailingHedges.contains(last) {
            words.removeLast()
        }
        while words.count > 1, let last = words.last?.lowercased(), dangling.contains(last) {
            words.removeLast()
        }
        return words
    }

    private static let trailingHedges: Set<String> = ["please", "now", "okay", "ok"]

    /// Her words are first-person ("ask me for X"); his ear is third-person.
    /// Runs before cutting so "me" is never a cut point.
    private static func rewritePerson(_ text: String) -> String {
        let replacements = ["me": "her", "my": "her", "i": "she"]
        return text.split(whereSeparator: \.isWhitespace).map { raw -> String in
            let token = String(raw)
            let letters = token.trimmingCharacters(in: .punctuationCharacters)
            guard let her = replacements[letters.lowercased()], !letters.isEmpty else {
                return token
            }
            return token.replacingOccurrences(of: letters, with: her)
        }.joined(separator: " ")
    }

    private static func wordCount(_ text: String) -> Int {
        tokens(text).count
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
        words = cutAtActionJoiner(words)
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

    /// Joining words that start a second action ("close the lid and move
    /// it"). The split keeps the first action; the second is still checked
    /// visually, it just isn't spoken.
    private static let actionJoiners: Set<String> = ["and", "then", "&", "plus"]

    /// Splits a compound action at its joining word, but only when the
    /// part before it is already a complete action: a verb plus an
    /// object, at least 2 words.
    private static func cutAtActionJoiner(_ words: [String]) -> [String] {
        guard let index = words.firstIndex(where: { actionJoiners.contains($0.lowercased()) }),
              index >= 2,
              let first = words.first?.lowercased(),
              actionVerbs.contains(first)
        else {
            return words
        }
        return Array(words.prefix(index))
    }

    /// Words a spoken line must not end on: prepositions, articles,
    /// conjunctions, and auxiliary verbs (plus the clause breaks, so a
    /// cut that still lands on one loses that word too). Words that pull
    /// double duty as particles or nouns stay speakable: no phrasal
    /// "up" / "out" / "off", no "can" (the trash can) or "refill".
    private static let dangling: Set<String> = [
        "a", "an", "the", "her", "his", "some", "that", "to", "of", "from", "for",
        "on", "in", "with", "and", "or", "at", "by",
        "if", "when", "while", "because", "so", "but", "he", "she", "it", "is",
        "that's", "thats", "who", "which", "since", "until", "before", "after",
        "into", "onto", "during", "beside", "between", "beyond", "toward",
        "towards", "upon", "within", "without", "about", "under", "than",
        "plus", "then", "nor", "yet", "&",
        "be", "am", "are", "was", "were", "been", "do", "does", "did",
        "have", "has", "had", "will", "would", "could", "should", "might",
        "must", "shall",
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
