import Foundation
import NoticerAgent
import NoticerCore

/// One step of the session after a frame has been gated.
public struct PipelineStep: Equatable, Sendable {
    public var spoken: [Cue]
    public var decisions: [ToolHandlerResult]
    public var modelError: String?
    public var speechError: String?

    public init(
        spoken: [Cue],
        decisions: [ToolHandlerResult],
        modelError: String? = nil,
        speechError: String? = nil
    ) {
        self.spoken = spoken
        self.decisions = decisions
        self.modelError = modelError
        self.speechError = speechError
    }
}

/// What the phone can show without touching the engine.
public struct SessionView: Equatable, Sendable {
    public var now: Date
    public var needs: [Need]
    public var openNeeds: [OpenNeedState]
    public var cues: [Cue]
    public var log: [EngineEvent]
    public var modelCalls: Int

    public init(
        now: Date,
        needs: [Need],
        openNeeds: [OpenNeedState],
        cues: [Cue],
        log: [EngineEvent],
        modelCalls: Int
    ) {
        self.now = now
        self.needs = needs
        self.openNeeds = openNeeds
        self.cues = cues
        self.log = log
        self.modelCalls = modelCalls
    }

    public var masterySummary: String {
        if needs.isEmpty {
            return "No needs"
        }
        return needs.map { need in
            let score = String(format: "%.3f", need.mastery.score)
            return "\(need.id) m=\(score) \(need.mastery.phase.rawValue)"
        }.joined(separator: ", ")
    }

    public var headStartSummary: String {
        if openNeeds.isEmpty {
            return "No open head start"
        }
        return openNeeds.map { open in
            let left = Int(open.cueDeadline.timeIntervalSince(now).rounded())
            let total = Int(open.cueDeadline.timeIntervalSince(open.latchedAt).rounded())
            return "\(open.needID) \(left)s left of \(total)s"
        }.joined(separator: ", ")
    }
}

/// Frame gate snapshot in, model call out, cue spoken.
///
/// The caller pulls frames from a `FrameSource` (replay or DAT) and runs the
/// Vision gate, then calls `ingest`. This type does not reimplement mastery
/// or the chat-completions client. `NeedEngine` decides. `HardCapGate` is
/// asked with `EngineTuning.headStartExtensionStepSeconds` (15 s) so an
/// extension grant uses the same step the engine applies.
///
/// The engine stays the timer. A gate rejection is recorded on the step and
/// does not rewrite the verdict.
public actor SessionPipeline {
    public nonisolated let extensionStepSeconds: TimeInterval

    private let caps: HardCapGate
    private let model: any ModelClient
    private let speaker: any CueSpeaker
    private let clock: SessionClock
    private var engine: NeedEngine<SessionClock>
    private var spokenCueIDs: Set<String> = []
    private var failedCallID: String?

    public init(
        clock: SessionClock,
        needs: [Need],
        model: any ModelClient,
        speaker: any CueSpeaker
    ) throws {
        let step = EngineTuning.headStartExtensionStepSeconds
        self.extensionStepSeconds = step
        self.caps = HardCapGate(extensionStepSeconds: step)
        self.model = model
        self.speaker = speaker
        self.clock = clock
        self.engine = try NeedEngine(clock: clock, needs: needs)
    }

    public func view() -> SessionView {
        SessionView(
            now: clock.now(),
            needs: engine.needs,
            openNeeds: engine.openNeeds,
            cues: engine.cues,
            log: engine.log,
            modelCalls: engine.modelCallsIssued
        )
    }

    public func ingest(frame: CameraFrame, gate: FrameGateSnapshot) async throws -> PipelineStep {
        engine.ingest(frame: frame, gate: gate)
        return try await fulfill()
    }

    public func tick() async throws -> PipelineStep {
        engine.tick()
        return try await fulfill()
    }

    /// Phone tap. The engine treats this as a false cue and restores mastery.
    public func dismissLastCue() {
        guard let id = engine.cues.last?.id else { return }
        engine.dismissFalseCue(id)
    }

    public func replaceNeeds(_ needs: [Need]) throws {
        try engine.setNeeds(needs)
    }

    private func fulfill() async throws -> PipelineStep {
        var decisions: [ToolHandlerResult] = []
        var modelError: String?
        while let call = engine.pendingModelCall {
            if failedCallID == call.id {
                break
            }
            let verdict: ModelVerdict
            do {
                verdict = try await model.complete(call.request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedCallID = call.id
                modelError = String(describing: error)
                break
            }
            failedCallID = nil
            let decision = caps.decide(
                verdict: verdict,
                session: capSession(),
                keyframes: call.request.keyframes
            )
            engine.handle(callID: call.id, verdict: verdict)
            decisions.append(decision)
        }
        let (spoken, speechError) = try await speakNewCues()
        return PipelineStep(
            spoken: spoken,
            decisions: decisions,
            modelError: modelError,
            speechError: speechError
        )
    }

    private func capSession() -> CapSession {
        let now = clock.now()
        var headStarts: [String: HeadStartWindow] = [:]
        for open in engine.openNeeds {
            headStarts[open.needID] = HeadStartWindow(startedAt: open.latchedAt, endsAt: open.cueDeadline)
        }
        let completed = max(0, engine.modelCallsIssued - (engine.pendingModelCall == nil ? 0 : 1))
        return CapSession(
            now: now,
            authoredNeedIDs: Set(engine.needs.map(\.id)),
            openNeedIDs: engine.openNeedIDs,
            callsCompletedBeforeThis: completed,
            lastLatchAt: engine.log.last { $0.kind == .needLatched }?.at,
            relatchNotBefore: [:],
            headStarts: headStarts,
            lastCueAt: engine.cues.last?.createdAt
        )
    }

    private func speakNewCues() async throws -> ([Cue], String?) {
        var fresh: [Cue] = []
        var speechError: String?
        for cue in engine.cues where !spokenCueIDs.contains(cue.id) {
            do {
                try await speaker.speak(cue)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                speechError = String(describing: error)
            }
            spokenCueIDs.insert(cue.id)
            fresh.append(cue)
        }
        return (fresh, speechError)
    }
}
