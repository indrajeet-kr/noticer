import XCTest
@testable import NoticerCore

/// Compound chores keep the whole chore: a latch fires on any visible
/// unmet part, but resolution and credit need every part handled. One
/// part fixed is `stillOpen partial`, not complete.
final class CompoundNeedTests: EngineTestCase {
    private func trashCan() -> Need {
        Need(
            id: "trash-can-lid",
            authorText: "Close the lid of trash can and move it to the corner",
            cueWording: "Lid's open?",
            visualCondition: "lid visibly open, OR can visibly outside the designated corner",
            handledCondition: "lid closed AND can in the designated corner",
            unknownCondition: "placement cannot be judged when the corner is out of view",
            selfNoticeSignal: "wearer_closing_trash_lid",
            priority: 0
        )
    }

    private func setupTrashCan() throws {
        try engine.setNeeds([trashCan(), Self.refillWater()])
    }

    private func nextLatchCall() throws -> PendingModelCall {
        advance(SessionLimits.latchMinIntervalSeconds + 1)
        see([mom()], handsEdge: true)
        return try XCTUnwrap(engine.pendingModelCall)
    }

    // MARK: - Part matching

    func testPartSplittingAndWordMatching() {
        XCTAssertTrue(CompoundParts.isCompound(trashCan()))
        XCTAssertFalse(CompoundParts.isCompound(Self.takeBaby()))
        XCTAssertEqual(
            CompoundParts.unmetParts("lid visibly open, OR can visibly outside the designated corner"),
            ["lid visibly open", "can visibly outside the designated corner"]
        )
        XCTAssertEqual(
            CompoundParts.handledParts("lid closed AND can in the designated corner"),
            ["lid closed", "can in the designated corner"]
        )
        XCTAssertEqual(CompoundParts.handledParts("lid closed"), ["lid closed"])
        // "or" inside a word never splits.
        XCTAssertEqual(CompoundParts.unmetParts("corner dark"), ["corner dark"])
    }

    func testAllHandledMatrix() {
        let need = trashCan()
        XCTAssertFalse(CompoundParts.allHandled(need: need, tokens: nil))
        XCTAssertFalse(CompoundParts.allHandled(need: need, tokens: []))
        XCTAssertFalse(CompoundParts.allHandled(need: need, tokens: ["lid_open", "placement_unknown"]))
        XCTAssertFalse(CompoundParts.allHandled(need: need, tokens: ["lid_closed", "placement_unknown"]))
        XCTAssertFalse(CompoundParts.allHandled(need: need, tokens: ["lid_closed"]))
        XCTAssertFalse(CompoundParts.allHandled(need: need, tokens: ["lid_closed", "lid_open"]))
        XCTAssertTrue(CompoundParts.allHandled(need: need, tokens: ["lid_closed", "can_in_corner"]))
        XCTAssertTrue(CompoundParts.allHandled(need: Self.takeBaby(), tokens: nil), "single needs always pass")
    }

    func testRecompileOffer() {
        var stale = trashCan()
        stale.unknownCondition = nil
        stale.handledCondition = "lid closed"
        XCTAssertEqual(
            CompoundParts.recompileOffer(for: stale),
            "I can watch both parts of this: close the lid of trash can and move it to the corner. Update it?"
        )
        XCTAssertNil(CompoundParts.recompileOffer(for: trashCan()), "already compound")
        XCTAssertNil(CompoundParts.recompileOffer(for: Self.takeBaby()), "single request")
        var uncompiled = stale
        uncompiled.visualCondition = nil
        XCTAssertNil(CompoundParts.recompileOffer(for: uncompiled), "nothing compiled yet")
    }

    // MARK: - Latch and resolution

    func testLatchFiresOnAnyVisibleUnmetPart() throws {
        try setupTrashCan()
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(
            callID: latch.id,
            verdict: partLatchVerdict(
                "trash-can-lid",
                sustained: true,
                confidence: 0.8,
                evidence: ["lid_open", "placement_unknown"]
            )
        )

        XCTAssertEqual(engine.openNeedIDs, ["trash-can-lid"])
        XCTAssertTrue(events(.stillOpen).isEmpty)
    }

    func testOnePartFixedIsStillOpenPartial() throws {
        try setupTrashCan()
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: partLatchVerdict("trash-can-lid"))
        XCTAssertEqual(engine.openNeedIDs, ["trash-can-lid"])

        let heartbeat = try nextLatchCall()
        engine.handle(
            callID: heartbeat.id,
            verdict: resolvedVerdict(tokens: ["lid_closed", "placement_unknown"])
        )

        XCTAssertEqual(engine.openNeedIDs, ["trash-can-lid"], "one part fixed is not complete")
        XCTAssertEqual(events(.stillOpen).last?.detail, "partial")
        XCTAssertEqual(mastery(of: "trash-can-lid"), .initial, "no credit for a partial fix")
        XCTAssertTrue(events(.caughtHimself).isEmpty)
    }

    func testEveryPartHandledResolves() throws {
        try setupTrashCan()
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: partLatchVerdict("trash-can-lid"))
        let before = mastery(of: "trash-can-lid")

        let heartbeat = try nextLatchCall()
        engine.handle(
            callID: heartbeat.id,
            verdict: resolvedVerdict(tokens: ["lid_closed", "can_in_corner"])
        )

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.caughtHimself).map(\.needID), ["trash-can-lid"])
        XCTAssertEqual(mastery(of: "trash-can-lid"), MasteryMath.applySelfNotice(before))
    }

    func testUnpromptedCompletionNeedsEveryPart() throws {
        try setupTrashCan()
        glancePair()

        let start = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(
            callID: start.id,
            verdict: intervention("trash-can-lid", action: "wearer_closing_trash_lid")
        )
        XCTAssertEqual(events(.unpromptedStarted).map(\.needID), ["trash-can-lid"])

        let partial = try nextLatchCall()
        engine.handle(
            callID: partial.id,
            verdict: resolvedVerdict(tokens: ["lid_closed", "placement_unknown"])
        )
        XCTAssertTrue(events(.selfNoticedUnprompted).isEmpty, "partial completion credits nothing")
        XCTAssertEqual(events(.stillOpen).last?.detail, "partial")

        // The start stays armed: a full report still completes it.
        let full = try nextLatchCall()
        engine.handle(
            callID: full.id,
            verdict: resolvedVerdict(tokens: ["lid_closed", "can_in_corner"])
        )
        XCTAssertEqual(events(.selfNoticedUnprompted).map(\.needID), ["trash-can-lid"])
    }

    // MARK: - Conversion

    func testUnknownVisualRoundTripsThroughConversion() {
        let draft = NeedsIntentDraft(
            id: "trash-can-lid",
            authorText: "Close the lid of trash can and move it to the corner",
            whisper: "Lid's open?",
            priority: .normal,
            allowsCheckIn: false,
            visualCue: "lid visibly open, OR can visibly outside the designated corner",
            handledVisual: "lid closed AND can in the designated corner",
            unknownVisual: "placement cannot be judged when the corner is out of view",
            wearerSignal: "wearer_closing_trash_lid"
        )
        let converted = NeedsIntentConversion.toNeeds([draft], current: [])
        XCTAssertEqual(converted.first?.unknownCondition, draft.unknownVisual)
        XCTAssertTrue(converted.first.map(CompoundParts.isCompound) ?? false)

        let back = NeedsIntentConversion.fromNeeds(converted)
        XCTAssertEqual(back.first?.unknownVisual, draft.unknownVisual)

        let json = NeedsIntentConversion.currentListJSON(converted)
        XCTAssertTrue(json.contains("unknown_visual"))
    }

    // MARK: - Helpers

    private func partLatchVerdict(
        _ id: String,
        sustained: Bool = true,
        confidence: Double? = 0.2,
        evidence: [String]? = nil
    ) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: id,
                sustainedAcrossStrip: sustained,
                partnerStateEvidence: evidence ?? ["lid_open"],
                wearerHandsOccupied: false,
                confidence: confidence
            )
        )
    }

    private func resolvedVerdict(tokens: [String]) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNeedResolved,
            assessment: SceneAssessment(
                needID: "trash-can-lid",
                sustainedAcrossStrip: false,
                partnerStateEvidence: tokens,
                wearerHandsOccupied: false,
                resolution: .caughtHimself,
                actionCode: "wearer_closing_trash_lid",
                confidence: 0.85
            )
        )
    }
}
