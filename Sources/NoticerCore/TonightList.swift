import Foundation

/// Which stored moments belong on Tonight. The same rule while a session is
/// running and after it stops: the local calendar day, and only needs that
/// are still on her list. A removed need drops off instead of keeping its
/// old wording.
public enum TonightList {
    public static func isVisible(
        at: Date,
        needID: String,
        activeNeedIDs: Set<String>,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard activeNeedIDs.contains(needID) else { return false }
        return calendar.isDate(at, inSameDayAs: now)
    }

    public static func select<Moment>(
        _ moments: [Moment],
        at: (Moment) -> Date,
        needID: (Moment) -> String,
        activeNeedIDs: Set<String>,
        now: Date,
        calendar: Calendar = .current
    ) -> [Moment] {
        moments.filter {
            isVisible(
                at: at($0),
                needID: needID($0),
                activeNeedIDs: activeNeedIDs,
                now: now,
                calendar: calendar
            )
        }
    }
}

/// Tonight resets per evening, not per day: an evening runs 12:00 PM to
/// 11:59 AM local time, so a 00:25 entry belongs to the previous night.
/// Runs on launch and on session start; never on stop.
public enum TonightReset {
    public static func eveningStart(now: Date, calendar: Calendar = .current) -> Date {
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        if now < noon {
            return calendar.date(byAdding: .day, value: -1, to: noon) ?? noon
        }
        return noon
    }

    public static func reset<Moment>(
        _ moments: [Moment],
        at: (Moment) -> Date,
        now: Date,
        calendar: Calendar = .current
    ) -> (kept: [Moment], dropped: Int) {
        let start = eveningStart(now: now, calendar: calendar)
        let kept = moments.filter { at($0) >= start }
        return (kept, moments.count - kept.count)
    }
}
