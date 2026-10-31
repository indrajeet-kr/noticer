import Foundation
import XCTest
@testable import NoticerCore

class EngineTestCase: XCTestCase {
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    var clock: ManualClock!
    var engine: NeedEngine<ManualClock>!

    override func setUpWithError() throws {
        try super.setUpWithError()
        clock = ManualClock(now: Self.origin)
        engine = try NeedEngine(clock: clock, needs: [Self.takeBaby(), Self.refillWater()])
    }

    static func takeBaby(
        priority: Int = 0,
        dwell: TimeInterval? = nil,
        mastery: MasteryState = .initial,
        allowsCheckIn: Bool = false,
        selfNotice: String? = nil,
        wording: String = "Her plate's getting cold, maybe take the baby?"
    ) -> Need {
        Need(
            id: "take-baby",
            authorText: "eating one-handed, take the baby",
            cueWording: wording,
            selfNoticeSignal: selfNotice,
            dwellSeconds: dwell,
            priority: priority,
            allowsCheckIn: allowsCheckIn,
            mastery: mastery
        )
    }

    static func refillWater(
        priority: Int = 1,
        dwell: TimeInterval? = nil,
        mastery: MasteryState = .initial
    ) -> Need {
        Need(
            id: "refill-water",
            authorText: "nursing, no water",
            cueWording: "Her water's empty.",
            dwellSeconds: dwell,
            priority: priority,
            mastery: mastery
        )
    }

    static func need(id: String, priority: Int, dwell: TimeInterval? = nil, mastery: MasteryState = .initial, allowsCheckIn: Bool = false) -> Need {
        Need(
            id: id,
            authorText: id,
            cueWording: "Cue for \(id).",
            dwellSeconds: dwell,
            priority: priority,
            allowsCheckIn: allowsCheckIn,
            mastery: mastery
        )
    }

    func person(width: Double, height: Double, x: Double = 0.1) -> ObservedPerson {
        ObservedPerson(
            boundingBox: NormalizedRect(x: x, y: 0.1, width: width, height: height),
            aspectRatio: width / height
        )
    }

    func mom() -> ObservedPerson { person(width: 0.30, height: 0.70) }

    func adultVisitor() -> ObservedPerson { person(width: 0.28, height: 0.62, x: 0.55) }

    func baby() -> ObservedPerson { person(width: 0.18, height: 0.22, x: 0.40) }

    func television() -> ObservedPerson { person(width: 0.50, height: 0.28, x: 0.40) }

    func advance(_ seconds: TimeInterval) {
        clock.advance(by: seconds)
    }

    func advance(to date: Date) {
        let delta = date.timeIntervalSince(clock.now())
        if delta > 0 { clock.advance(by: delta) }
    }

    func see(
        _ people: [ObservedPerson],
        sharpness: Double? = nil,
        jpeg: UInt8 = 1,
        handsEdge: Bool = false,
        sceneActive: Bool = false,
        activityEdge: Bool = false
    ) {
        let now = clock.now()
        let frame = CameraFrame(capturedAt: now, jpegData: Data([jpeg]), width: 8, height: 8)
        let gate = FrameGateSnapshot(
            capturedAt: now,
            people: people,
            wearerHandsVisible: handsEdge,
            handGateRisingEdge: handsEdge,
            sharpness: sharpness,
            sceneActive: sceneActive,
            activityEdge: activityEdge
        )
        engine.ingest(frame: frame, gate: gate, sharpness: sharpness)
    }

    /// Two person frames 5 s apart. That is one keyframe per glance, far enough to latch.
    func glancePair() {
        see([mom()])
        advance(5)
        see([mom()])
    }

    func mastery(of id: String) -> MasteryState {
        engine.needs.first { $0.id == id }?.mastery ?? .initial
    }

    func events(_ kind: EngineEventKind) -> [EngineEvent] {
        engine.log.filter { $0.kind == kind }
    }

    func latchVerdict(_ id: String, sustained: Bool = true, confidence: Double? = 0.2) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .latchNeedHypothesis,
            assessment: SceneAssessment(
                needID: id,
                sustainedAcrossStrip: sustained,
                partnerStateEvidence: ["eating_one_handed"],
                wearerHandsOccupied: false,
                confidence: confidence
            )
        )
    }

    func noTransition(_ id: String? = nil, sustained: Bool? = nil, handsOccupied: Bool? = nil, resolution: Resolution? = nil) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .reportNoTransition,
            assessment: SceneAssessment(
                needID: id,
                sustainedAcrossStrip: sustained,
                wearerHandsOccupied: handsOccupied,
                resolution: resolution
            )
        )
    }

    func intervention(_ id: String, action: String, sustained: Bool? = nil) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .logWearerIntervention,
            assessment: SceneAssessment(
                needID: id,
                sustainedAcrossStrip: sustained,
                actionCode: action
            )
        )
    }

    func deferral(_ id: String) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .deferCueWearerBusy,
            assessment: SceneAssessment(needID: id, wearerHandsOccupied: true)
        )
    }

    func extensionRequest(_ id: String) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: .requestHeadStartExtension,
            assessment: SceneAssessment(needID: id),
            extensionReason: "hot pan"
        )
    }

    func partnerResolved(_ id: String, tool: ToolName = .reportNeedResolved) -> ModelVerdict {
        ModelVerdict(
            finishReason: .toolCalls,
            tool: tool,
            assessment: SceneAssessment(needID: id, resolution: .resolvedByPartner)
        )
    }
}
