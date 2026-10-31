import Foundation
import NoticerCore
import XCTest

/// Her list loads the saved needs, and a fresh install shows the defaults.
/// `MomsListView` renders `model.needs` directly, so this is the list the
/// user sees on first open with no message sent.
final class NeedListStoreTests: XCTestCase {
    private let key = "noticer.needs.v1"

    func testFreshInstallShowsDefaultNeeds() {
        let stashed = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let stashed {
                UserDefaults.standard.set(stashed, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        XCTAssertEqual(NeedListStore.load(), NeedListStore.defaultNeeds)
        XCTAssertFalse(NeedListStore.defaultNeeds.isEmpty)
        for need in NeedListStore.defaultNeeds {
            XCTAssertNotNil(need.handledCondition)
            XCTAssertNotNil(need.selfNoticeSignal)
        }
    }

    func testSavedNeedsMigratePolarityAndFlagUnknownOnes() throws {
        let stashed = UserDefaults.standard.data(forKey: key)
        defer {
            if let stashed {
                UserDefaults.standard.set(stashed, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let legacy = [
            Need(id: "water", authorText: "Keep water bottle on dining table", cueWording: "Water helps.", visualCondition: "dining table without bottle", priority: 0),
            Need(id: "hall-light", authorText: "Dim hallway lamp", cueWording: "Dim the hall lamp?", priority: 1),
        ]
        NeedListStore.save(legacy)

        var logged: [String] = []
        let loaded = NeedListStore.load { tag, msg in
            logged.append("[\(tag)] \(msg)")
        }
        XCTAssertNotNil(loaded.first { $0.id == "water" }?.handledCondition)
        XCTAssertEqual(loaded.first { $0.id == "water" }?.selfNoticeSignal, "wearer_placing_water_bottle_on_table")
        XCTAssertNil(loaded.first { $0.id == "hall-light" }?.handledCondition)
        XCTAssertEqual(logged, ["[NEEDS] needs-polarity-review hall-light"])
    }
}
