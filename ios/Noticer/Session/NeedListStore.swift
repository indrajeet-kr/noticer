import Foundation
import NoticerCore

/// Mom's list, kept on the phone. The compile step and the fade engine are other tracks.
enum NeedListStore {
    private static let key = "noticer.needs.v1"

    static func load() -> [Need] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let needs = try? JSONDecoder().decode([Need].self, from: data),
              !needs.isEmpty
        else {
            return defaultNeeds
        }
        return Array(needs.prefix(SessionLimits.maxAuthoredNeeds))
    }

    static func save(_ needs: [Need]) {
        let trimmed = Array(needs.prefix(SessionLimits.maxAuthoredNeeds))
        guard let data = try? JSONEncoder().encode(trimmed) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func blankNeed(priority: Int) -> Need {
        Need(
            id: UUID().uuidString,
            authorText: "",
            cueWording: "",
            priority: priority
        )
    }

    /// The recorded latch fixture uses the id `eating-one-handed`.
    static let defaultNeeds: [Need] = [
        Need(
            id: "eating-one-handed",
            authorText: "Eating one-handed, plate going cold",
            cueWording: "Her plate's getting cold, maybe take the baby?",
            priority: 0
        ),
        Need(
            id: "nursing-water",
            authorText: "Nursing, no water within reach",
            cueWording: "Water's out of reach, maybe refill it?",
            priority: 1
        ),
    ]
}
