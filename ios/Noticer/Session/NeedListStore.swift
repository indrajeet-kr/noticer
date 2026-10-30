import Foundation
import NoticerCore
import NoticerPipeline

/// Mom's list, kept on the phone. The default ids match the engine and the scenarios.
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

    /// Same ids as the need engine and `fixtures/scenarios`: `take-baby`, `refill-water`.
    static let defaultNeeds: [Need] = MVPNeedList.all
}
