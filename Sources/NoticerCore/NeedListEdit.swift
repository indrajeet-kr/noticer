import Foundation

// MARK: - App-owned need-list editing (pure logic, Linux-tested)

/// The app applies list edits; the model only proposes. A model answer is
/// never a replacement list: drafts upsert by id, and a saved need
/// disappears only when she explicitly chose it (swap chip, remove action)
/// or named it in her message. Anything else the model drops is kept.
public enum NeedListEdit {
    // MARK: - Limit and routing

    public static func isFull(_ needs: [Need]) -> Bool {
        needs.count >= SessionLimits.maxAuthoredNeeds
    }

    /// True when the message reads as an edit of the existing list
    /// (remove, reword, reprioritize, pause) rather than a fresh add.
    /// Edit messages go to the model even when the list is full, so she
    /// can always free a slot; the merge guard still protects the rest.
    public static func isEditMessage(_ message: String) -> Bool {
        !Set(wordTokens(message)).isDisjoint(with: editVerbs)
    }

    private static let editVerbs: Set<String> = [
        "remove", "removing", "removed", "delete", "deleting", "drop", "dropping",
        "change", "changing", "edit", "editing", "reword", "rewording", "rename",
        "renaming", "rephrase", "fix", "update", "updating", "reprioritize",
        "priority", "priorities", "higher", "lower", "pause", "pausing",
        "paused", "resume", "resuming", "unpause", "move", "moving", "reorder",
    ]

    // MARK: - Swap question (built by the app, never the model)

    /// "You already have 6 needs — which one should I swap out for "<new>"?"
    public static func swapQuestion(newText: String, limit: Int = SessionLimits.maxAuthoredNeeds) -> String {
        let name = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = name.isEmpty ? "the new need" : name
        return "You already have \(limit) needs — which one should I swap out for \"\(quoted)\"?"
    }

    /// Follow-up when her typed swap answer names nothing: same chips again.
    public static func swapReaskQuestion(newText: String) -> String {
        let name = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = name.isEmpty ? "the new need" : name
        return "Which one did you mean — tap one to swap it for \"\(quoted)\"?"
    }

    public static func keepAllChip(limit: Int = SessionLimits.maxAuthoredNeeds) -> String {
        "Keep all \(limit)"
    }

    public static func keepAllConfirmation(limit: Int = SessionLimits.maxAuthoredNeeds) -> String {
        "Kept all \(limit) — nothing changed."
    }

    public struct SwapCandidate: Sendable, Equatable {
        public var id: String
        public var shortName: String

        public init(id: String, shortName: String) {
            self.id = id
            self.shortName = shortName
        }
    }

    public static func swapCandidates(for needs: [Need]) -> [SwapCandidate] {
        needs.map { SwapCandidate(id: $0.id, shortName: shortName(for: $0)) }
    }

    /// Short chip name from the stable id slug ("remove-empty-glasses" →
    /// "remove empty glasses"), capped at 4 words. Slugs are lowercase
    /// alphanumerics, so chips never carry surprise words. UUID-style ids
    /// fall back to her own trimmed words.
    public static func shortName(for need: Need) -> String {
        if UUID(uuidString: need.id) == nil {
            let words = need.id.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let kept = Array(words.prefix(4)).joined(separator: " ")
            if !kept.isEmpty {
                return kept
            }
        }
        let fallback = wordTokens(need.authorText).prefix(4).joined(separator: " ")
        return fallback.isEmpty ? need.id : fallback
    }

    // MARK: - Naming (which need her words mean)

    /// Lowercased alphanumeric tokens.
    public static func wordTokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Articles, prepositions, pronouns, and edit verbs: words that never
    /// identify a need on their own. Verbs are excluded so "remove the
    /// water one" names water, not a need that happens to say "remove".
    private static let noiseWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "for", "with", "from", "of", "to",
        "in", "on", "at", "by", "as", "is", "are", "be", "so", "if", "out", "up",
        "it", "its", "her", "his", "him", "she", "he", "they", "them", "their",
        "my", "me", "we", "our", "you", "your", "that", "this", "these", "those",
        "one", "ones", "all", "any", "no", "not", "do", "does", "did", "please",
        "just", "tonight", "list", "need", "needs", "than", "then", "there",
        "here", "what", "which", "when", "how", "more", "most", "other",
        "another", "every", "each", "some", "new", "old", "back", "off", "into",
        "onto", "over", "again", "still", "also", "never", "mind", "leave",
        "forget", "dont", "don", "t", "re", "ll", "ve", "s", "d", "m",
        "take", "get", "bring", "put", "keep", "fold", "clean", "pick", "grab",
        "hold", "give", "help", "let", "want", "getting", "bringing", "putting",
        "folding", "cleaning", "picking", "holding", "giving", "helping",
    ]

    public static func significantWords(_ text: String) -> [String] {
        wordTokens(text).filter { !noiseWords.contains($0) && !editVerbs.contains($0) }
    }

    /// Words a message can match against: id slug words plus author words.
    public static func needWords(_ need: Need) -> Set<String> {
        Set(wordTokens(need.id.replacingOccurrences(of: "-", with: " ")) + wordTokens(need.authorText))
    }

    /// True when the message shares at least one significant word with the need.
    public static func namesNeed(message: String, need: Need) -> Bool {
        let messageWords = Set(significantWords(message))
        guard !messageWords.isEmpty else { return false }
        return !messageWords.isDisjoint(with: needWords(need))
    }

    /// The single need the message names, or nil when none or several match.
    public static func resolveNamedNeed(message: String, in needs: [Need]) -> Need? {
        let matches = needs.filter { namesNeed(message: message, need: $0) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// True when her swap answer backs out ("keep all", "never mind", ...).
    /// Checked before name resolution, so "skip the mat for now" discards
    /// instead of matching a need that mentions mats.
    public static func isKeepAllAnswer(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return keepAllPhrases.contains { lowered.contains($0) }
    }

    private static let keepAllPhrases = [
        "keep all", "keep them", "keep it", "never mind", "nevermind", "cancel",
        "skip", "leave it", "forget it", "don't add", "dont add", "do not add",
        "nothing", "nevermind",
    ]

    // MARK: - Merge guard

    /// True when her words clearly edit the list: "remove/delete/drop X
    /// from my list", "I don't need X anymore", "stop reminding me about
    /// X". An imperative chore ("Remove the table from the hall") never
    /// matches, so it adds a need instead of deleting one.
    public static func hasExplicitEditIntent(message: String) -> Bool {
        let lowered = message.lowercased()
        let listPhrases = [
            "from my list", "from the list", "from her list",
            "off my list", "off the list", "off her list",
        ]
        if listPhrases.contains(where: lowered.contains) {
            let verbs: Set<String> = ["remove", "delete", "drop", "cut", "take", "clear"]
            if !Set(wordTokens(message)).isDisjoint(with: verbs) {
                return true
            }
        }
        let dontNeed = [
            "don't need", "dont need", "do not need",
            "doesn't need", "doesnt need", "does not need",
            "no longer need",
        ]
        if dontNeed.contains(where: lowered.contains) {
            return true
        }
        let stopReminding = [
            "stop reminding", "don't remind", "dont remind",
            "do not remind", "stop telling me",
        ]
        return stopReminding.contains(where: lowered.contains)
    }

    /// Saved ids the model dropped that may actually go: explicitly chosen
    /// ones (swap picks), ones named with an explicit edit phrase, and ones
    /// named with an edit verb on a turn that adds nothing new (so "remove
    /// the water one" still removes water). A chore phrasing that shares a
    /// word with a saved need ("Remove the table...") is blocked whenever
    /// the turn also adds needs. Everything else the model drops is kept.
    public static func removalsAllowed(
        current: [Need],
        modelIDs: Set<String>,
        message: String,
        explicitRemovals: Set<String>
    ) -> Set<String> {
        var allowed = explicitRemovals
        let currentIDs = Set(current.map(\.id))
        let addsNew = !modelIDs.subtracting(currentIDs).isEmpty
        let explicit = hasExplicitEditIntent(message: message)
        let editVerb = isEditMessage(message)
        for need in current where !modelIDs.contains(need.id) {
            guard namesNeed(message: message, need: need) else { continue }
            if explicit || (editVerb && !addsNew) {
                allowed.insert(need.id)
            }
        }
        return allowed
    }

    /// Saved needs the model dropped that the guard keeps: the turn is
    /// logged, not applied.
    public static func blockedRemovals(
        current: [Need],
        modelIDs: Set<String>,
        message: String,
        explicitRemovals: Set<String> = []
    ) -> [Need] {
        let allowed = removalsAllowed(
            current: current,
            modelIDs: modelIDs,
            message: message,
            explicitRemovals: explicitRemovals
        )
        return current.filter { !modelIDs.contains($0.id) && !allowed.contains($0.id) }
    }

    /// Saved needs the merged result actually drops. The read-back card
    /// lists these so Looks right only applies what she saw.
    public static func removedNeeds(current: [Need], mergedIDs: Set<String>) -> [Need] {
        current.filter { !mergedIDs.contains($0.id) }
    }

    /// Merges model drafts onto the saved list. Drafts upsert by id (typo
    /// repair included); saved needs the model dropped are kept unless
    /// explicitly chosen or named; explicit removals win even if a draft
    /// re-adds the id; the result never exceeds the limit and never holds
    /// duplicate ids (saved needs are sacred, newest drafts past capacity
    /// drop).
    public static func merge(
        current: [Need],
        drafts: [NeedsIntentDraft],
        message: String,
        explicitRemovals: Set<String> = [],
        limit: Int = SessionLimits.maxAuthoredNeeds
    ) -> [Need] {
        let currentIDs = Set(current.map(\.id))
        let repairedIDs = Set(drafts.map { NeedsIntentSlug.repair($0.id, against: current.map(\.id)) })
        let allowed = removalsAllowed(
            current: current,
            modelIDs: repairedIDs,
            message: message,
            explicitRemovals: explicitRemovals
        )
        var merged = NeedsIntentConversion.toNeeds(drafts, current: current)
        merged.removeAll { explicitRemovals.contains($0.id) }
        let mergedIDs = Set(merged.map(\.id))
        for need in current where !mergedIDs.contains(need.id) && !allowed.contains(need.id) {
            merged.append(need)
        }
        var seen = Set<String>()
        var deduped: [Need] = []
        for need in merged where seen.insert(need.id).inserted {
            deduped.append(need)
        }
        let savedCount = deduped.filter { currentIDs.contains($0.id) }.count
        var budget = max(0, limit - savedCount)
        return deduped.filter { need in
            if currentIDs.contains(need.id) {
                return true
            }
            if budget > 0 {
                budget -= 1
                return true
            }
            return false
        }
    }

    /// In-place swap: the picked need leaves, the new one takes its slot,
    /// everyone else is untouched. An unknown pick never drops a saved
    /// need (appends only with room); a colliding new id gets a fresh slug
    /// so storage dedupe can never eat a saved row later.
    public static func applySwap(current: [Need], removeID: String, newNeed: Need) -> [Need] {
        let ids = Set(current.map(\.id))
        var fresh = newNeed
        if fresh.id != removeID, ids.contains(fresh.id) {
            fresh.id = uniqueSlug(base: NeedsIntentSlug.normalize(fresh.authorText), against: ids)
        }
        if let index = current.firstIndex(where: { $0.id == removeID }) {
            var out = current
            out[index] = fresh
            return out
        }
        guard current.count < SessionLimits.maxAuthoredNeeds else {
            return current
        }
        return current + [fresh]
    }

    static func uniqueSlug(base: String, against ids: Set<String>) -> String {
        let stem = base.isEmpty ? "need" : base
        if !ids.contains(stem) {
            return stem
        }
        var n = 2
        while ids.contains("\(stem)-\(n)") {
            n += 1
        }
        return "\(stem)-\(n)"
    }
}

// MARK: - Reply-text hardening (raw JSON must never reach a bubble)

public enum NeedReplyText {
    /// Pulls the first balanced {...} payload out of surrounding prose
    /// (string- and escape-aware). No balanced braces → the text itself.
    public static func extractPayload(_ text: String) -> String {
        let chars = Array(text)
        guard let open = chars.firstIndex(of: "{") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < chars.count {
            let char = chars[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(chars[open...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            index += 1
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the text carries something shaped like JSON: a balanced
    /// brace span containing a quote or colon, or an unbalanced brace
    /// tail with quotes or colons (truncated JSON). Plain prose with
    /// braces ("use {brackets} here") reads as prose.
    public static func looksLikeJSON(_ text: String) -> Bool {
        guard let open = text.firstIndex(of: "{") else {
            return false
        }
        let payload = extractPayload(text)
        if payload.hasPrefix("{"), payload.hasSuffix("}") {
            return payload.contains("\"") || payload.contains(":")
        }
        let tail = text[open...]
        return tail.contains("\"") || tail.contains(":")
    }

    public static let fallbackQuestion = "I didn't quite catch that — could you say it once more?"
}
