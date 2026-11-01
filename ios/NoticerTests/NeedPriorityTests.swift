import Foundation
import NoticerCore
import XCTest

/// Priority toggle: writes the same `isUrgent` flag the engine reads,
/// persists through the store, and zeroes the displayed head start.
final class NeedPriorityTests: XCTestCase {
    private var stashedNeeds: Data?

    override func setUp() {
        super.setUp()
        stashedNeeds = UserDefaults.standard.data(forKey: "noticer.needs.v1")
    }

    override func tearDown() {
        if let stashedNeeds {
            UserDefaults.standard.set(stashedNeeds, forKey: "noticer.needs.v1")
        } else {
            UserDefaults.standard.removeObject(forKey: "noticer.needs.v1")
        }
        super.tearDown()
    }

    @MainActor
    func testSetUrgentPersistsAndZeroesHeadStart() {
        let model = PhoneSessionModel()
        model.needs = [
            Need(id: "take-baby", authorText: "eating one-handed, take the baby", cueWording: "Take the baby?", priority: 1),
        ]
        XCTAssertGreaterThan(model.displayHeadStart(for: model.needs[0]), 0)

        model.setUrgent("take-baby", urgent: true)

        XCTAssertTrue(model.needs.first?.isUrgent == true)
        XCTAssertEqual(model.displayHeadStart(for: model.needs[0]), 0)
        let reloaded = NeedListStore.load()
        XCTAssertTrue(reloaded.first { $0.id == "take-baby" }?.isUrgent == true)

        model.setUrgent("take-baby", urgent: false)

        XCTAssertFalse(model.needs.first?.isUrgent == true)
        XCTAssertGreaterThan(model.displayHeadStart(for: model.needs[0]), 0)
        XCTAssertFalse(NeedListStore.load().first { $0.id == "take-baby" }?.isUrgent == true)
    }

    @MainActor
    func testSetUrgentIgnoresUnknownID() {
        let model = PhoneSessionModel()
        model.needs = [
            Need(id: "take-baby", authorText: "take the baby", cueWording: "Take the baby?", priority: 1),
        ]
        model.setUrgent("missing", urgent: true)
        XCTAssertFalse(model.needs.first?.isUrgent == true)
    }
}
