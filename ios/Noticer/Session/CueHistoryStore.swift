import Foundation

/// Cue counts per day, kept on the phone in `UserDefaults` as day → count.
/// `SessionMomentsStore` only keeps tonight; this is the history behind the
/// Learning bars and week dots. A day entry exists once a session ran that
/// day, even with zero cues, so dots mark session days.
enum CueHistoryStore {
    static let key = "noticer.cueHistory.v1"
    static let capDays = 365

    static func load(defaults: UserDefaults = .standard) -> [String: Int] {
        guard let data = defaults.data(forKey: key),
              let history = try? JSONDecoder().decode([String: Int].self, from: data)
        else {
            return [:]
        }
        return history
    }

    static func save(_ history: [String: Int], defaults: UserDefaults = .standard) {
        let ordered = history.sorted { $0.key > $1.key }
        let trimmed = Dictionary(uniqueKeysWithValues: Array(ordered.prefix(capDays)))
        guard let data = try? JSONEncoder().encode(trimmed) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    /// Records one fired cue. Pure over the history dict; the caller saves.
    static func recordingCue(in history: [String: Int], at date: Date = Date()) -> [String: Int] {
        var next = history
        let day = dayKey(for: date)
        next[day, default: 0] += 1
        return next
    }

    /// Marks a session day so dots and bars know a session ran, even cueless.
    static func recordingSessionDay(in history: [String: Int], at date: Date = Date()) -> [String: Int] {
        var next = history
        let day = dayKey(for: date)
        if next[day] == nil {
            next[day] = 0
        }
        return next
    }

    static func recordCue(at date: Date = Date(), defaults: UserDefaults = .standard) {
        save(recordingCue(in: load(defaults: defaults), at: date), defaults: defaults)
    }

    static func recordSessionDay(at date: Date = Date(), defaults: UserDefaults = .standard) {
        save(recordingSessionDay(in: load(defaults: defaults), at: date), defaults: defaults)
    }

    static func count(on date: Date, in history: [String: Int]) -> Int {
        history[dayKey(for: date)] ?? 0
    }

    /// True when the day has a session entry (even zero cues).
    static func hasSession(on date: Date, in history: [String: Int]) -> Bool {
        history[dayKey(for: date)] != nil
    }

    /// Most recent day before `date` with a session entry, for "down from N".
    static func mostRecentPriorDay(before date: Date, in history: [String: Int]) -> (date: Date, count: Int)? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let days = history.keys.compactMap(date(forDayKey:)).filter { $0 < start }.sorted()
        guard let day = days.last else {
            return nil
        }
        return (day, history[dayKey(for: day)] ?? 0)
    }

    /// Trailing daily counts, oldest first, ending on `date`.
    static func lastDays(_ days: Int, ending date: Date, in history: [String: Int]) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return (0..<max(1, days)).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: start) else {
                return nil
            }
            return (day, hasSession(on: day, in: history) ? count(on: day, in: history) : 0)
        }
    }

    /// True when cues trend down over 3 or more session days: the trailing
    /// run is non-increasing and ends below where it starts.
    static func isFading(history: [String: Int], ending date: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let sessionDays = history.keys.compactMap(date(forDayKey:)).filter { $0 <= start }.sorted()
        guard sessionDays.count >= 3 else {
            return false
        }
        let trail = sessionDays.suffix(7).map { count(on: $0, in: history) }
        guard trail.count >= 3, let first = trail.first, let last = trail.last, last < first else {
            return false
        }
        return zip(trail, trail.dropFirst()).allSatisfy { $0 >= $1 }
    }

    /// Trailing 7-day buckets, oldest first, ending on `date`. Labels are
    /// the bucket's first day as "M/d".
    static func weeklyBuckets(_ weeks: Int, ending date: Date, in history: [String: Int]) -> [(label: String, count: Int)] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let labeler = DateFormatter()
        labeler.dateFormat = "M/d"
        return (0..<max(1, weeks)).map { chunk in
            let backBase = (max(1, weeks) - 1 - chunk) * 7
            var count = 0
            var first: Date = start
            for back in backBase..<(backBase + 7) {
                guard let day = calendar.date(byAdding: .day, value: -back, to: start) else {
                    continue
                }
                first = day
                count += history[dayKey(for: day)] ?? 0
            }
            return (labeler.string(from: first), count)
        }
    }

    /// Trailing calendar months, oldest first. Labels are "MMM".
    static func monthlyBuckets(_ months: Int, ending date: Date, in history: [String: Int]) -> [(label: String, count: Int)] {
        let calendar = Calendar.current
        let labeler = DateFormatter()
        labeler.dateFormat = "MMM"
        let endMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return (0..<max(1, months)).reversed().map { back in
            let month = calendar.date(byAdding: .month, value: -back, to: endMonth) ?? endMonth
            var count = 0
            if let range = calendar.range(of: .day, in: .month, for: month) {
                for day in range {
                    var parts = calendar.dateComponents([.year, .month], from: month)
                    parts.day = day
                    if let date = calendar.date(from: parts) {
                        count += history[dayKey(for: date)] ?? 0
                    }
                }
            }
            return (labeler.string(from: month), count)
        }
    }

    static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Calendar.current.startOfDay(for: date))
    }

    static func date(forDayKey key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
}
