import Foundation
import NoticerAgent
import NoticerCore

/// Plays one scenario through the same pipeline the phone uses.
///
/// Order: `ReplayFrameSource`, scripted signal gate, `NeedEngine` keyframe
/// selection, recorded `ModelClient`, verdict handling, `CueSpeaker`.
/// The clock jumps to each frame. Nothing sleeps unless the caller passes a pace.
public struct ScenarioPlayback: Sendable {
    public let pipeline: SessionPipeline
    public let scenario: ReplayScenario
    private let clock: SessionClock
    private let origin: Date
    private let frames: [ScenarioFrame]

    public init(
        scenario: ReplayScenario,
        speaker: any CueSpeaker,
        origin: Date = ScenarioLibrary.origin
    ) throws {
        let clock = SessionClock.manual(startingAt: origin)
        let client = try ScriptedModelClient(responses: scenario.responses)
        self.pipeline = try SessionPipeline(
            clock: clock,
            needs: scenario.needs,
            model: client,
            speaker: speaker
        )
        self.scenario = scenario
        self.clock = clock
        self.origin = origin
        self.frames = scenario.frames(origin: origin)
    }

    /// `onStep` runs on the main actor so the phone can update its screen.
    /// The pipeline itself stays off that actor. Awaiting it lets the speaker
    /// hop back to the main actor without a deadlock.
    @MainActor
    public func run(
        pace: Duration? = nil,
        onStep: (@MainActor (PipelineStep, SessionView) -> Void)? = nil
    ) async throws -> ScenarioReport {
        let source = ReplayFrameSource(frames: frames.map { $0.cameraFrame() })
        var index = 0
        var decisions: [ToolHandlerResult] = []
        var modelErrors: [String] = []
        while let frame = try await source.nextFrame() {
            try Task.checkCancellation()
            let spec = frames[index]
            index += 1
            clock.advance(to: frame.capturedAt)
            let gate = ScriptedSignalGate.snapshot(
                at: frame.capturedAt,
                people: spec.people,
                handsRising: false
            )
            let step = try await pipeline.ingest(frame: frame, gate: gate)
            decisions.append(contentsOf: step.decisions)
            if let error = step.modelError {
                modelErrors.append(error)
            }
            if let onStep {
                let view = await pipeline.view()
                onStep(step, view)
            }
            if let pace {
                try await Task.sleep(for: pace)
            }
        }
        let view = await pipeline.view()
        return ScenarioReport(
            scenarioID: scenario.scenarioID,
            origin: origin,
            endedAt: frames.last?.capturedAt ?? origin,
            cues: view.cues,
            needs: view.needs,
            log: view.log,
            decisions: decisions,
            modelErrors: modelErrors
        )
    }
}
