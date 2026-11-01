import XCTest
@testable import NoticerCore

/// Urgent needs skip the wait, not the evidence: a not-sustained urgent
/// hypothesis latches only on a fresh cited newest frame with the anchor
/// unmet and confidence at least 0.75. Anything less falls to confirms.
final class UrgentEvidenceTests: EngineTestCase {
    private func urgentNeeds() throws {
        var urgent = Self.takeBaby()
        urgent.isUrgent = true
        try engine.setNeeds([urgent, Self.refillWater()])
    }

    private func newestID(_ call: PendingModelCall) -> String {
        call.request.keyframes.max(by: { $0.capturedAt < $1.capturedAt })!.id
    }

    private func urgentVerdict(
        _ id: String,
        evidence: [String]?,
        anchor: AnchorState?,
        confidence: Double?,
        sustained: Bool? = false
    ) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: id,
                sustainedAcrossStrip: sustained,
                partnerStateEvidence: ["lid_open"],
                wearerHandsOccupied: false,
                confidence: confidence,
                evidenceKeyframeIDs: evidence,
                newestAnchorState: anchor
            )
        )
    }

    func testFreshCitedNewestFrameLatches() throws {
        try urgentNeeds()
        // Urgent scouts on one frame, so the first call goes out at t=0.
        // Clear it, then answer the two-frame call with fresh evidence.
        see([mom()])
        let scout = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: scout.id, verdict: noTransition())
        advance(SessionLimits.latchMinIntervalSeconds)
        see([mom()], jpeg: 2)
        let latch = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(
            callID: latch.id,
            verdict: urgentVerdict("take-baby", evidence: [newestID(latch)], anchor: .unmet, confidence: 0.85)
        )

        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertEqual(events(.needLatched).map(\.needID), ["take-baby"])
        XCTAssertEqual(
            events(.latchAccepted).map(\.detail),
            ["urgent-single-frame evidence=\(newestID(latch)) conf=0.85"]
        )
    }

    func testEmptyEvidenceFallsThroughToConfirm() throws {
        try urgentNeeds()
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(
            callID: latch.id,
            verdict: urgentVerdict("take-baby", evidence: [], anchor: .unmet, confidence: 0.95)
        )

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.latchRejected).last?.detail, "urgent-no-fresh-evidence")
        XCTAssertEqual(events(.confirmScheduled).map(\.needID), ["take-baby"])
        XCTAssertTrue(events(.latchAccepted).isEmpty)
    }

    func testStaleNewestFrameIsRejected() throws {
        try urgentNeeds()
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)

        advance(EngineTuning.urgentFreshFrameMaxAgeSeconds + 0.5)
        engine.handle(
            callID: latch.id,
            verdict: urgentVerdict("take-baby", evidence: [newestID(latch)], anchor: .unmet, confidence: 0.9)
        )

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.latchRejected).last?.detail, "urgent-no-fresh-evidence")
    }

    func testEvidenceMissingTheNewestFrameIsRejected() throws {
        try urgentNeeds()
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)
        let oldestID = try XCTUnwrap(latch.request.keyframes.min(by: { $0.capturedAt < $1.capturedAt })?.id)

        engine.handle(
            callID: latch.id,
            verdict: urgentVerdict("take-baby", evidence: [oldestID], anchor: .unmet, confidence: 0.9)
        )

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.latchRejected).last?.detail, "urgent-no-fresh-evidence")
    }

    func testNotVisibleAnchorIsRejected() throws {
        try urgentNeeds()
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(
            callID: latch.id,
            verdict: urgentVerdict("take-baby", evidence: [newestID(latch)], anchor: .notVisible, confidence: 0.9)
        )

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.latchRejected).last?.detail, "urgent-no-fresh-evidence")
    }

    func testLowConfidenceIsRejected() throws {
        try urgentNeeds()
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(
            callID: latch.id,
            verdict: urgentVerdict("take-baby", evidence: [newestID(latch)], anchor: .unmet, confidence: 0.74)
        )

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.latchRejected).last?.detail, "urgent-no-fresh-evidence")
    }

    func testCooldownStillWinsOverFreshEvidence() throws {
        try urgentNeeds()
        glancePair()
        let first = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: first.id, verdict: latchVerdict("take-baby"))
        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])

        advance(SessionLimits.heartbeatSeconds + 1)
        see([mom()], jpeg: 2)
        let heartbeat = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: heartbeat.id, verdict: partnerResolved("take-baby"))
        XCTAssertTrue(engine.openNeedIDs.isEmpty)

        advance(SessionLimits.latchMinIntervalSeconds + 1)
        see([mom()], jpeg: 3)
        let second = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(
            callID: second.id,
            verdict: urgentVerdict("take-baby", evidence: [newestID(second)], anchor: .unmet, confidence: 0.9)
        )

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.latchRejected).last?.detail, "cooldown")
    }

    func testNonUrgentNeedsBehaveAsBefore() throws {
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(
            callID: latch.id,
            verdict: urgentVerdict("take-baby", evidence: [newestID(latch)], anchor: .unmet, confidence: 0.85)
        )

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.latchRejected).last?.detail, "not-sustained")
        XCTAssertTrue(events(.latchAccepted).isEmpty)
    }

    func testPaddedEvidenceIDTrimsAndLatches() throws {
        try urgentNeeds()
        see([mom()])
        let scout = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: scout.id, verdict: noTransition())
        advance(SessionLimits.latchMinIntervalSeconds)
        see([mom()], jpeg: 2)
        let latch = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(
            callID: latch.id,
            verdict: urgentVerdict(
                "take-baby",
                evidence: ["  ", " \(newestID(latch)) "],
                anchor: .unmet,
                confidence: 0.85
            )
        )

        XCTAssertEqual(engine.openNeedIDs, ["take-baby"])
        XCTAssertEqual(events(.latchAccepted).count, 1)
    }

    func testTypoAnchorStateDropsAndRejects() throws {
        try urgentNeeds()
        glancePair()
        let latch = try XCTUnwrap(engine.pendingModelCall)

        engine.handle(
            callID: latch.id,
            verdict: urgentVerdict(
                "take-baby",
                evidence: [newestID(latch)],
                anchor: AnchorState(rawValue: "unmett"),
                confidence: 0.9
            )
        )

        XCTAssertTrue(engine.openNeedIDs.isEmpty)
        XCTAssertEqual(events(.assessmentDropped).last?.detail, "unknown-anchor-state")
        XCTAssertEqual(events(.latchRejected).last?.detail, "urgent-no-fresh-evidence")
    }
}
