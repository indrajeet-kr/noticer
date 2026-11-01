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
