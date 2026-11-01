import Foundation
import XCTest
@testable import NoticerCore

/// App-owned list editing: the swap flow, the merge guard, and reply-text
/// hardening. A model answer is never a replacement list.
final class NeedListEditTests: XCTestCase {
    // MARK: - Fixtures

    private func need(
        _ id: String,
        _ authorText: String,
        priority: Int = 1,
        isUrgent: Bool = false
    ) -> Need {
        Need(
            id: id,
            authorText: authorText,
            cueWording: "Whisper for \(id).",
            visualCondition: "unmet \(id)",
            priority: priority,
            isUrgent: isUrgent
        )
    }

    private func sixNeeds() -> [Need] {
        [
            need("take-baby", "eating one-handed, take the baby", priority: 0),
            need("refill-water", "nursing, no water"),
            need("water", "water on the nightstand"),
            need("pick-roaming-kid", "pick up the roaming kid"),
            need("clean-floor-toys", "Help clean the toys from floor"),
            need("remove-empty-glasses", "Remove the empty glasses from the dinning table"),
        ]
    }

    private func draft(
        _ id: String,
        _ authorText: String,
        priority: NeedsIntentPriority = .normal,
        isUrgent: Bool = false
    ) -> NeedsIntentDraft {
        NeedsIntentDraft(
            id: id,
            authorText: authorText,
            whisper: "Whisper for \(id).",
            priority: priority,
            allowsCheckIn: false,
            visualCue: "unmet \(id)",
            isUrgent: isUrgent
        )
    }

    // MARK: - Routing

    func testFullListDetectsLimit() {
        XCTAssertTrue(NeedListEdit.isFull(sixNeeds()))
        XCTAssertFalse(NeedListEdit.isFull(Array(sixNeeds().prefix(5))))
    }

    func testEditMessagesRouteToModel() {
        for message in [
            "remove the water one",
            "delete the glasses",
            "drop toys",
            "make water higher priority",
            "change the baby one",
            "reword the mat",
            "pause water tonight",
            "resume the baby",
            "move toys to the top",
        ] {
            XCTAssertTrue(NeedListEdit.isEditMessage(message), message)
        }
    }

    func testFreshAddsAreNotEdits() {
        for message in [
            "Fold the mat if on the floor",
            "swap the water one",
            "water for the dog",
            "Keep all 6 and skip the mat for now",
            "bedroom",
        ] {
            XCTAssertFalse(NeedListEdit.isEditMessage(message), message)
        }
    }

    // MARK: - Swap question

    func testSwapQuestionCopy() {
        XCTAssertEqual(
            NeedListEdit.swapQuestion(newText: "Fold the mat if on the floor"),
            "You already have 6 needs — which one should I swap out for \"Fold the mat if on the floor\"?"
        )
        XCTAssertEqual(NeedListEdit.keepAllChip(), "Keep all 6")
    }

    func testSwapCandidatesListAllSix() {
        let candidates = NeedListEdit.swapCandidates(for: sixNeeds())
        XCTAssertEqual(candidates.map(\.id), sixNeeds().map(\.id))
        XCTAssertEqual(candidates.count, 6)
        XCTAssertFalse(candidates.map(\.shortName).contains { $0.isEmpty })
    }

    func testShortNamesAreStableSlugWords() {
        let names = Dictionary(
            uniqueKeysWithValues: NeedListEdit.swapCandidates(for: sixNeeds()).map { ($0.id, $0.shortName) }
        )
        XCTAssertEqual(names["take-baby"], "take baby")
        XCTAssertEqual(names["refill-water"], "refill water")
        XCTAssertEqual(names["remove-empty-glasses"], "remove empty glasses")
        XCTAssertEqual(names["clean-floor-toys"], "clean floor toys")
    }

    // MARK: - Naming

    func testSwapAnswerResolvesToTheRightNeed() {
        // One water need: "the water one" is unambiguous.
        let needs = [
            need("take-baby", "eating one-handed, take the baby"),
            need("refill-water", "nursing, no water"),
            need("pick-roaming-kid", "pick up the roaming kid"),
        ]
        XCTAssertEqual(
            NeedListEdit.resolveNamedNeed(message: "swap the water one", in: needs)?.id,
            "refill-water"
        )
        let six = sixNeeds()
        XCTAssertEqual(
            NeedListEdit.resolveNamedNeed(message: "swap out remove empty glasses", in: six)?.id,
            "remove-empty-glasses"
        )
        XCTAssertEqual(
            NeedListEdit.resolveNamedNeed(message: "the toys", in: six)?.id,
            "clean-floor-toys"
        )
        XCTAssertEqual(
            NeedListEdit.resolveNamedNeed(message: "swap the nursing one", in: six)?.id,
            "refill-water"
        )
    }

    func testAmbiguousAnswerResolvesToNothing() {
        // "water" matches refill-water and water: re-ask with chips instead.
        XCTAssertNil(NeedListEdit.resolveNamedNeed(message: "swap the water", in: sixNeeds()))
        XCTAssertNil(NeedListEdit.resolveNamedNeed(message: "swap it", in: sixNeeds()))
        XCTAssertNil(NeedListEdit.resolveNamedNeed(message: "", in: sixNeeds()))
    }

    func testVerbsNeverNameANeedAlone() {
        // "remove" appears in a saved need's words; the verb must not match it.
        XCTAssertFalse(NeedListEdit.namesNeed(
            message: "remove the water one",
            need: need("remove-empty-glasses", "Remove the empty glasses from the dinning table")
        ))
        XCTAssertTrue(NeedListEdit.namesNeed(
            message: "remove the water one",
            need: need("refill-water", "nursing, no water")
        ))
        XCTAssertFalse(NeedListEdit.namesNeed(
            message: "take the trash out",
            need: need("take-baby", "eating one-handed, take the baby")
        ))
    }

    func testKeepAllAnswers() {
        for message in [
            "Keep all 6",
            "Keep all 6 and skip the mat for now",
            "never mind",
            "cancel",
            "skip",
            "leave it",
            "don't add it",
        ] {
            XCTAssertTrue(NeedListEdit.isKeepAllAnswer(message), message)
        }
        XCTAssertFalse(NeedListEdit.isKeepAllAnswer("swap the water one"))
        XCTAssertFalse(NeedListEdit.isKeepAllAnswer("Fold the mat if on the floor"))
    }

    // MARK: - Swap application

    func testChoosingSwapsExactlyThatOne() {
        let current = sixNeeds()
        let mat = need("fold-mat", "Fold the mat if on the floor")
        let swapped = NeedListEdit.applySwap(current: current, removeID: "refill-water", newNeed: mat)
        XCTAssertEqual(swapped.map(\.id), [
            "take-baby", "fold-mat", "water", "pick-roaming-kid", "clean-floor-toys", "remove-empty-glasses",
        ])
        // The other five are byte-identical, in place.
        for id in ["take-baby", "water", "pick-roaming-kid", "clean-floor-toys", "remove-empty-glasses"] {
            guard let before = current.first(where: { $0.id == id }),
                  let after = swapped.first(where: { $0.id == id })
            else {
                return XCTFail("missing \(id)")
            }
            XCTAssertEqual(before, after)
            XCTAssertEqual(before.uiID, after.uiID)
        }
        XCTAssertEqual(swapped.firstIndex { $0.id == "fold-mat" }, 1)
    }

    func testSwapWithUnknownPickNeverDropsSavedNeeds() {
        let current = sixNeeds()
        let mat = need("fold-mat", "Fold the mat if on the floor")
        // Full + unknown pick: unchanged, the new need is dropped, nothing saved is lost.
        XCTAssertEqual(
            NeedListEdit.applySwap(current: current, removeID: "missing", newNeed: mat),
            current
        )
        let room = Array(current.prefix(5))
        XCTAssertEqual(
            NeedListEdit.applySwap(current: room, removeID: "missing", newNeed: mat).map(\.id),
            room.map(\.id) + ["fold-mat"]
        )
    }

    func testSwapReassignsCollidingNewID() {
        let current = sixNeeds()
        // The model echoed a kept id for the new need: fresh slug, no duplicate.
        let dupe = need("water", "Water for the plants")
        let swapped = NeedListEdit.applySwap(current: current, removeID: "refill-water", newNeed: dupe)
        XCTAssertEqual(swapped.map(\.id).count, Set(swapped.map(\.id)).count)
        let added = swapped.first { $0.authorText == "Water for the plants" }
        XCTAssertEqual(added?.id, "water-for-the-plants")
        XCTAssertNotNil(swapped.first { $0.id == "water" && $0.authorText == "water on the nightstand" })
    }

    // MARK: - Merge guard

    func testUnderLimitAddKeepsEverything() {
        let current = Array(sixNeeds().prefix(2))
        let drafts = [
            draft("take-baby", "eating one-handed, take the baby", priority: .important),
            draft("refill-water", "nursing, no water"),
            draft("fold-mat", "Fold the mat if on the floor"),
        ]
        let merged = NeedListEdit.merge(current: current, drafts: drafts, message: "Fold the mat if on the floor")
        XCTAssertEqual(merged.map(\.id), ["take-baby", "refill-water", "fold-mat"])
    }

    func testNamedRemovalStillWorks() {
        let current = [need("take-baby", "Take the baby"), need("refill-water", "nursing, no water")]
        let drafts = [draft("take-baby", "Take the baby")]
        let merged = NeedListEdit.merge(current: current, drafts: drafts, message: "remove the water one")
        XCTAssertEqual(merged.map(\.id), ["take-baby"])
    }

    func testMultipleNamedRemovalsWork() {
        let current = sixNeeds()
        let drafts = [
            draft("take-baby", "eating one-handed, take the baby"),
            draft("refill-water", "nursing, no water"),
            draft("water", "water on the nightstand"),
            draft("pick-roaming-kid", "pick up the roaming kid"),
        ]
        let merged = NeedListEdit.merge(
            current: current,
            drafts: drafts,
            message: "remove the toys and glasses"
        )
        XCTAssertEqual(merged.map(\.id), ["take-baby", "refill-water", "water", "pick-roaming-kid"])
    }

    func testUnnamedDropsAreKept() {
        // Regression for the 6 -> 4 bug: the model returned 4 needs that
        // left out toys and glasses and never added the mat. Nothing she
        // didn't choose leaves the list.
        let current = sixNeeds()
        let drafts = [
            draft("take-baby", "eating one-handed, take the baby", priority: .important),
            draft("refill-water", "nursing, no water"),
            draft("water", "water on the nightstand"),
            draft("pick-roaming-kid", "pick up the roaming kid"),
        ]
        let merged = NeedListEdit.merge(
            current: current,
            drafts: drafts,
            message: "Keep all 6 and skip the mat for now"
        )
        XCTAssertEqual(merged.map(\.id), current.map(\.id))
        for need in current {
            XCTAssertEqual(merged.first { $0.id == need.id }, need)
        }
    }

    func testExplicitRemovalWinsEvenIfDraftReadds() {
        let current = [need("take-baby", "Take the baby"), need("refill-water", "nursing, no water")]
        let drafts = [
            draft("take-baby", "Take the baby"),
            draft("refill-water", "nursing, no water"),
        ]
        let merged = NeedListEdit.merge(
            current: current,
            drafts: drafts,
            message: "Fold the mat if on the floor",
            explicitRemovals: ["refill-water"]
        )
        XCTAssertEqual(merged.map(\.id), ["take-baby"])
    }

    func testMergeNeverExceedsTheLimit() {
        let current = Array(sixNeeds().prefix(5))
        let drafts = current.map { draft($0.id, $0.authorText) } + [
            draft("fold-mat", "Fold the mat if on the floor"),
            draft("mop-floor", "Mop the floor"),
        ]
        let merged = NeedListEdit.merge(current: current, drafts: drafts, message: "fold the mat and mop")
        // All five saved survive; only one of the two new drafts fits.
        XCTAssertEqual(merged.count, 6)
        XCTAssertTrue(current.allSatisfy { saved in merged.contains { $0.id == saved.id } })
        XCTAssertEqual(merged.filter { $0.id == "fold-mat" }.count, 1)
        XCTAssertTrue(merged.allSatisfy { $0.id != "mop-floor" })
    }

    func testMergeDedupesByID() {
        let current = [need("take-baby", "Take the baby")]
        let drafts = [
            draft("take-baby", "Take the baby"),
            draft("take-baby", "Take the baby now"),
        ]
        let merged = NeedListEdit.merge(current: current, drafts: drafts, message: "baby")
        XCTAssertEqual(merged.map(\.id), ["take-baby"])
    }

    // MARK: - Reply text

    func testExtractPayloadFindsEmbeddedJSON() {
        XCTAssertEqual(
            NeedReplyText.extractPayload("Sure! {\"question\":\"Which one?\",\"suggestions\":[\"A\"]} Let me know."),
            "{\"question\":\"Which one?\",\"suggestions\":[\"A\"]}"
        )
        XCTAssertEqual(
            NeedReplyText.extractPayload("{\"question\":\"Which one?\"}"),
            "{\"question\":\"Which one?\"}"
        )
        // Braces inside strings don't end the scan early.
        XCTAssertEqual(
            NeedReplyText.extractPayload("Note: {\"text\":\"a } brace\"} done."),
            "{\"text\":\"a } brace\"}"
        )
        // Non-JSON braces still extract the span; looksLikeJSON sorts it
        // back to prose downstream.
        XCTAssertEqual(
            NeedReplyText.extractPayload("Use {brackets} here."),
            "{brackets}"
        )
    }

    func testLooksLikeJSON() {
        XCTAssertTrue(NeedReplyText.looksLikeJSON("{\"question\":\"Which one?\"}"))
        XCTAssertTrue(NeedReplyText.looksLikeJSON("Here: {\"a\":1} thanks."))
        XCTAssertTrue(NeedReplyText.looksLikeJSON("Broken: {\"question\": oops}"))
        XCTAssertTrue(NeedReplyText.looksLikeJSON("{\"question\": \"Which one\", \"suggestions\": [\"Swap out"))
        XCTAssertFalse(NeedReplyText.looksLikeJSON("Could you tell me a little more about bedtime?"))
        XCTAssertFalse(NeedReplyText.looksLikeJSON("Use {brackets} here."))
        XCTAssertFalse(NeedReplyText.looksLikeJSON("Count {1, 3} things."))
    }

    // MARK: - Priority persistence and engine visibility

    func testUrgentSurvivesCodableRoundTrip() throws {
        let urgent = need("take-baby", "Take the baby", isUrgent: true)
        let data = try JSONEncoder().encode([urgent])
        let decoded = try JSONDecoder().decode([Need].self, from: data)
        XCTAssertEqual(decoded.first?.isUrgent, true)
    }

    func testUrgentNeedGetsZeroHeadStart() {
        XCTAssertEqual(
            MasteryMath.headStartSeconds(for: need("take-baby", "Take the baby", isUrgent: true)),
            0
        )
        XCTAssertGreaterThan(
            MasteryMath.headStartSeconds(for: need("take-baby", "Take the baby")),
            0
        )
    }
}
