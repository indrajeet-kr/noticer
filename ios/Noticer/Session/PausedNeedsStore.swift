import Foundation
import NoticerCore

/// Needs paused for tonight, kept on the phone in their own `UserDefaults`
/// key so `Need` and the engine stay untouched. "Pause tonight" means
/// tonight: ids roll over at the next calendar day, and the paused set
/// clears on load when the stored day is stale.
enum PausedNeedsStore {
    static let key = "noticer.pausedNeeds.v1"

    private struct Payload: Codable {
        var ids: Set<String>
        /// `yyyy-MM-dd` in the current calendar.
        var day: String
    }

    static func load(defaults: UserDefaults = .standard, today: Date = Date()) -> Set<String> {
        guard let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return []
        }
        guard payload.day == dayKey(for: today) else {
            return []
        }
        return payload.ids
    }

    static func save(_ ids: Set<String>, defaults: UserDefaults = .standard, today: Date = Date()) {
        let payload = Payload(ids: ids, day: dayKey(for: today))
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    /// The session list: paused ids dropped, order kept.
    static func active(needs: [Need], pausedIDs: Set<String>) -> [Need] {
        needs.filter { !pausedIDs.contains($0.id) }
    }

    static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Calendar.current.startOfDay(for: date))
    }
}
