import Foundation
import NoticerAgent
import NoticerCore

// MARK: - Mom's-list intent conversion (UI layer, pure logic)

///
/// Turns mom's free text into structured needs through one Muse Spark
/// chat-completions call. The engine never sees this type: the UI converts
/// the result into `[Need]` and assigns the existing model's `needs`.
///
/// Contract (from the UX spec):
/// - `POST https://api.meta.ai/v1/chat/completions`, model `muse-spark-1.3`,
///   `reasoning_effort: minimal`, `tool_choice: auto`.
/// - `max_tokens` is omitted. Reasoning tokens count toward that cap, and a
///   1024 cap was cutting the tool call off (`finish_reason: length`).
/// - Every request message `content` is a non-null string.
/// - Tools: `set_needs` (full replacement list, max 6) and
///   `ask_clarifying_question` (exactly one question, saves nothing).
/// - No tool call means `message.content` is a clarifying-question bubble.
/// - Any failure keeps the last saved list; the caller shows the offline
///   banner and a Retry button.
///

// MARK: Priority words

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

// MARK: Drafts and results

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
        self.wearerSignal = wearerSignal
        self.isUrgent = isUrgent
    }
}

public enum NeedsIntentResult: Sendable, Equatable {
    /// Full replacement list plus one warm read-back sentence.
    case needs([NeedsIntentDraft], readBack: String)
    /// Exactly one question. Suggestions answer it by sending that text.
    case question(question: String, suggestions: [String])
}

public enum NeedsIntentError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingAPIKey
    case transport(String)
    case rejected(status: Int, message: String)
    case malformedResponse(String)
    case invalidNeeds(String)
    case forbiddenWhisper(needID: String, word: String)

    public var description: String {
        switch self {
        case .missingAPIKey:
            return "No API key is saved."
        case .transport(let message):
            return message
        case .rejected(let status, let message):
            return message.isEmpty ? "HTTP \(status)." : "HTTP \(status): \(message)"
        case .malformedResponse(let message):
            return message
        case .invalidNeeds(let message):
            return message
        case .forbiddenWhisper(let needID, let word):
            return "The whisper for \(needID) mentions \"\(word)\"."
        }
    }
}

// MARK: System prompt (stored constant, from the UX spec)

public enum NeedsIntentSystemPrompt {
    public static let text = """
        You help a mother tell a supportive teammate app what helps her at home. Convert her words into a short list of concrete household needs her partner can notice.
        Rules:
        - Each distinct, observable need becomes one item. Do not invent needs she did not express, and do not split one need into several.
        - Keep authorText in her words.
        - whisper is a calm, warm coaching invitation of 8 words or fewer for her partner, e.g. "Maybe offer to take the baby?" or "Grab her a water refill?". For a safety need it may be a little firmer but still kind, e.g. "Could you move that glass from the baby?". Never scold, never state blunt alarms, and never mention glasses, camera, cameras, watch, watching, saw, see or seeing.
        - problem_visual is the UNMET state you would see when she needs help, as seen in a first-person frame, always with its person or place anchor, never the goal: "dining table surface visible with no water bottle on it", NOT "water bottle on dining table".
        - handled_visual is the state after it is done, what the same scene looks like once it is handled: "water bottle standing on the dining table".
        - wearer_signal is his helping action in snake_case starting with wearer_: "wearer_placing_water_bottle_on_table".
        - urgent is true only for immediate physical safety hazards (such as a glass or sharp object on the floor near the baby), otherwise false.
        - Priority: "important" if she stresses urgency or safety, "gentle" if casual, otherwise "normal". allowsCheckIn is true only if she says asking her is fine.
        - Do not add medical, medication or dosing, fever, infant sleep or breathing monitoring, or mental-health requests. Instead call ask_clarifying_question, gently explaining that Noticer only helps with everyday household logistics, and suggest a household version if there is one.
        - If CURRENT_LIST is non-empty, treat her message as an edit (reprioritize, remove, reword, add) and return the FULL updated list via set_needs, keeping existing ids.
        - If she lists more than 6 needs, call ask_clarifying_question asking which 6 matter most, with suggestions.
        - If a need is too vague to observe, call ask_clarifying_question with exactly one gentle question.
        - Otherwise call set_needs. Never call both tools.
        Examples:
        - "Keep water bottle on dining table" -> problem_visual "dining table visible with no water bottle", handled_visual "water bottle on the dining table", wearer_signal "wearer_placing_water_bottle_on_table"
        - "Bring her water when she's on the couch" -> problem_visual "partner on couch with no water within reach", handled_visual "glass of water within her reach", wearer_signal "wearer_handing_water_to_partner"
        - "Take the baby when her food is getting cold" -> problem_visual "partner eating while holding the baby", handled_visual "partner eating with both hands free", wearer_signal "wearer_hands_receiving_baby"
        """
}

// MARK: Slugs

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

// MARK: Whisper rules

/// Length clamps, then a forbidden-word check on what would actually ship.
/// Matching is case-insensitive on whole words, so "seed" never trips "see".
public enum NeedsIntentWhisper {
    public static let maxCharacters = 60
    public static let maxWords = 8
    public static let forbiddenWords = [
        "glasses", "camera", "cameras", "saw", "see", "seeing", "seen", "watch", "watching", "watched"
    ]

    public static func clamp(_ raw: String) -> String {
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        var text = words.prefix(maxWords).joined(separator: " ")
        if text.count > maxCharacters {
            let cut = text.prefix(maxCharacters)
            if let lastSpace = cut.lastIndex(of: " ") {
                text = String(cut[..<lastSpace])
            } else {
                text = String(cut)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first forbidden word in the text, if any.
    public static func forbiddenWord(in whisper: String) -> String? {
        let words = whisper.lowercased().split { !$0.isLetter }.map(String.init)
        return words.first { forbiddenWords.contains($0) }
    }
}

// MARK: Request body

/// Builds the exact chat-completions body from the UX spec. Both message
/// contents are always strings, never null.
public enum NeedsIntentRequest {
    public static let modelID = "muse-spark-1.3"
    public static let reasoningEffort = "minimal"
    public static let toolChoice = "auto"

    public static func body(currentList: [Need], message: String) throws -> Data {
        let userText = "CURRENT_LIST: \(NeedsIntentConversion.currentListJSON(currentList))\nMESSAGE: \(message)"
        let payload = WireRequest(
            model: modelID,
            reasoningEffort: reasoningEffort,
            toolChoice: toolChoice,
            messages: [
                WireMessage(role: MuseSparkModelClient.instructionRole, content: NeedsIntentSystemPrompt.text),
                WireMessage(role: "user", content: userText),
            ],
            tools: NeedsIntentTools.wireTools()
        )
        return try JSONEncoder().encode(payload)
    }

    public struct WireMessage: Encodable {
        public var role: String
        public var content: String
    }

    private struct WireRequest: Encodable {
        var model: String
        var reasoningEffort: String
        var toolChoice: String
        var messages: [WireMessage]
        var tools: [JSONValue]
        var parallelToolCalls: Bool = false

        private enum CodingKeys: String, CodingKey {
            case model
            case reasoningEffort = "reasoning_effort"
            case toolChoice = "tool_choice"
            case messages
            case tools
            case parallelToolCalls = "parallel_tool_calls"
        }
    }
}

// MARK: Tool schemas (from the UX spec)

public enum NeedsIntentTools {
    public static let setNeedsName = "set_needs"
    public static let askQuestionName = "ask_clarifying_question"

    public static func wireTools() -> [JSONValue] {
        [setNeedsEntry(), askQuestionEntry()]
    }

    private static func setNeedsEntry() -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(setNeedsName),
                "description": .string(
                    "Replace mom's full needs list with this list (max 6). Always return the complete list, including unchanged needs."
                ),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "needs": .object([
                            "type": .string("array"),
                            "maxItems": .number(6),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "id": .object([
                                        "type": .string("string"),
                                        "pattern": .string("^[a-z0-9]+(-[a-z0-9]+)*$"),
                                        "description": .string(
                                            "short stable kebab slug, e.g. take-baby, refill-water; keep existing ids on edits"
                                        ),
                                    ]),
                                    "authorText": .object([
                                        "type": .string("string"),
                                        "description": .string(
                                            "the need in her own words, lightly trimmed, second person read-back friendly"
                                        ),
                                    ]),
                                    "whisper": .object([
                                        "type": .string("string"),
                                        "maxLength": .number(60),
                                        "description": .string(
                                            "short warm coaching line for dad, <= 8 words, e.g. 'Her water's low.' Never mention glasses, cameras, or seeing."
                                        ),
                                    ]),
                                    "priority": .object([
                                        "type": .string("string"),
                                        "enum": .array([.string("gentle"), .string("normal"), .string("important")]),
                                    ]),
                                    "allowsCheckIn": .object([
                                        "type": .string("boolean"),
                                        "description": .string("true only if she implies dad may ask her"),
                                    ]),
                                    "problem_visual": .object([
                                        "type": .string("string"),
                                        "description": .string(
                                            "the unmet state that triggers the need, always with its person or place anchor, e.g. 'dining table surface visible with no water bottle on it'"
                                        ),
                                    ]),
                                    "handled_visual": .object([
                                        "type": .string("string"),
                                        "description": .string(
                                            "what the same scene looks like once handled, e.g. 'water bottle standing on the dining table'"
                                        ),
                                    ]),
                                    "wearer_signal": .object([
                                        "type": .string("string"),
                                        "description": .string(
                                            "dad's helping action in snake_case starting with wearer_, e.g. 'wearer_placing_water_bottle_on_table'"
                                        ),
                                    ]),
                                    "urgent": .object([
                                        "type": .string("boolean"),
                                        "description": .string(
                                            "true only for immediate physical safety hazards where the whisper should not wait"
                                        ),
                                    ]),
                                ]),
                                "required": .array([
                                    .string("id"), .string("authorText"), .string("whisper"),
                                    .string("priority"), .string("allowsCheckIn"),
                                    .string("problem_visual"), .string("handled_visual"), .string("wearer_signal"),
                                ]),
                            ]),
                        ]),
                        "readBack": .object([
                            "type": .string("string"),
                            "description": .string("one warm sentence summarizing the list"),
                        ]),
                    ]),
                    "required": .array([.string("needs"), .string("readBack")]),
                ]),
            ]),
        ])
    }

    private static func askQuestionEntry() -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(askQuestionName),
                "description": .string(
                    "Ask exactly one gentle question when the message is ambiguous or lists more than 6 needs. Do not save anything."
                ),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "question": .object(["type": .string("string")]),
                        "suggestions": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "maxItems": .number(6),
                        ]),
                    ]),
                    "required": .array([.string("question")]),
                ]),
            ]),
        ])
    }
}

// MARK: Response parsing

/// Reads `choices[0].message.tool_calls`. With no tool call, `content` is a
/// clarifying-question bubble. Assistant `content` may be null when a tool
/// call carries the turn.
public enum NeedsIntentResponse {
    public static func parse(data: Data) throws -> NeedsIntentResult {
        let envelope: WireEnvelope
        do {
            envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        } catch {
            throw NeedsIntentError.malformedResponse("The reply was not a chat completion.")
        }
        guard let choice = envelope.choices.first else {
            throw NeedsIntentError.malformedResponse("The reply had no message.")
        }
        if choice.finishReason == FinishReason.length.rawValue {
            throw NeedsIntentError.malformedResponse(
                "finish_reason was length. The token cap cut the turn off before a tool call finished. Reasoning tokens count toward max_tokens, so raise the cap to at least \(MuseSparkModelClient.minimumMaxTokens) or leave it unset."
            )
        }
        let message = choice.message
        let calls = message.toolCalls ?? []
        if calls.isEmpty {
            let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw NeedsIntentError.malformedResponse("The reply was empty.")
            }
            return .question(question: text, suggestions: [])
        }
        guard calls.count == 1, let call = calls.first else {
            throw NeedsIntentError.malformedResponse(
                "The model returned \(calls.count) tool calls. This turn expects exactly one."
            )
        }
        switch call.function.name {
        case NeedsIntentTools.setNeedsName:
            return try parseSetNeeds(call.function.arguments)
        case NeedsIntentTools.askQuestionName:
            return try parseQuestion(call.function.arguments)
        default:
            throw NeedsIntentError.malformedResponse("The model called unknown tool \(call.function.name).")
        }
    }

    private static func parseSetNeeds(_ arguments: String) throws -> NeedsIntentResult {
        guard let data = arguments.data(using: .utf8) else {
            throw NeedsIntentError.malformedResponse("The set_needs arguments were not text.")
        }
        let decoded: WireSetNeeds
        do {
            decoded = try JSONDecoder().decode(WireSetNeeds.self, from: data)
        } catch {
            throw NeedsIntentError.malformedResponse("The set_needs arguments were not readable.")
        }
        guard decoded.needs.count <= SessionLimits.maxAuthoredNeeds else {
            throw NeedsIntentError.invalidNeeds(
                "The model returned \(decoded.needs.count) needs. The list holds \(SessionLimits.maxAuthoredNeeds)."
            )
        }
        var drafts: [NeedsIntentDraft] = []
        var seen: Set<String> = []
        for raw in decoded.needs {
            let id = NeedsIntentSlug.normalize(raw.id)
            guard NeedsIntentSlug.isValid(id) else {
                throw NeedsIntentError.invalidNeeds("The model returned an unusable id.")
            }
            guard !seen.contains(id) else {
                throw NeedsIntentError.invalidNeeds("The model returned \(id) twice.")
            }
            seen.insert(id)
            let authorText = raw.authorText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !authorText.isEmpty else {
                throw NeedsIntentError.invalidNeeds("A need came back without her words.")
            }
            let visualCue = (raw.problemVisual ?? raw.visualCue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !visualCue.isEmpty else {
                throw NeedsIntentError.invalidNeeds("A need came back without an observable cue.")
            }
            let handledVisual = (raw.handledVisual ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let wearerSignal = (raw.wearerSignal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let whisper = NeedsIntentWhisper.clamp(raw.whisper)
            guard !whisper.isEmpty else {
                throw NeedsIntentError.invalidNeeds("A need came back without a whisper.")
            }
            if let word = NeedsIntentWhisper.forbiddenWord(in: whisper) {
                throw NeedsIntentError.forbiddenWhisper(needID: id, word: word)
            }
            drafts.append(NeedsIntentDraft(
                id: id,
                authorText: authorText,
                whisper: whisper,
                priority: .lenient(raw.priority),
                allowsCheckIn: raw.allowsCheckIn,
                visualCue: visualCue,
                handledVisual: handledVisual,
                wearerSignal: wearerSignal,
                isUrgent: raw.urgent ?? false
            ))
        }
        return .needs(drafts, readBack: decoded.readBack.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseQuestion(_ arguments: String) throws -> NeedsIntentResult {
        guard let data = arguments.data(using: .utf8) else {
            throw NeedsIntentError.malformedResponse("The question arguments were not text.")
        }
        let decoded: WireQuestion
        do {
            decoded = try JSONDecoder().decode(WireQuestion.self, from: data)
        } catch {
            throw NeedsIntentError.malformedResponse("The question arguments were not readable.")
        }
        let question = decoded.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            throw NeedsIntentError.malformedResponse("The model asked an empty question.")
        }
        let suggestions = (decoded.suggestions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return .question(question: question, suggestions: Array(suggestions.prefix(6)))
    }

    private struct WireEnvelope: Decodable {
        var choices: [WireChoice]
    }

    private struct WireChoice: Decodable {
        var message: WireAssistantMessage
        var finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    private struct WireAssistantMessage: Decodable {
        var content: String?
        var toolCalls: [WireToolCall]?

        private enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    private struct WireToolCall: Decodable {
        var function: WireFunction
    }

    private struct WireFunction: Decodable {
        var name: String
        var arguments: String
    }

    private struct WireSetNeeds: Decodable {
        var needs: [WireNeed]
        var readBack: String
    }

    private struct WireNeed: Decodable {
        var id: String
        var authorText: String
        var whisper: String
        var priority: String
        var allowsCheckIn: Bool
        var problemVisual: String?
        var handledVisual: String?
        var wearerSignal: String?
        var visualCue: String?
        var urgent: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case authorText
            case whisper
            case priority
            case allowsCheckIn
            case problemVisual = "problem_visual"
            case handledVisual = "handled_visual"
            case wearerSignal = "wearer_signal"
            case visualCue
            case urgent
        }
    }

    private struct WireQuestion: Decodable {
        var question: String
        var suggestions: [String]?
    }
}

// MARK: Conversion into the engine's [Need]

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
            let signal = draft.wearerSignal.trimmingCharacters(in: .whitespacesAndNewlines)
            return Need(
                id: id,
                authorText: draft.authorText,
                cueWording: draft.whisper,
                visualCondition: draft.visualCue.isEmpty ? old?.visualCondition : draft.visualCue,
                handledCondition: handled.isEmpty ? old?.handledCondition : handled,
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

// MARK: - Live client

public struct NeedsIntentConfiguration: Sendable, Equatable {
    public var endpoint: URL
    public var modelID: String
    public var requestTimeout: TimeInterval
    public var maxAttempts: Int
    public var retryInitialDelay: TimeInterval
    public var retryMaximumDelay: TimeInterval

    public init(
        endpoint: URL = MuseSparkModelClient.chatCompletionsURL,
        modelID: String = NeedsIntentRequest.modelID,
        requestTimeout: TimeInterval = 60,
        maxAttempts: Int = 3,
        retryInitialDelay: TimeInterval = 0.5,
        retryMaximumDelay: TimeInterval = 8
    ) {
        self.endpoint = endpoint
        self.modelID = modelID
        self.requestTimeout = requestTimeout
        self.maxAttempts = max(1, maxAttempts)
        self.retryInitialDelay = retryInitialDelay
        self.retryMaximumDelay = max(retryInitialDelay, retryMaximumDelay)
    }
}

/// One-shot interpreter. Throws `NeedsIntentError`; the UI keeps the saved
/// list on every error. The key never appears in an error message.
public struct NeedsIntentClient: Sendable {
    private let apiKey: String?
    private let transport: any HTTPTransport
    private let configuration: NeedsIntentConfiguration
    private let sleeper: any RetrySleeper

    public init(
        apiKey: String?,
        transport: (any HTTPTransport)? = nil,
        configuration: NeedsIntentConfiguration = NeedsIntentConfiguration(),
        sleeper: any RetrySleeper = TaskRetrySleeper()
    ) {
        self.apiKey = apiKey
        self.transport = transport ?? URLSessionHTTPTransport(timeout: configuration.requestTimeout)
        self.configuration = configuration
        self.sleeper = sleeper
    }

    public func interpret(currentList: [Need], message: String) async throws -> NeedsIntentResult {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NeedsIntentError.missingAPIKey
        }
        let body = try NeedsIntentRequest.body(currentList: currentList, message: message)
        let url = postURL()
        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: body
        )
        let response = try await send(request, apiKey: apiKey)
        do {
            return try NeedsIntentResponse.parse(data: response.body)
        } catch let error as NeedsIntentError {
            throw error
        } catch {
            throw NeedsIntentError.malformedResponse("The reply was not readable.")
        }
    }

    private func postURL() -> URL {
        var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        if path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        components?.path = path
        return components?.url ?? configuration.endpoint
    }

    private func send(_ request: HTTPRequest, apiKey: String) async throws -> HTTPResponse {
        var lastTransportMessage = "The request failed."
        for attempt in 0..<configuration.maxAttempts {
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastTransportMessage = Self.redact(String(describing: error), secret: apiKey)
                if Self.isTransient(error), attempt + 1 < configuration.maxAttempts {
                    try await sleeper.sleep(seconds: Self.delay(
                        attempt: attempt,
                        initial: configuration.retryInitialDelay,
                        maximum: configuration.retryMaximumDelay
                    ))
                    continue
                }
                throw NeedsIntentError.transport(lastTransportMessage)
            }
            if (200..<300).contains(response.statusCode) {
                return response
            }
            if Self.shouldRetry(status: response.statusCode), attempt + 1 < configuration.maxAttempts {
                try await sleeper.sleep(seconds: Self.delay(
                    attempt: attempt,
                    initial: configuration.retryInitialDelay,
                    maximum: configuration.retryMaximumDelay,
                    retryAfter: response.header("retry-after").flatMap { TimeInterval($0) }
                ))
                continue
            }
            throw NeedsIntentError.rejected(
                status: response.statusCode,
                message: Self.redact(Self.apiMessage(response.body), secret: apiKey)
            )
        }
        throw NeedsIntentError.transport(lastTransportMessage)
    }

    private static func shouldRetry(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private static func delay(
        attempt: Int,
        initial: TimeInterval,
        maximum: TimeInterval,
        retryAfter: TimeInterval? = nil
    ) -> TimeInterval {
        var wait = min(max(0, initial * pow(2.0, Double(attempt))), maximum)
        if let retryAfter {
            wait = min(max(wait, retryAfter), maximum)
        }
        return wait
    }

    private static func apiMessage(_ body: Data) -> String {
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .object(let root) = raw,
              case .object(let error)? = root["error"],
              case .string(let message)? = error["message"] else {
            return ""
        }
        return message
    }

    private static func redact(_ text: String, secret: String) -> String {
        guard secret.count >= 4 else { return text }
        return text.replacingOccurrences(of: secret, with: "[redacted]")
    }
}
