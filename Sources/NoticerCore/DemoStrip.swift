import Foundation

/// Demo mode's live strip: a pure-observer mapping from engine events to big
/// plain words for screen recordings. It only reads values that already flow
/// to the phone and never changes engine behavior, timing, or call rate.
public struct DemoStripItem: Equatable, Sendable, Identifiable {
    public enum Style: String, Sendable {
        case neutral, noticed, headStart, whisper, outcomeWin, outcomeOther, chip
    }

    /// Monotonic sequence number, never shown.
    public var id: Int
    public var at: Date
    /// Plain language, shown as-is.
    public var text: String
    public var style: Style
    /// Head start only.
    public var countdownEndsAt: Date?

    public init(id: Int, at: Date, text: String, style: Style, countdownEndsAt: Date? = nil) {
        self.id = id
        self.at = at
        self.text = text
        self.style = style
        self.countdownEndsAt = countdownEndsAt
    }
}

public struct DemoStripBuffer: Sendable {
    public static let capacity = 20
    public static let visible = 5
    /// Oldest first.
    public private(set) var items: [DemoStripItem]
    public private(set) var sessionStart: Date?
    private var nextID = 0

    public init() {
        items = []
        sessionStart = nil
    }

    public mutating func reset(sessionStart: Date) {
        items = []
        self.sessionStart = sessionStart
        nextID = 0
    }

    public mutating func append(_ text: String, style: DemoStripItem.Style, at: Date, countdownEndsAt: Date? = nil) {
        items.append(DemoStripItem(id: nextID, at: at, text: text, style: style, countdownEndsAt: countdownEndsAt))
        nextID += 1
        if items.count > Self.capacity {
            items.removeFirst(items.count - Self.capacity)
        }
    }

    /// The last `visible` items, oldest first.
    public func visibleItems() -> [DemoStripItem] {
        Array(items.suffix(Self.visible))
    }

    public func relativeTime(_ item: DemoStripItem) -> String {
        guard let start = sessionStart else { return "+0.0s" }
        let delta = max(0, item.at.timeIntervalSince(start))
        let rounded = (delta * 10).rounded() / 10
        if rounded >= 60 {
            let total = Int(rounded)
            return String(format: "+%d:%02d", total / 60, total % 60)
        }
        return String(format: "+%.1fs", rounded)
    }
}

public enum DemoStripMapper {
    /// Returns nil for events that are not shown. The head-start closure
    /// feeds `headStartFollowUp`; this function ignores it.
    public static func item(
        for event: EngineEvent,
        needs: [Need],
        headStartSeconds: (String) -> TimeInterval?
    ) -> (String, DemoStripItem.Style, Date?)? {
        switch event.kind {
        case .needLatched:
            return ("Noticed: \(shortTitle(for: event.needID, needs: needs))", .noticed, nil)
        case .stillOpen where event.detail == "out-of-view":
            return ("Still open · out of view", .neutral, nil)
        case .caughtHimself where event.isSharedFinish:
            return ("You finished it. Nice teamwork.", .outcomeWin, nil)
        case .caughtHimself:
            return ("You got it", .outcomeWin, nil)
        case .resolvedByPartner:
            return ("She handled it", .outcomeOther, nil)
        case .closedUnknown:
            return ("Handled · unclear who", .outcomeOther, nil)
        case .cueDeferredHandsBusy:
            return ("Holding the whisper · hands busy", .neutral, nil)
        case .cueDeferredPartnerCheck:
            return ("Holding the whisper · she may have it", .neutral, nil)
        case .headStartExtended:
            return ("More time for you", .neutral, nil)
        default:
            return nil
        }
    }

    /// The head-start row that follows a latch immediately. Nil for other
    /// events or when no head start is known. The countdown end is anchored
    /// to `now` (wall time at drain), not the engine-stamped event time: the
    /// strip renders against the wall clock, and replay stamps events on a
    /// clock that can lag it, which expired the countdown instantly.
    public static func headStartFollowUp(
        for event: EngineEvent,
        headStartSeconds: (String) -> TimeInterval?,
        now: Date = Date()
    ) -> (String, DemoStripItem.Style, Date?)? {
        guard event.kind == .needLatched,
            let needID = event.needID,
            let seconds = headStartSeconds(needID)
        else { return nil }
        let shown = max(0, Int(seconds.rounded()))
        return ("Head start: \(shown)s for you", .headStart, now.addingTimeInterval(TimeInterval(shown)))
    }

    /// "Whispered: “\(spokenText)”". The inner text is byte-equal to the input.
    public static func whisperCaption(_ spokenText: String) -> String {
        "Whispered: “\(spokenText)”"
    }

    /// Parses "call=… purpose=… model=2604ms …" into "Muse Spark · 2.6s".
    /// Any other timing line returns nil.
    public static func latencyChip(fromTimingLine line: String) -> String? {
        for token in line.split(whereSeparator: \.isWhitespace) {
            guard token.hasPrefix("model="), token.hasSuffix("ms") else { continue }
            let digits = token.dropFirst("model=".count).dropLast("ms".count)
            guard let ms = Double(digits) else { continue }
            return String(format: "Muse Spark · %.1fs", ms / 1_000)
        }
        return nil
    }

    public static let firstFrame = "Live · first frame in"
    /// Short label: the demo strip's empty row and Tonight's "now" line.
    public static let listening = "Listening quietly"
    /// Sentence form for the Tonight status line and the session phase.
    public static let listeningStatus = "Listening quietly."

    /// Listening lines the phone shows. The forbidden-word check covers these
    /// without the iOS target.
    public static let userFacingListeningLines = [listening, listeningStatus]

    /// The need's words, never its id. Trimmed to 40 chars on a word
    /// boundary with "…" when longer; "a need" when missing.
    public static func shortTitle(for needID: String?, needs: [Need]) -> String {
        guard let needID,
            let text = needs.first(where: { $0.id == needID })?.authorText.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return "a need" }
        if text.count <= 40 { return text }
        var words: [String] = []
        var length = 0
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let next = length == 0 ? word.count : length + 1 + word.count
            if next > 40 { break }
            words.append(word)
            length = next
        }
        if words.isEmpty { return String(text.prefix(40)) + "…" }
        return words.joined(separator: " ") + "…"
    }

    public static let forbiddenWords = ["glasses", "camera", "cameras", "saw", "see", "seeing", "seen", "watch", "watching", "watched"]

    public static func passesWordRules(_ s: String) -> Bool {
        let words = s.lowercased().split { !$0.isLetter }.map(String.init)
        return !words.contains { forbiddenWords.contains($0) }
    }
}
