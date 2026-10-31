import Foundation

/// Phrased timing for the need detail sheet: words lead, seconds stay
/// secondary. Pure so the copy is unit-testable.
enum TimingWords {
    /// "He gets about a minute and a half to notice first", plus "90 seconds".
    /// The detail is nil when the main sentence already states the exact
    /// seconds (under a minute), so the sheet never shows "20 seconds" twice.
    static func headStartSentence(seconds: TimeInterval) -> (main: String, detail: String?) {
        let total = max(0, Int(seconds.rounded()))
        let detail: String? = total < 60 ? nil : "\(total) seconds"
        return ("He gets \(amount(total)) to notice first", detail)
    }

    private static func amount(_ total: Int) -> String {
        if total < 60 {
            return total == 1 ? "about a second" : "about \(total) seconds"
        }
        let minutes = total / 60
        let rest = total % 60
        if rest == 0 {
            return minutes == 1 ? "about a minute" : "about \(minutes) minutes"
        }
        if rest == 30 {
            return minutes == 1 ? "about a minute and a half" : "about \(minutes) minutes and a half"
        }
        if total < 90 {
            return "about a minute"
        }
        return "about \(minutes) minutes"
    }
}

/// Her-list header copy: "3 things she's shared", or "Nothing shared yet".
enum ListHeader {
    static func title(count: Int) -> String {
        switch count {
        case 0:
            return "Nothing shared yet"
        case 1:
            return "1 thing she's shared"
        default:
            return "\(count) things she's shared"
        }
    }
}

/// Wins header day line from the session's start: "Friday evening" when it
/// started at 17:00 or later, else "Friday morning"/"Friday afternoon".
enum DayPart {
    static func line(for date: Date) -> String {
        let namer = DateFormatter()
        namer.locale = Locale(identifier: "en_US_POSIX")
        namer.dateFormat = "EEEE"
        let hour = Calendar.current.component(.hour, from: date)
        let part = hour >= 17 ? "evening" : hour >= 12 ? "afternoon" : "morning"
        return "\(namer.string(from: date)) \(part)"
    }
}

/// Learning week sentence: "3 cues tonight, down from 7."
enum CueWeekSentence {
    static func text(tonight: Int, prior: Int?) -> String {
        let noun = tonight == 1 ? "1 cue" : "\(tonight) cues"
        switch (tonight, prior) {
        case (0, _):
            return "No cues tonight."
        case (_, let prior?) where prior > tonight:
            return "\(noun) tonight, down from \(prior)."
        default:
            return "\(noun) tonight."
        }
    }
}

/// Wins sentences: "He caught 3 things on his own tonight. 2 cues, down from 5."
enum WinsSummary {
    static func sentence(selfNotices: Int, cues: Int, priorCues: Int?) -> String {
        var parts: [String] = []
        if selfNotices == 1 {
            parts.append("He caught 1 thing on his own tonight.")
        } else if selfNotices > 1 {
            parts.append("He caught \(selfNotices) things on his own tonight.")
        }
        if cues > 0 {
            let noun = cues == 1 ? "1 cue" : "\(cues) cues"
            if let prior = priorCues, prior > cues {
                parts.append("\(noun.capitalizedFirst), down from \(prior).")
            } else {
                parts.append("\(noun.capitalizedFirst) tonight.")
            }
        }
        if parts.isEmpty {
            return "A quiet night together."
        }
        return parts.joined(separator: " ")
    }

    static func headline(selfNotices: Int, hasWins: Bool) -> String {
        if !hasWins {
            return "A gentle start, together"
        }
        if selfNotices == 0 {
            return "Every nudge is teamwork too"
        }
        return "A good night, together"
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else {
            return self
        }
        return String(first).uppercased() + dropFirst()
    }
}
