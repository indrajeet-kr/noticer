import Foundation
import NoticerCore
import XCTest

/// Read-back staleness: list changes outside the chat supersede pending
/// read-backs, accept refuses them, and the seeded sheet entry rebuilds
/// from the screen's list.
final class NeedsIntentServiceTests: XCTestCase {
    private var stashedNeeds: Data?
    private var stashedPaused: Data?

    override func setUp() {
        super.setUp()
        stashedNeeds = UserDefaults.standard.data(forKey: "noticer.needs.v1")
        stashedPaused = UserDefaults.standard.data(forKey: "noticer.pausedNeeds.v1")
    }

    override func tearDown() {
        if let stashedNeeds {
            UserDefaults.standard.set(stashedNeeds, forKey: "noticer.needs.v1")
        } else {
            UserDefaults.standard.removeObject(forKey: "noticer.needs.v1")
        }
        if let stashedPaused {
            UserDefaults.standard.set(stashedPaused, forKey: "noticer.pausedNeeds.v1")
        } else {
            UserDefaults.standard.removeObject(forKey: "noticer.pausedNeeds.v1")
        }
        super.tearDown()
    }

    private func stubNeeds() -> [Need] {
        [
            Need(id: "take-baby", authorText: "take the baby", cueWording: "Take the baby?", priority: 0),
            Need(id: "refill-water", authorText: "nursing, no water", cueWording: "Her water's empty.", priority: 1),
        ]
    }

    @MainActor
    private func seededModel() -> PhoneSessionModel {
        let model = PhoneSessionModel()
        model.needs = stubNeeds()
        model.intentService.seedIfNeeded(from: model)
        return model
    }

    @MainActor
    private func appendPending(to service: NeedsIntentService, model: PhoneSessionModel) -> UUID {
        let id = UUID()
        service.entries.append(.readBack(
            id: id,
            drafts: NeedsIntentConversion.fromNeeds(model.needs),
            readBack: "Both things.",
            changed: [],
            accepted: false,
            superseded: false
        ))
        return id
    }

    @MainActor
    func testRemoveThenAcceptOldReadBackIsRejected() {
        let model = seededModel()
        let service = model.intentService
        let pending = appendPending(to: service, model: model)

        service.removeSavedNeed(id: "take-baby", model: model)
        XCTAssertEqual(model.needs.map(\.id), ["refill-water"])

        guard case .readBack(_, _, _, _, false, true) = service.entries.first(where: { $0.id == pending }) else {
            return XCTFail("the pending read-back should be superseded after the removal")
        }
        service.accept(entryID: pending, model: model)
        XCTAssertEqual(
            model.needs.map(\.id), ["refill-water"],
            "accepting a superseded entry must not resurrect the removed need"
        )
    }

    @MainActor
    func testSeededEntryRebuiltAfterRemoval() {
        let model = seededModel()
        let service = model.intentService

        service.removeSavedNeed(id: "take-baby", model: model)
        service.refreshSheetList(from: model)

        guard let seed = service.seededEntryID,
              case .readBack(_, let drafts, _, _, true, false) = service.entries.first(where: { $0.id == seed })
        else {
            return XCTFail("the seeded entry should still be the live accepted list")
        }
        XCTAssertEqual(drafts.map(\.id), model.needs.map(\.id))
        XCTAssertEqual(drafts.map(\.id), ["refill-water"])
    }

    @MainActor
    func testAcceptSupersedesOtherPendings() {
        let model = seededModel()
        let service = model.intentService
        let first = appendPending(to: service, model: model)
        let second = appendPending(to: service, model: model)

        service.accept(entryID: first, model: model)

        guard case .readBack(_, _, _, _, false, true) = service.entries.first(where: { $0.id == second }) else {
            return XCTFail("accepting one entry should supersede the other pending entry")
        }
    }

    @MainActor
    func testPauseSupersedesPendings() {
        let model = seededModel()
        let service = model.intentService
        let pending = appendPending(to: service, model: model)

        model.setPaused("take-baby", paused: true)

        guard case .readBack(_, _, _, _, false, true) = service.entries.first(where: { $0.id == pending }) else {
            return XCTFail("pausing should supersede pending read-backs")
        }
    }

    @MainActor
    func testUndoSupersedesPendings() {
        let model = seededModel()
        let service = model.intentService
        service.removeSavedNeed(id: "take-baby", model: model)
        let pending = appendPending(to: service, model: model)

        service.undoRemove(model: model)

        XCTAssertEqual(model.needs.map(\.id), ["take-baby", "refill-water"])
        guard case .readBack(_, _, _, _, false, true) = service.entries.first(where: { $0.id == pending }) else {
            return XCTFail("undo should supersede pending read-backs")
        }
    }
}
