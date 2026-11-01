import XCTest
@testable import NoticerCore

/// A confirm needs a new, distinct observation: only a cited new frame
/// with an unmet anchor latches. Bounded retries inside 3 attempts / 8 s,
/// sharpness preferred but never required, one clearing place.
final class ConfirmEvidenceTests: EngineTestCase {
    private func hypothesis(evidence: [String]? = nil, confidence: Double? = 0.8) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: "take-baby",
                sustainedAcrossStrip: false,
                partnerStateEvidence: ["lid_open"],
                wearerHandsOccupied: false,
                confidence: confidence,
                evidenceKeyframeIDs: evidence
            )
        )
    }

    private func confirmReply(
        evidence: [String]?,
        anchor: AnchorState?,
        tool: ToolName = .latchNeedHypothesis
    ) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: tool,
            assessment: SceneAssessment(
                needID: "take-baby",
                wearerHandsOccupied: false,
                confidence: 0.8,
                evidenceKeyframeIDs: evidence,
                newestAnchorState: anchor
            )
        )
    }

    /// glancePair, answer the latch call with a hypothesis, return the call.
    @discardableResult
    private func startSighting(evidence: [String]? = nil) throws -> PendingModelCall {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: hypothesis(evidence: evidence))
        XCTAssertEqual(events(.confirmScheduled).map(\.needID), ["take-baby"])
        return latch
    }

    /// Advance past the 1.5 s due time with a fresh glance, return the confirm.
    private func issueNextConfirm() throws -> PendingModelCall {
        advance(EngineTuning.confirmDelaySeconds + 1)
        see([mom()])
        let confirm = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(confirm.purpose, .confirm)
        return confirm
    }

    private func stripNewestID(_ call: PendingModelCall) -> String {
        call.request.keyframes.max(by: { $0.capturedAt < $1.capturedAt })!.id
    }

    // MARK: - Reading the reply

    func testOldSourceEvidenceNeverConfirms() throws {
        let latch = try startSighting()
        let sourceID = stripNewestID(latch)
        let first = try issueNextConfirm()
        let firstNewID = try XCTUnwrap(
            first.request.keyframes.map(\.id).first { $0 != sourceID }
        )

        engine.handle(callID: first.id, verdict: confirmReply(evidence: [sourceID], anchor: .unmet))

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.confirmSelfOnly).map(\.needID), ["take-baby"])
        XCTAssertEqual(
            events(.confirmRetry).map(\.detail),
            ["attempt=2 reason=self-only"]
        )

        // The retry sends a different new frame; the first one never repeats.
        let second = try issueNextConfirm()
        let secondIDs = second.request.keyframes.map(\.id)
        XCTAssertTrue(secondIDs.contains(sourceID))
        XCTAssertFalse(secondIDs.contains(firstNewID))
        XCTAssertEqual(secondIDs.count, 2)
    }

    func testCitedNewFrameWithUnmetAnchorLatches() throws {
        try startSighting()
        let confirm = try issueNextConfirm()
        let newID = stripNewestID(confirm)

        engine.handle(callID: confirm.id, verdict: confirmReply(evidence: [newID], anchor: .unmet))

        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertEqual(events(.needLatched).map(\.needID), ["take-baby"])
        XCTAssertTrue(events(.confirmRetry).isEmpty)
        XCTAssertEqual(events(.confirmEnded).map(\.detail), ["outcome=latched"])

        // The sighting is gone: no confirm resurfaces afterwards.
        advance(EngineTuning.confirmDelaySeconds + 1)
        see([mom()])
        XCTAssertFalse(engine.pendingModelCalls.contains { $0.purpose == .confirm })
        XCTAssertEqual(events(.confirmEnded).count, 1)
    }

    func testHandledInNewFrameBeatsOlderUnmetEvidence() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: latch.id, verdict: hypothesis(evidence: [stripNewestID(latch)]))
        XCTAssertEqual(events(.confirmScheduled).map(\.needID), ["take-baby"])
        let confirm = try issueNextConfirm()
        let sourceID = try XCTUnwrap(
            confirm.request.keyframes.map(\.id).first { $0 != stripNewestID(confirm) }
        )

        engine.handle(callID: confirm.id, verdict: confirmReply(evidence: [sourceID], anchor: .handled))

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(
            events(.confirmCleared).map { "\($0.needID ?? "?") \($0.detail ?? "")" },
            ["take-baby reason=handled"]
        )
        XCTAssertEqual(events(.confirmEnded).map(\.detail), ["outcome=cleared"])
        XCTAssertTrue(events(.confirmRetry).isEmpty)

        advance(EngineTuning.confirmDelaySeconds + 1)
        see([mom()])
        XCTAssertFalse(engine.pendingModelCalls.contains { $0.purpose == .confirm })
    }

    func testNotVisibleRetriesWithADifferentFrame() throws {
        let latch = try startSighting()
        let sourceID = stripNewestID(latch)
        let first = try issueNextConfirm()
        let firstNewID = try XCTUnwrap(
            first.request.keyframes.map(\.id).first { $0 != sourceID }
        )

        engine.handle(callID: first.id, verdict: confirmReply(evidence: [sourceID], anchor: .notVisible))

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertTrue(events(.confirmSelfOnly).isEmpty)
        XCTAssertEqual(
            events(.confirmRetry).map(\.detail),
            ["attempt=2 reason=not-visible"]
        )

        let second = try issueNextConfirm()
        let secondIDs = second.request.keyframes.map(\.id)
        XCTAssertTrue(secondIDs.contains(sourceID))
        XCTAssertFalse(
            secondIDs.contains(firstNewID),
            "no frame id is reused across attempts"
        )
    }

    func testNoTransitionConfirmReplyReadsTheSame() throws {
        try startSighting()
        let confirm = try issueNextConfirm()
        let newID = stripNewestID(confirm)

        engine.handle(
            callID: confirm.id,
            verdict: confirmReply(evidence: [newID], anchor: .unmet, tool: .reportNoTransition)
        )

        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertEqual(events(.confirmEnded).map(\.detail), ["outcome=latched"])
    }

    // MARK: - Bounds

    func testThreeAttemptsExhausts() throws {
        try startSighting()
        XCTAssertEqual(engine.modelCallsIssued, 1)

        var issuedIDs: [String] = []
        for _ in 1...EngineTuning.confirmMaxAttempts {
            let confirm = try issueNextConfirm()
            issuedIDs.append(stripNewestID(confirm))
            engine.handle(callID: confirm.id, verdict: confirmReply(evidence: [], anchor: .unclear))
        }

        XCTAssertEqual(Set(issuedIDs).count, EngineTuning.confirmMaxAttempts, "every attempt sends a new frame")
        XCTAssertEqual(engine.modelCallsIssued, 1 + EngineTuning.confirmMaxAttempts, "every attempt spends budget")
        XCTAssertEqual(
            events(.confirmRetry).map(\.detail),
            ["attempt=2 reason=unclear", "attempt=3 reason=unclear"]
        )
        XCTAssertEqual(events(.confirmEnded).map(\.detail), ["outcome=exhausted"])

        // No fourth attempt: later ticks never issue another confirm.
        advance(EngineTuning.confirmDelaySeconds + 1)
        see([mom()])
        XCTAssertFalse(engine.pendingModelCalls.contains { $0.purpose == .confirm })
    }

    func testEightSecondsExpires() throws {
        try startSighting()
        let first = try issueNextConfirm()
        engine.handle(callID: first.id, verdict: confirmReply(evidence: [], anchor: .unclear))
        XCTAssertEqual(events(.confirmRetry).count, 1)

        advance(EngineTuning.confirmMaxElapsedSeconds)
        see([mom()])

        XCTAssertEqual(events(.confirmEnded).map(\.detail), ["outcome=expired"])
        XCTAssertFalse(engine.pendingModelCalls.contains { $0.purpose == .confirm })
    }

    // MARK: - Strip assembly

    func testConfirmStripRecomputesAges() throws {
        try startSighting()
        let confirm = try issueNextConfirm()
        XCTAssertEqual(confirm.request.keyframes.count, 2)
        let oldest = try XCTUnwrap(confirm.request.keyframes.min(by: { $0.capturedAt < $1.capturedAt }))
        let newest = try XCTUnwrap(confirm.request.keyframes.max(by: { $0.capturedAt < $1.capturedAt }))
        XCTAssertGreaterThan(oldest.ageSeconds, 0, "the source frame's age is recomputed, not carried over")
        XCTAssertEqual(newest.ageSeconds, 0)
        XCTAssertEqual(oldest.ageSeconds, newest.capturedAt.timeIntervalSince(oldest.capturedAt), accuracy: 1e-9)
    }

    // MARK: - Clearing

    func testStopEndsTheSighting() throws {
        try startSighting()
        _ = try issueNextConfirm()

        engine.stopSession()

        XCTAssertEqual(events(.confirmEnded).map(\.detail), ["outcome=stopped"])
        XCTAssertTrue(engine.pendingModelCalls.isEmpty, "the in-flight attempt is abandoned with the sighting")
        advance(EngineTuning.confirmDelaySeconds + 1)
        engine.tick()
        XCTAssertEqual(events(.confirmEnded).count, 1, "finishConfirm logs once")
    }

    func testNeedRemovalEndsTheSighting() throws {
        try startSighting()
        let confirm = try issueNextConfirm()

        try engine.setNeeds([Self.refillWater()])

        XCTAssertEqual(events(.confirmEnded).map(\.detail), ["outcome=removed"])
        // The late reply for the abandoned attempt drops.
        engine.handle(callID: confirm.id, verdict: confirmReply(evidence: [], anchor: .unmet))
        XCTAssertEqual(events(.staleReplyDropped).count, 1)
        XCTAssertTrue(engine.openNeedIDs.isEmpty)
    }

    // MARK: - Frame choice

    func testSharperNewFrameIsPreferred() throws {
        engine = try NeedEngine(clock: clock, needs: [Self.takeBaby(), Self.refillWater()], timing: .quick)
        try startSighting()
        advance(1.2)
        let softAt = clock.now()
        see([mom()], sharpness: 0.01, jpeg: 3)
        XCTAssertNil(engine.pendingModelCall, "not due yet")
        advance(1.2)
        let sharpAt = clock.now()
        see([mom()], sharpness: 0.9, jpeg: 4)

        let confirm = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(confirm.purpose, .confirm)
        let stripAt = confirm.request.keyframes.map(\.capturedAt)
        XCTAssertTrue(stripAt.contains(sharpAt))
        XCTAssertFalse(stripAt.contains(softAt))
    }

    func testSoftNewFrameIsStillSentWhenAlone() throws {
        try startSighting()
        advance(EngineTuning.confirmDelaySeconds + 1)
        see([mom()], sharpness: 0.011, jpeg: 3)

        let confirm = try XCTUnwrap(engine.pendingModelCall)
        XCTAssertEqual(confirm.purpose, .confirm)
        XCTAssertEqual(confirm.request.keyframes.count, 2)
    }
}
