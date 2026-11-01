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

    // MARK: - Swap flow (full list)

    private func sixStubNeeds() -> [Need] {
        [
            Need(id: "take-baby", authorText: "eating one-handed, take the baby", cueWording: "Take the baby?", priority: 0),
            Need(id: "refill-water", authorText: "nursing, no water", cueWording: "Her water's empty.", priority: 1),
            Need(id: "water", authorText: "water on the nightstand", cueWording: "Water?", priority: 1),
            Need(id: "pick-roaming-kid", authorText: "pick up the roaming kid", cueWording: "Kid?", priority: 1),
            Need(id: "clean-floor-toys", authorText: "Help clean the toys from floor", cueWording: "Toys?", priority: 1),
            Need(id: "remove-empty-glasses", authorText: "Remove the empty glasses from the dinning table", cueWording: "Glasses?", priority: 1),
        ]
    }

    @MainActor
    private func fullModel() -> PhoneSessionModel {
        let model = PhoneSessionModel()
        model.needs = sixStubNeeds()
        return model
    }

    private func stubDraft(
        _ id: String,
        _ authorText: String,
        priority: NeedsIntentPriority = .normal
    ) -> NeedsIntentDraft {
        NeedsIntentDraft(
            id: id,
            authorText: authorText,
            whisper: "Whisper \(id).",
            priority: priority,
            allowsCheckIn: false,
            visualCue: "unmet \(id)"
        )
    }

    @MainActor
    func testRouteMatrix() {
        XCTAssertEqual(
            NeedsIntentService.route(message: "Fold the mat", needsCount: 6, pendingSwap: false, lastEntryIsOpenQuestion: false),
            .swapQuestion
        )
        XCTAssertEqual(
            NeedsIntentService.route(message: "remove the water one", needsCount: 6, pendingSwap: false, lastEntryIsOpenQuestion: false),
            .model
        )
        XCTAssertEqual(
            NeedsIntentService.route(message: "Water", needsCount: 6, pendingSwap: false, lastEntryIsOpenQuestion: true),
            .model
        )
        XCTAssertEqual(
            NeedsIntentService.route(message: "anything", needsCount: 6, pendingSwap: true, lastEntryIsOpenQuestion: false),
            .swapAnswer
        )
        XCTAssertEqual(
            NeedsIntentService.route(message: "Fold the mat", needsCount: 2, pendingSwap: false, lastEntryIsOpenQuestion: false),
            .model
        )
    }

    @MainActor
    func testSendOnFullListAsksSwapAndAddsNothing() {
        let model = fullModel()
        let service = model.intentService
        service.send("Fold the mat if on the floor", model: model)

        XCTAssertFalse(service.thinking)
        XCTAssertEqual(model.needs.map(\.id), sixStubNeeds().map(\.id))
        XCTAssertEqual(service.pendingSwapText, "Fold the mat if on the floor")
        guard case .swapQuestion(_, let text, let newText, let candidates) = service.entries.last else {
            return XCTFail("expected a swap question, got \(String(describing: service.entries.last))")
        }
        XCTAssertEqual(
            text,
            "You already have 6 needs — which one should I swap out for \"Fold the mat if on the floor\"?"
        )
        XCTAssertEqual(newText, "Fold the mat if on the floor")
        XCTAssertEqual(candidates.map(\.id), sixStubNeeds().map(\.id))
    }

    @MainActor
    func testChooseSwapRecordsExplicitPick() {
        let model = fullModel()
        let service = model.intentService
        service.interpretHook = { _, _ in throw CancellationError() }
        service.send("Fold the mat if on the floor", model: model)

        service.chooseSwap(candidateID: "refill-water", model: model)

        XCTAssertEqual(service.pendingExplicitRemovals, ["refill-water"])
        guard case .her(_, let text) = service.entries.last else {
            return XCTFail("expected her pick last")
        }
        XCTAssertEqual(text, "Swap out refill water")
    }

    @MainActor
    func testApplyStructuredSwapSwapsInPlace() {
        let model = fullModel()
        let service = model.intentService
        service.showSwapQuestion(newText: "Fold the mat if on the floor", model: model)

        service.applyStructuredSwap(
            drafts: [stubDraft("fold-mat", "Fold the mat if on the floor")],
            pickID: "refill-water",
            model: model
        )

        XCTAssertNil(service.pendingSwapText)
        XCTAssertTrue(service.pendingExplicitRemovals.isEmpty)
        guard case .readBack(_, let drafts, let readBack, let changed, false, false) = service.entries.last else {
            return XCTFail("expected a pending read-back, got \(String(describing: service.entries.last))")
        }
        XCTAssertEqual(
            drafts.map(\.id),
            ["take-baby", "fold-mat", "water", "pick-roaming-kid", "clean-floor-toys", "remove-empty-glasses"]
        )
        XCTAssertEqual(readBack, "Swapped “nursing, no water” for “Fold the mat if on the floor”.")
        XCTAssertEqual(changed, ["fold-mat"])
        // The saved list is untouched until Looks right.
        XCTAssertEqual(model.needs.map(\.id), sixStubNeeds().map(\.id))
    }

    @MainActor
    func testKeepAllLeavesListUnchanged() {
        let model = fullModel()
        let service = model.intentService
        service.showSwapQuestion(newText: "Fold the mat if on the floor", model: model)

        service.keepAll(model: model)

        XCTAssertNil(service.pendingSwapText)
        XCTAssertEqual(model.needs.map(\.id), sixStubNeeds().map(\.id))
        guard case .question(_, let text, let suggestions) = service.entries.last else {
            return XCTFail("expected a confirmation, got \(String(describing: service.entries.last))")
        }
        XCTAssertEqual(text, "Kept all 6 — nothing changed.")
        XCTAssertTrue(suggestions.isEmpty)
    }

    @MainActor
    func testTypedKeepAllBacksOut() {
        let model = fullModel()
        let service = model.intentService
        service.showSwapQuestion(newText: "Fold the mat if on the floor", model: model)

        service.handleSwapAnswer("never mind", model: model)

        XCTAssertNil(service.pendingSwapText)
        XCTAssertEqual(model.needs.map(\.id), sixStubNeeds().map(\.id))
        guard case .question(_, let text, _) = service.entries.last else {
            return XCTFail("expected a confirmation, got \(String(describing: service.entries.last))")
        }
        XCTAssertEqual(text, "Kept all 6 — nothing changed.")
    }

    @MainActor
    func testTypedSwapAnswerConfirmsNamedPick() {
        let model = fullModel()
        let service = model.intentService
        service.interpretHook = { _, _ in throw CancellationError() }
        service.showSwapQuestion(newText: "Fold the mat if on the floor", model: model)

        service.handleSwapAnswer("swap the nursing one", model: model)

        XCTAssertEqual(service.pendingExplicitRemovals, ["refill-water"])
    }

    @MainActor
    func testUnmatchedSwapAnswerReasks() {
        let model = fullModel()
        let service = model.intentService
        service.showSwapQuestion(newText: "Fold the mat if on the floor", model: model)

        service.handleSwapAnswer("swap it", model: model)

        XCTAssertEqual(service.pendingSwapText, "Fold the mat if on the floor")
        guard case .swapQuestion(_, let text, _, let candidates) = service.entries.last else {
            return XCTFail("expected a re-ask, got \(String(describing: service.entries.last))")
        }
        XCTAssertTrue(text.hasPrefix("Which one did you mean"), text)
        XCTAssertEqual(candidates.count, 6)
    }

    @MainActor
    func testNeedsEntryActionConvertsOverCapacityToSwap() {
        let current = sixStubNeeds()
        let drafts = current.map { stubDraft($0.id, $0.authorText) }
            + [stubDraft("fold-mat", "Fold the mat if on the floor")]
        let action = NeedsIntentService.needsEntryAction(
            drafts: drafts,
            message: "Fold the mat if on the floor",
            current: current,
            explicit: []
        )
        XCTAssertEqual(action, .swap("Fold the mat if on the floor"))
    }

    @MainActor
    func testNeedsEntryActionGuardsSilentDrops() {
        let current = sixStubNeeds()
        let drafts = [
            stubDraft("take-baby", "eating one-handed, take the baby", priority: .important),
            stubDraft("refill-water", "nursing, no water"),
            stubDraft("water", "water on the nightstand"),
            stubDraft("pick-roaming-kid", "pick up the roaming kid"),
        ]
        let action = NeedsIntentService.needsEntryAction(
            drafts: drafts,
            message: "Keep all 6 and skip the mat for now",
            current: current,
            explicit: []
        )
        guard case .readBack(let guarded) = action else {
            return XCTFail("expected a guarded read-back, got \(action)")
        }
        XCTAssertEqual(guarded.map(\.id), current.map(\.id))
    }

    @MainActor
    func testInterpretMergesThroughHook() async {
        let model = fullModel()
        let service = model.intentService
        service.interpretHook = { _, _ in
            .needs(
                [
                    self.stubDraft("take-baby", "eating one-handed, take the baby", priority: .important),
                    self.stubDraft("refill-water", "nursing, no water"),
                ],
                readBack: "Trimmed."
            )
        }

        await service.interpret(message: "something", model: model)

        guard case .readBack(_, let drafts, _, _, false, false) = service.entries.last else {
            return XCTFail("expected a read-back, got \(String(describing: service.entries.last))")
        }
        // The model dropped four needs nobody named: all six stay.
        XCTAssertEqual(drafts.map(\.id), sixStubNeeds().map(\.id))
    }
}
