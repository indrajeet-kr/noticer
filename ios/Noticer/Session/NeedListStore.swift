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

    /// A short id for the model, taken from her words. The text field never edits this.
    /// A generated id stays a UUID until she leaves the card, so typing does not rebuild the row.
    static func readableID(from text: String, avoiding taken: Set<String>) -> String? {
        var slug = ""
        var pendingHyphen = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !slug.isEmpty {
                    slug.append("-")
                }
                pendingHyphen = false
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty {
                pendingHyphen = true
            }
            if slug.count >= 48 {
                break
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        guard !slug.isEmpty else {
            return nil
        }
        if !taken.contains(slug) {
            return slug
        }
        var suffix = 2
        while taken.contains("\(slug)-\(suffix)") {
            suffix += 1
        }
        return "\(slug)-\(suffix)"
    }

    /// Same ids as the need engine and `fixtures/scenarios`: `take-baby`, `refill-water`.
    static let defaultNeeds: [Need] = MVPNeedList.all
}
