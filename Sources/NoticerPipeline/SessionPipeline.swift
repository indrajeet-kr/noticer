import Foundation
import NoticerAgent
import NoticerCore

/// One step of the session after a frame has been gated.
public struct PipelineStep: Equatable, Sendable {
    public var spoken: [Cue]
    public var decisions: [ToolHandlerResult]
    public var modelError: String?
    public var speechError: String?
    /// The tool Meta just returned. A no-change reply does not write an engine event.
    public var modelSummary: String?

    public init(
        spoken: [Cue],
        decisions: [ToolHandlerResult],
        modelError: String? = nil,
        speechError: String? = nil,
        modelSummary: String? = nil
    ) {
        self.spoken = spoken
        self.decisions = decisions
        self.modelError = modelError
        self.speechError = speechError
        self.modelSummary = modelSummary
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
/// signal gate, then calls `ingest`. This type does not reimplement mastery
/// or the chat-completions client. `NeedEngine` decides. `HardCapGate` is
/// asked with `EngineTuning.headStartExtensionStepSeconds` (15 s) so an
/// extension grant uses the same step the engine applies.
///
/// One model call is in flight at a time. Another `ingest` or `tick` updates
/// the engine and waits; it does not start a second call. The in-flight call
/// is abandoned at `EngineTuning.inFlightStaleSeconds` so the next tick can
/// proceed. The engine stays the timer. A gate rejection is recorded on the
/// step and does not rewrite the verdict.
public actor SessionPipeline {
    public nonisolated let extensionStepSeconds: TimeInterval

    private let caps: HardCapGate
    private let model: any ModelClient
    private let speaker: any CueSpeaker
    private let clock: SessionClock
    private var engine: NeedEngine<SessionClock>
    private var spokenCueIDs: Set<String> = []
    private var modelInFlight = false

    public init(
        clock: SessionClock,
        needs: [Need],
        model: any ModelClient,
        speaker: any CueSpeaker,
        timing: TimingProfile = .standard
    ) throws {
        let step = EngineTuning.headStartExtensionStepSeconds
        self.extensionStepSeconds = step
        self.caps = HardCapGate(extensionStepSeconds: step, timing: timing)
        self.model = model
        self.speaker = speaker
        self.clock = clock
        self.engine = try NeedEngine(clock: clock, needs: needs, timing: timing)
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
        if modelInFlight {
            let (spoken, speechError) = try await speakNewCues()
            return PipelineStep(spoken: spoken, decisions: [], speechError: speechError)
        }
        var decisions: [ToolHandlerResult] = []
        var modelError: String?
        var modelSummary: String?
        while let call = engine.pendingModelCall {
            modelInFlight = true
            let verdict: ModelVerdict
            do {
                verdict = try await completeOne(call)
            } catch is CancellationError {
                modelInFlight = false
                throw CancellationError()
            } catch is ModelCallTimeout {
                modelInFlight = false
                engine.abandonInFlightCall()
                modelError = "The model call timed out. The next tick can start another."
                break
            } catch {
                modelInFlight = false
                engine.abandonInFlightCall()
                modelError = String(describing: error)
                break
            }
            modelInFlight = false
            let decision = caps.decide(
                verdict: verdict,
                session: capSession(),
                keyframes: call.request.keyframes
            )
            engine.handle(callID: call.id, verdict: verdict)
            decisions.append(decision)
            modelSummary = Self.summary(verdict)
        }
        let (spoken, speechError) = try await speakNewCues()
        return PipelineStep(
            spoken: spoken,
            decisions: decisions,
            modelError: modelError,
            speechError: speechError,
            modelSummary: modelSummary
        )
    }

    /// One line for the phone. `report_no_transition` does not latch, so the engine log stays empty.
    private static func summary(_ verdict: ModelVerdict) -> String {
        let need = verdict.assessment.needID ?? "no need"
        let partner: String
        if verdict.assessment.partnerInView == true {
            partner = "partner in view"
        } else if verdict.assessment.partnerInView == false {
            partner = "partner not in view"
        } else {
            partner = "partner unset"
        }
        let sustained = verdict.assessment.sustainedAcrossStrip == true ? "sustained" : "not sustained"
        return "Meta \(verdict.tool.rawValue) \(need), \(partner), \(sustained)"
    }

    /// Races the model call against the engine's in-flight stale window.
    /// The loser is cancelled, so a timed-out call is not still running when the next one starts.
    private func completeOne(_ call: PendingModelCall) async throws -> ModelVerdict {
        let client = model
        let request = call.request
        return try await withThrowingTaskGroup(of: ModelVerdict.self) { group in
            group.addTask {
                try await client.complete(request)
            }
            group.addTask {
                let nanoseconds = UInt64(EngineTuning.inFlightStaleSeconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ModelCallTimeout()
            }
            guard let verdict = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return verdict
        }
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
            spokenCueIDs.insert(cue.id)
            do {
                try await speaker.speak(cue)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                speechError = String(describing: error)
            }
            fresh.append(cue)
        }
        return (fresh, speechError)
    }
}

private struct ModelCallTimeout: Error, Sendable {}
