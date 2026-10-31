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
    }
}
