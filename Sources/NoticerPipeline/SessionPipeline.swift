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
    /// Structured `[TIMING]` lines emitted on this step.
    public var timingLines: [String]

    public init(
        spoken: [Cue],
        decisions: [ToolHandlerResult],
        modelError: String? = nil,
        speechError: String? = nil,
        modelSummary: String? = nil,
        timingLines: [String] = []
    ) {
        self.spoken = spoken
        self.decisions = decisions
        self.modelError = modelError
        self.speechError = speechError
        self.modelSummary = modelSummary
        self.timingLines = timingLines
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
/// Up to `LatencyTuning.maxInFlight` model calls run concurrently when newer
/// keyframes arrive. Each completed call publishes its step immediately, and
/// newly fired cues speak on the same step via a detached task.
public actor SessionPipeline {
    public nonisolated let extensionStepSeconds: TimeInterval
    public nonisolated let latency: LatencyTuning

    private let caps: HardCapGate
    private let model: any ModelClient
    private let speaker: any CueSpeaker
    private let clock: SessionClock
    private var engine: NeedEngine<SessionClock>
    private var spokenCueIDs: Set<String> = []
    private var inFlightCallIDs: Set<String> = []
    private var callWallIssuedAt: [String: Date] = [:]
    private var cueFiredWallAt: [String: Date] = [:]
    private var speechTasks: [Task<Void, Never>] = []
    private var pendingSpeechError: String?
    private var speakerPrepared = false
    private var lastRateSummaryAt: Date

    public init(
        clock: SessionClock,
        needs: [Need],
        model: any ModelClient,
        speaker: any CueSpeaker,
        timing: TimingProfile = .standard,
        latency: LatencyTuning = .default
    ) throws {
        let step = EngineTuning.headStartExtensionStepSeconds
        self.extensionStepSeconds = step
        self.latency = latency
        self.caps = HardCapGate(extensionStepSeconds: step, timing: timing, latency: latency)
        self.model = model
        self.speaker = speaker
        self.clock = clock
        self.engine = try NeedEngine(clock: clock, needs: needs, timing: timing, latency: latency)
        self.lastRateSummaryAt = clock.now()
    }

    public func prepareSpeaker() async {
        guard latency.instantSpeech else { return }
        speakerPrepared = true
        await speaker.prepare(needs: engine.needs)
    }

    public func waitForSpeech() async {
        let tasks = speechTasks
        speechTasks = []
        for task in tasks {
            await task.value
        }
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
        noteIssuedTimestamps()
        noteCueWallTimestamps()
        return try await fulfill()
    }

    public func tick() async throws -> PipelineStep {
        engine.tick()
        noteIssuedTimestamps()
        noteCueWallTimestamps()
        return try await fulfill()
    }

    /// Phone tap. The engine treats this as a false cue and restores mastery.
    public func dismissLastCue() {
        guard let id = engine.cues.last?.id else { return }
        engine.dismissFalseCue(id)
    }

    public func replaceNeeds(_ needs: [Need]) async throws {
        try engine.setNeeds(needs)
        if latency.instantSpeech {
            speakerPrepared = true
            await speaker.prepare(needs: engine.needs)
        }
    }

    private func ensureSpeakerPrepared() async {
        guard latency.instantSpeech, !speakerPrepared else { return }
        speakerPrepared = true
        await speaker.prepare(needs: engine.needs)
    }

    private func noteIssuedTimestamps() {
        let wallNow = Date()
        for pending in engine.pendingModelCalls where callWallIssuedAt[pending.id] == nil {
            callWallIssuedAt[pending.id] = wallNow
        }
    }

    private func noteCueWallTimestamps() {
        let wallNow = Date()
        for cue in engine.cues where cueFiredWallAt[cue.id] == nil {
            cueFiredWallAt[cue.id] = wallNow
        }
    }

    private func recordSpeechError(_ message: String) {
        pendingSpeechError = message
    }

    private func consumeRateTimingLines() -> [String] {
        guard latency.timingTelemetry else { return [] }
        let now = clock.now()
        guard now.timeIntervalSince(lastRateSummaryAt) >= 60 else { return [] }
        lastRateSummaryAt = now
        let cpm = engine.callsInLastMinute(now: now)
        let openCount = engine.openNeeds.count
        return ["calls/min=\(cpm) open=\(openCount)"]
    }

    private func fulfill() async throws -> PipelineStep {
        await ensureSpeakerPrepared()

        var decisions: [ToolHandlerResult] = []
        var modelError: String?
        var modelSummary: String?
        var timingLines = consumeRateTimingLines()

        while let call = engine.pendingModelCalls.first(where: { !inFlightCallIDs.contains($0.id) }) {
            inFlightCallIDs.insert(call.id)
            let modelStart = Date()
            let issuedWall = callWallIssuedAt[call.id] ?? modelStart
            let queueMs = max(0, modelStart.timeIntervalSince(issuedWall) * 1_000)
            let payloadBytes = Self.estimateRequestBytes(call.request)

            let verdict: ModelVerdict
            do {
                verdict = try await completeOne(call)
            } catch is CancellationError {
                inFlightCallIDs.remove(call.id)
                callWallIssuedAt[call.id] = nil
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                // A stop-time -999 is a cancel, not a model error.
                inFlightCallIDs.remove(call.id)
                callWallIssuedAt[call.id] = nil
                throw CancellationError()
            } catch is ModelCallTimeout {
                inFlightCallIDs.remove(call.id)
                callWallIssuedAt[call.id] = nil
                engine.abandonInFlightCall(id: call.id)
                modelError = "The model call timed out. The next tick can start another."
                break
            } catch {
                inFlightCallIDs.remove(call.id)
                callWallIssuedAt[call.id] = nil
                engine.abandonInFlightCall(id: call.id)
                modelError = String(describing: error)
                break
            }

            let replyArrivedAt = Date()
            let modelMs = max(0, replyArrivedAt.timeIntervalSince(modelStart) * 1_000)
            let decision = caps.decide(
                verdict: verdict,
                session: capSession(),
                keyframes: call.request.keyframes
            )
            inFlightCallIDs.remove(call.id)
            callWallIssuedAt[call.id] = nil
            engine.handle(callID: call.id, verdict: verdict)
            noteIssuedTimestamps()
            noteCueWallTimestamps()
            let applyMs = max(0, Date().timeIntervalSince(replyArrivedAt) * 1_000)

            decisions.append(decision)
            modelSummary = Self.summary(verdict)
            if latency.timingTelemetry {
                timingLines.append(
                    String(
                        format: "call=%@ purpose=%@ queue=%dms model=%dms apply=%.1fms bytes=%d",
                        call.id,
                        call.purpose.rawValue,
                        Int(queueMs.rounded()),
                        Int(modelMs.rounded()),
                        applyMs,
                        payloadBytes
                    )
                )
                timingLines.append(contentsOf: consumeRateTimingLines())
            }

            if latency.oneReplyPerStep {
                break
            }
        }

        if latency.instantSpeech {
            let (spoken, cueTimings) = dispatchNewCuesDetached()
            timingLines.append(contentsOf: cueTimings)
            let speechError = pendingSpeechError
            pendingSpeechError = nil
            return PipelineStep(
                spoken: spoken,
                decisions: decisions,
                modelError: modelError,
                speechError: speechError,
                modelSummary: modelSummary,
                timingLines: timingLines
            )
        }

        // Legacy mode (`instantSpeech == false`): defer speech to the next step
        // whenever this step ran a model turn.
        if !decisions.isEmpty || modelError != nil {
            return PipelineStep(
                spoken: [],
                decisions: decisions,
                modelError: modelError,
                modelSummary: modelSummary,
                timingLines: timingLines
            )
        }
        let (spoken, speechError, cueTimings) = try await speakNewCuesSynchronously()
        timingLines.append(contentsOf: cueTimings)
        return PipelineStep(
            spoken: spoken,
            decisions: decisions,
            modelError: modelError,
            speechError: speechError,
            modelSummary: modelSummary,
            timingLines: timingLines
        )
    }

    private static func estimateRequestBytes(_ request: ModelRequest) -> Int {
        MuseSparkModelClient.encodedRequestByteCount(request)
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
        let completed = max(0, engine.modelCallsIssued - engine.pendingModelCalls.count)
        let urgentIDs = Set(engine.needs.filter(\.isUrgent).map(\.id))
        return CapSession(
            now: now,
            authoredNeedIDs: Set(engine.needs.map(\.id)),
            urgentNeedIDs: urgentIDs,
            openNeedIDs: engine.openNeedIDs,
            callsCompletedBeforeThis: completed,
            lastLatchAt: engine.log.last { $0.kind == .needLatched }?.at,
            relatchNotBefore: [:],
            headStarts: headStarts,
            lastCueAt: engine.cues.last?.createdAt
        )
    }

    private func dispatchNewCuesDetached() -> ([Cue], [String]) {
        var fresh: [Cue] = []
        var lines: [String] = []
        let dispatchWall = Date()
        for cue in engine.cues where !spokenCueIDs.contains(cue.id) {
            spokenCueIDs.insert(cue.id)
            fresh.append(cue)
            if latency.timingTelemetry,
               let timing = engine.cueTimings.last(where: { $0.cueID == cue.id }) {
                let visibleToLatch = max(0, timing.latchedAt.timeIntervalSince(timing.visibleAt))
                let latchToCue = max(0, timing.cueFiredAt.timeIntervalSince(timing.latchedAt))
                let firedWall = cueFiredWallAt[cue.id] ?? dispatchWall
                let cueToSpeechMs = max(0, dispatchWall.timeIntervalSince(firedWall) * 1_000)
                lines.append(
                    String(
                        format: "need=%@ visible→latch=%.1fs latch→cue=%.1fs cue→speech=%.0fms",
                        cue.needID,
                        visibleToLatch,
                        latchToCue,
                        cueToSpeechMs
                    )
                )
            }
            let speakerRef = speaker
            let task = Task.detached { [weak self] in
                do {
                    try await speakerRef.speak(cue)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.recordSpeechError(String(describing: error))
                }
            }
            speechTasks.append(task)
        }
        return (fresh, lines)
    }

    private func speakNewCuesSynchronously() async throws -> ([Cue], String?, [String]) {
        var fresh: [Cue] = []
        var speechError: String?
        var lines: [String] = []
        for cue in engine.cues where !spokenCueIDs.contains(cue.id) {
            spokenCueIDs.insert(cue.id)
            let speakStartWall = Date()
            do {
                try await speaker.speak(cue)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                speechError = String(describing: error)
            }
            fresh.append(cue)
            if latency.timingTelemetry,
               let timing = engine.cueTimings.last(where: { $0.cueID == cue.id }) {
                let visibleToLatch = max(0, timing.latchedAt.timeIntervalSince(timing.visibleAt))
                let latchToCue = max(0, timing.cueFiredAt.timeIntervalSince(timing.latchedAt))
                let firedWall = cueFiredWallAt[cue.id] ?? speakStartWall
                let cueToSpeechMs = max(0, speakStartWall.timeIntervalSince(firedWall) * 1_000)
                lines.append(
                    String(
                        format: "need=%@ visible→latch=%.1fs latch→cue=%.1fs cue→speech=%.0fms",
                        cue.needID,
                        visibleToLatch,
                        latchToCue,
                        cueToSpeechMs
                    )
                )
            }
        }
        return (fresh, speechError, lines)
    }
}

private struct ModelCallTimeout: Error, Sendable {}
