import Foundation
import NoticerCore
import XCTest

/// Paused-tonight ids: session exclusion, persistence, and next-day rollover.
/// `PhoneSessionModel.needsForSession()` filters through
/// `PausedNeedsStore.active`, which is what these tests pin — the model
/// itself needs the glasses toolkit and can't join this target.
final class PausedNeedsStoreTests: XCTestCase {
    private func needs() -> [Need] {
        [
            Need(id: "take-baby", authorText: "take the baby", cueWording: "", priority: 0),
            Need(id: "refill-water", authorText: "nursing, no water", cueWording: "", priority: 1),
        ]
    }

    func testActiveExcludesPausedIDs() {
        let active = PausedNeedsStore.active(needs: needs(), pausedIDs: ["refill-water"])
        XCTAssertEqual(active.map(\.id), ["take-baby"])
    }

    func testActiveKeepsOrderWithNonePaused() {
        let active = PausedNeedsStore.active(needs: needs(), pausedIDs: [])
        XCTAssertEqual(active.map(\.id), ["take-baby", "refill-water"])
    }

    func testUnknownPausedIDsAreIgnored() {
        let active = PausedNeedsStore.active(needs: needs(), pausedIDs: ["missing-need"])
        XCTAssertEqual(active.map(\.id), ["take-baby", "refill-water"])
    }

    func testPersistenceRoundTrip() {
        let defaults = UserDefaults(suiteName: "PausedNeedsStoreTests")!
        defaults.removePersistentDomain(forName: "PausedNeedsStoreTests")
        PausedNeedsStore.save(["take-baby"], defaults: defaults)
        XCTAssertEqual(PausedNeedsStore.load(defaults: defaults), ["take-baby"])
        defaults.removePersistentDomain(forName: "PausedNeedsStoreTests")
    }

    func testPausedIDsClearAtTheNextCalendarDay() {
        let defaults = UserDefaults(suiteName: "PausedNeedsStoreTests")!
        defaults.removePersistentDomain(forName: "PausedNeedsStoreTests")
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        PausedNeedsStore.save(["take-baby"], defaults: defaults, today: yesterday)
        XCTAssertEqual(PausedNeedsStore.load(defaults: defaults, today: Date()), [])
        defaults.removePersistentDomain(forName: "PausedNeedsStoreTests")
    }

    func testEmptyStoreLoadsEmpty() {
        let defaults = UserDefaults(suiteName: "PausedNeedsStoreTests")!
        defaults.removePersistentDomain(forName: "PausedNeedsStoreTests")
        XCTAssertEqual(PausedNeedsStore.load(defaults: defaults), [])
    }
}
