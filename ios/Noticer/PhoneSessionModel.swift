import Foundation
import MWDATCore
import NoticerCore
import NoticerPipeline

enum CaptureMode: String, CaseIterable, Identifiable, Hashable {
    case live = "Live"
    case replay = "Replay"

    var id: String { rawValue }
}

struct ReplayOption: Identifiable, Hashable {
    enum Kind: String {
        case scenario
        case clip
    }

    var kind: Kind
    var name: String

    var id: String { "\(kind.rawValue):\(name)" }

    var label: String {
        switch kind {
        case .scenario:
            return "Scenario: \(name)"
        case .clip:
            return "Clip: \(name)"
        }
    }
}

/// Phone session. Frames go through the vision gate, then `SessionPipeline`.
@MainActor
@Observable
final class PhoneSessionModel {
    var needs: [Need] = NeedListStore.load()
    var mode: CaptureMode = .replay
    var selectedReplayID = ""
    var phase = "Idle"
    var keepsScreenOn = false
    var framesSeen = 0
    var framesPassed = 0
    var gateLine = "No frame yet"
    var toolLine = "No model turn yet"
    var cueLine = "No cue yet"
    var masteryLine = "Mastery not running"
    var headStartLine = "Head start not running"
    var runError: String?
    var notices: [String] = []
    var dat = DATLiveStatus()
    var registration = "Glasses toolkit not configured"
    var configured = false
    var keyStatus = ModelKeyStore.statusLine()
    var sceneActive = true

    private var clips: [URL] = []
    private var scenarios: [ReplayScenario] = []
    private var loop: Task<Void, Never>?
    private var liveSource: DATFrameSource?
    private var pipeline: SessionPipeline?
    private let speaker = GlassesCueSpeaker()
    private let gate = PersonHandGate()
    private var watching = false

    var replayOptions: [ReplayOption] {
        let scenarioOptions = scenarios.map { ReplayOption(kind: .scenario, name: $0.scenarioID) }
        let clipOptions = clips.map { ReplayOption(kind: .clip, name: $0.lastPathComponent) }
        return scenarioOptions + clipOptions
    }

    var canStart: Bool {
        if isRunning {
            return true
        }
        switch mode {
        case .live:
            return true
        case .replay:
            return selectedOption != nil
        }
    }

    var isRunning: Bool {
        loop != nil
    }

    private var selectedOption: ReplayOption? {
        replayOptions.first { $0.id == selectedReplayID }
    }

    func configureWearables() {
        guard !configured else {
            return
        }
        do {
            try Wearables.configure()
            configured = true
            registration = Self.registrationLabel(Wearables.shared.registrationState)
            watchWearables()
        } catch let error as WearablesError {
            if case .alreadyConfigured = error {
                configured = true
                registration = Self.registrationLabel(Wearables.shared.registrationState)
                watchWearables()
                return
            }
            registration = error.description
        } catch {
            registration = error.localizedDescription
        }
    }

    func registerGlasses() {
        guard configured else {
            return
        }
        Task {
            do {
                try await Wearables.shared.startRegistration()
            } catch {
                addNotice(error.localizedDescription)
            }
        }
    }

    func handle(url: URL) {
        guard configured else {
            return
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else {
            return
        }
        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
            } catch {
                addNotice(error.localizedDescription)
            }
        }
    }

    func reloadLibrary() {
        clips = ClipLibrary.videoURLs()
        do {
            scenarios = try BundledScenarios.load()
        } catch {
            scenarios = []
            addNotice(error.localizedDescription)
        }
        if selectedOption == nil {
            selectedReplayID = replayOptions.first?.id ?? ""
        }
    }

    func saveNeeds() {
        NeedListStore.save(needs)
    }

    func addNeed() {
        guard needs.count < SessionLimits.maxAuthoredNeeds else {
            return
        }
        needs.append(NeedListStore.blankNeed(priority: needs.count))
        saveNeeds()
    }

    func deleteNeed(id: String) {
        needs.removeAll { $0.id == id }
        saveNeeds()
    }

    func refreshKeyStatus() {
        keyStatus = ModelKeyStore.statusLine()
    }

    func setForeground(_ active: Bool) async {
        sceneActive = active
        if !active, keepsScreenOn {
            phase = "Paused — bring the app to the front"
        }
        await liveSource?.setForeground(active)
    }

    func start() {
        guard loop == nil else {
            return
        }
        runError = nil
        framesSeen = 0
        framesPassed = 0
        gateLine = "No frame yet"
        toolLine = "No model turn yet"
        cueLine = "No cue yet"
        masteryLine = "Mastery not running"
        headStartLine = "Head start not running"
        keepsScreenOn = true
        phase = mode == .replay ? "Reading the replay" : "Starting glasses"
        loop = Task {
            await self.run()
        }
    }

    func stop() {
        let source = liveSource
        liveSource = nil
        loop?.cancel()
        loop = nil
        keepsScreenOn = false
        phase = "Idle"
        Task {
            await source?.stop()
        }
    }

    func resumeGlasses() {
        let source = liveSource
        Task {
            do {
                try await source?.resume()
            } catch {
                self.runError = error.localizedDescription
            }
        }
    }

    func dismissCue() {
        let current = pipeline
        Task {
            await speaker.stop()
            await current?.dismissLastCue()
            if let view = await current?.view() {
                self.masteryLine = view.masterySummary
            }
        }
    }

    private func run() async {
        var outcome = "Idle"
        do {
            switch mode {
            case .replay:
                try await runReplay()
                outcome = "Finished"
            case .live:
                try await runLive()
                outcome = "Finished"
            }
        } catch is CancellationError {
            outcome = "Idle"
        } catch {
            runError = error.localizedDescription
            outcome = "Stopped"
        }
        let source = liveSource
        liveSource = nil
        await source?.stop()
        keepsScreenOn = false
        if outcome == "Finished", framesSeen > 0, framesPassed == 0 {
            outcome = "Finished. The gate held every frame, so nothing was sent on."
        }
        if !Task.isCancelled {
            phase = outcome
            loop = nil
        }
    }

    private func runReplay() async throws {
        guard let option = selectedOption else {
            throw ClipLibraryError.noClips
        }
        switch option.kind {
        case .scenario:
            guard let scenario = scenarios.first(where: { $0.scenarioID == option.name }) else {
                throw ScenarioBundleError.unreadable(option.name)
            }
            addNotice("Replay clock. No API key. The scenario uses its own need list.")
            let playback = try ScenarioPlayback(scenario: scenario, speaker: speaker)
            pipeline = playback.pipeline
            phase = "Replaying \(scenario.scenarioID)"
            gateLine = "Scripted gate: \(scenario.people)"
            _ = try await playback.run(pace: .milliseconds(40)) { step, view in
                self.framesSeen += 1
                self.framesPassed += 1
                self.apply(step, view)
            }
        case .clip:
            guard let url = clips.first(where: { $0.lastPathComponent == option.name }) else {
                throw ClipLibraryError.noClips
            }
            let frames = try await ClipLibrary.extractFrames(from: url)
            guard let first = frames.first else {
                throw ClipLibraryError.noFrames
            }
            let recording = try ClipLibrary.makeRecording()
            if recording.skippedTruncated > 0 {
                addNotice("Skipped \(recording.skippedTruncated) truncated fixture(s). Those files are error samples.")
            }
            let clock = SessionClock.manual(startingAt: first.capturedAt)
            let session = try SessionPipeline(
                clock: clock,
                needs: needs,
                model: recording.client,
                speaker: speaker
            )
            pipeline = session
            await gate.reset()
            phase = "Watching"
            let source = ReplayFrameSource(frames: frames)
            let interval = Duration.milliseconds(1_000 / SessionLimits.requestedFramesPerSecond)
            while !Task.isCancelled {
                guard let frame = try await source.nextFrame() else {
                    break
                }
                clock.advance(to: frame.capturedAt)
                try await take(frame: frame, session: session, pace: interval)
            }
        }
    }

    private func runLive() async throws {
        let live = DATFrameSource()
        await live.setStatusHandler { [weak self] status in
            Task { @MainActor in
                self?.apply(status)
            }
        }
        liveSource = live
        try await live.start()
        let session = try SessionPipeline(
            clock: .wall(),
            needs: needs,
            model: AgentSeam.makeLiveClient(),
            speaker: speaker
        )
        pipeline = session
        await gate.reset()
        phase = "Watching"
        while !Task.isCancelled {
            while !sceneActive, !Task.isCancelled {
                phase = "Paused — bring the app to the front"
                try await Task.sleep(for: .milliseconds(200))
            }
            if Task.isCancelled {
                break
            }
            phase = "Watching"
            guard let frame = try await live.nextFrame() else {
                break
            }
            try await take(frame: frame, session: session, pace: nil)
        }
    }

    private func take(frame: CameraFrame, session: SessionPipeline, pace: Duration?) async throws {
        let decision = await gate.evaluate(frame)
        framesSeen += 1
        gateLine = Self.describe(decision)
        if decision.passes {
            framesPassed += 1
        }
        let step = try await session.ingest(frame: frame, gate: decision.snapshot)
        apply(step, await session.view())
        if let pace {
            try await Task.sleep(for: pace)
        }
    }

    private func apply(_ step: PipelineStep, _ view: SessionView) {
        masteryLine = view.masterySummary
        headStartLine = view.headStartSummary
        if let cue = step.spoken.last {
            cueLine = cue.kind == .chime ? "Chime" : cue.text
        }
        if let error = step.modelError {
            toolLine = error
        } else if let event = view.log.last {
            toolLine = Self.describe(event)
        }
        if let speech = step.speechError {
            addNotice("Cue audio failed: \(speech)")
        }
    }

    private func apply(_ status: DATLiveStatus) {
        dat = status
        for notice in status.notices {
            addNotice(notice)
        }
    }

    private func addNotice(_ message: String) {
        guard !notices.contains(message) else {
            return
        }
        notices.append(message)
    }

    private func watchWearables() {
        guard !watching else {
            return
        }
        watching = true
        Task {
            for await state in Wearables.shared.registrationStateStream() {
                self.registration = Self.registrationLabel(state)
            }
        }
    }

    private static func registrationLabel(_ state: RegistrationState) -> String {
        switch state {
        case .unavailable:
            return "Registration unavailable"
        case .available:
            return "Not registered"
        case .registering:
            return "Registering"
        case .registered:
            return "Registered"
        }
    }

    private static func describe(_ decision: GateDecision) -> String {
        let hands = decision.snapshot.wearerHandsVisible ? "hands visible" : "hands not visible"
        let rising = decision.snapshot.handGateRisingEdge ? ", hand rising" : ""
        let decisionText = decision.passes ? "passed" : "held"
        return "\(decision.snapshot.people.count) people, \(hands)\(rising), \(decisionText)"
    }

    private static func describe(_ event: EngineEvent) -> String {
        let who = event.needID.map { " \($0)" } ?? ""
        switch event.kind {
        case .needLatched:
            return "Latched\(who). Head start running."
        case .cueFired:
            return "Cue fired\(who)."
        case .caughtHimself:
            return "Caught it himself\(who)."
        case .headStartExtended:
            return "Head start extended\(who)."
        case .cueDeferredHandsBusy:
            return "Deferring the cue\(who). Hands are busy."
        case .resolvedByPartner:
            return "She handled it\(who)."
        default:
            let detail = event.detail.map { " \($0)" } ?? ""
            return event.kind.rawValue + who + detail
        }
    }
}
