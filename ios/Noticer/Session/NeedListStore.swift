import Foundation
import NoticerCore
import NoticerPipeline
import os

/// Mom's list, kept on the phone. The default ids match the engine and the scenarios.
enum NeedListStore {
    private static let key = "noticer.needs.v1"
    private static let logger = Logger(subsystem: "app.noticer.Noticer", category: "needs")

    static func load(log: ((String, String) -> Void)? = nil) -> [Need] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let needs = try? JSONDecoder().decode([Need].self, from: data),
              !needs.isEmpty
        else {
            return defaultNeeds
        }
        let repaired = repairIDs(needs)
        let migrated = NeedPolarityMigration.migrate(repaired)
        for reviewID in migrated.needsPolarityReviewIDs {
            if let log {
                log("NEEDS", "needs-polarity-review \(reviewID)")
            } else {
                logger.notice("[NEEDS] needs-polarity-review \(reviewID, privacy: .public)")
            }
        }
        if migrated.needs != needs {
            save(migrated.needs)
        }
        return Array(migrated.needs.prefix(SessionLimits.maxAuthoredNeeds))
    }

    /// Repairs ids the model typo'd on an earlier edit (e.g. "takeq-baby")
    /// by snapping single-typo slugs back to the canonical pair. Anything
    /// else, including her custom ids, passes through untouched. Merges drop
    /// the later duplicate and keep the first row.
    static func repairIDs(_ needs: [Need]) -> [Need] {
        var seen = Set<String>()
        var out: [Need] = []
        for var need in needs {
            need.id = NeedsIntentSlug.repair(
                need.id,
                against: [NeedsIntentSlug.takeBaby, NeedsIntentSlug.refillWater]
            )
            guard seen.insert(need.id).inserted else {
                continue
            }
            out.append(need)
        }
        return out
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
