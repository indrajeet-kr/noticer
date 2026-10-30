import Foundation
import XCTest
@testable import NoticerCore

final class NeedEditorIdentityTests: XCTestCase {
    func testSavedListWithoutARowIdentityStillLoads() throws {
        let json = """
        [{
          "id": "take-baby",
          "author_text": "eating one-handed, take the baby",
          "cue_wording": "Her plate's getting cold, maybe take the baby?",
          "priority": 0,
          "allows_check_in": false,
          "mastery": { "score": 0, "consecutive_self_notices": 0, "consecutive_misses": 0 }
        }]
        """
        let needs = try JSONDecoder().decode([Need].self, from: Data(json.utf8))
        XCTAssertEqual(needs.map(\.id), ["take-baby"])
        XCTAssertEqual(needs[0].authorText, "eating one-handed, take the baby")

        let again = try JSONDecoder().decode([Need].self, from: Data(json.utf8))
        XCTAssertEqual(needs, again)
    }

    func testASavedRowIdentityRoundTrips() throws {
        let uiID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let need = Need(
            id: "take-baby",
            authorText: "take the baby",
            cueWording: "whisper",
            priority: 0,
            uiID: uiID
        )
        let data = try JSONEncoder().encode([need])
        let loaded = try JSONDecoder().decode([Need].self, from: data)
        XCTAssertEqual(loaded[0].id, "take-baby")
        XCTAssertEqual(loaded[0].uiID, uiID)
        XCTAssertEqual(loaded, [need])
    }

    func testRenamingKeepsTheRowAndRemovingItByThatIdentitySucceeds() {
        let fresh = UUID().uuidString
        var needs = [
            Need(id: fresh, authorText: "Take the baby", cueWording: "", priority: 0),
            Need(id: "refill-water", authorText: "water", cueWording: "Her water's empty.", priority: 1),
        ]
        let uiID = needs[0].uiID
        let other = needs[1].uiID

        XCTAssertTrue(NeedListEditing.nameNeed(&needs, uiID: uiID))
        XCTAssertEqual(needs[0].id, "take-the-baby")
        XCTAssertEqual(needs[0].uiID, uiID)
        XCTAssertEqual(needs[1].uiID, other)
        XCTAssertEqual(needs[1].id, "refill-water")

        XCTAssertTrue(NeedListEditing.delete(&needs, uiID: uiID))
        XCTAssertEqual(needs.map(\.uiID), [other])
        XCTAssertFalse(NeedListEditing.nameNeed(&needs, uiID: uiID))
        XCTAssertFalse(NeedListEditing.delete(&needs, uiID: uiID))
        XCTAssertEqual(needs.map(\.id), ["refill-water"])
    }

    func testRemovingBeforeTheRenameLeavesTheSlugUntouched() {
        var needs = [
            Need(id: UUID().uuidString, authorText: "Take the baby", cueWording: "", priority: 0)
        ]
        let uiID = needs[0].uiID
        XCTAssertTrue(NeedListEditing.delete(&needs, uiID: uiID))
        XCTAssertFalse(NeedListEditing.nameNeed(&needs, uiID: uiID))
        XCTAssertTrue(needs.isEmpty)
    }

    func testASlugIsNotRewrittenWhenSheLeavesTheCardAgain() {
        var needs = [
            Need(id: "take-baby", authorText: "something else entirely", cueWording: "", priority: 0)
        ]
        XCTAssertFalse(NeedListEditing.nameNeed(&needs, uiID: needs[0].uiID))
        XCTAssertEqual(needs[0].id, "take-baby")
    }

    func testReadableIDsAvoidOnesAlreadyOnTheList() {
        let first = NeedListEditing.readableID(from: "Take the baby!", avoiding: [])
        XCTAssertEqual(first, "take-the-baby")
        let second = NeedListEditing.readableID(from: "Take the baby", avoiding: ["take-the-baby"])
        XCTAssertEqual(second, "take-the-baby-2")
        XCTAssertNil(NeedListEditing.readableID(from: "   ", avoiding: []))
    }
}
