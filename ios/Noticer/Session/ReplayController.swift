import Foundation
import NoticerCore
import NoticerPipeline
import SwiftUI

/// One recorded pipeline step of a replay, with the gate line that produced it.
struct ReplayFrame: Sendable {
    var step: PipelineStep
    var view: SessionView
    var gateLine: String
}

/// Replay with real transport. A scenario or clip is deterministic — recorded
/// responses, a jumping clock — so selecting one precomputes every step
/// headlessly (no pace, silent speaker), then playback scrubs through the
/// recorded states with play/pause, ±5 s, and state markers. The engine and
/// pipeline run exactly as the live session runs them; only the driver is new.
@MainActor
@Observable
final class ReplayController {
    var scenarios: [ReplayScenario] = []
    var clips: [URL] = []
    var selectedID = ""
    var frames: [ReplayFrame] = []
    var statuses: [SessionStatus] = []
    /// Scenario-clock offsets in seconds, parallel to frames.
    var times: [TimeInterval] = []
    var markers: [ReplayMarker] = []
    /// Live-steps rows per frame, parallel to frames. Built during the
    /// headless precompute so scrubbing replays the same list live shows.
    var stripSnapshots: [[DemoStripItem]] = []
    var index = 0
    var isPlaying = false
    var isLoading = false
    var loadError: String?
    var notices: [String] = []

    private var playTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var stripMemory = ReplayStripMemory()
    /// Scenario start of the loaded run. Row offsets measure against this,
    /// never against another run's start.
    private var stripStart: Date?
    private var clock = ReplayClock()
    /// Generation of the latest load. Only it may assign results.
    private var loadToken = 0
    /// Selection with a load in flight, if any.
    private(set) var loadingID: String?

    /// Playhead refresh while playing.
    private static let tickInterval: Duration = .milliseconds(100)

    var options: [ReplayOption] {
        let scenarioOptions = scenarios.map { ReplayOption(kind: .scenario, name: $0.scenarioID) }
        let clipOptions = clips.map { ReplayOption(kind: .clip, name: $0.lastPathComponent) }
        return scenarioOptions + clipOptions
    }

    var duration: TimeInterval {
        times.last ?? 0
    }

    var elapsed: TimeInterval {
        clock.playhead
    }

    var fraction: Double {
        clock.fraction
    }

    var currentFrame: ReplayFrame? {
        frames.indices.contains(index) ? frames[index] : nil
    }

    var currentStatus: SessionStatus {
        statuses.indices.contains(index) ? statuses[index] : .idle
    }

    /// The Live steps rows visible at the playhead, oldest first.
    var currentStripItems: [DemoStripItem] {
        guard stripSnapshots.indices.contains(index) else { return [] }
        return Array(stripSnapshots[index].suffix(DemoStripBuffer.visible))
    }

    func stripRelativeTime(_ item: DemoStripItem) -> String {
        guard let stripStart else {
            return "+0.0s"
        }
        let offset = ReplayClock.clampedOffset(at: item.at, start: stripStart, duration: clock.duration)
        var clamped = item
        clamped.at = stripStart.addingTimeInterval(offset)
        return stripMemory.buffer.relativeTime(clamped)
    }

    /// The recorded still for the playhead, if this scenario has stills.
    var currentStillURL: URL? {
        guard let scenario = selectedScenario,
            let still = scenario.still(at: elapsed),
            let url = BundledStills.url(for: still.image)
        else {
            return nil
        }
        return url
    }

    var selectedScenario: ReplayScenario? {
        guard selectedID.hasPrefix("scenario:") else { return nil }
        let name = String(selectedID.dropFirst("scenario:".count))
        return scenarios.first { $0.scenarioID == name }
    }

    var currentDevLines: [String] {
        guard let frame = currentFrame else {
            return ["No replay loaded"]
        }
        let lastCue = frame.view.cues.last.map { $0.kind == .chime ? "Chime" : $0.text } ?? "—"
        let lastEvent = frame.view.log.last.map(Self.describe) ?? "no need detected"
        return [
            "frames seen \(index + 1) · passed \(index + 1)",
            "model calls \(frame.view.modelCalls)",
            "meta: \(lastEvent)",
            "gate: \(frame.gateLine)",
            "cue: \(lastCue)",
            "mastery: \(frame.view.masterySummary)",
            "headstart: \(frame.view.headStartSummary)",
        ]
    }

    func reload() {
        clips = ClipLibrary.videoURLs()
        do {
            let loaded = try BundledScenarios.load()
            let available = BundledStills.availableImages()
            scenarios = loaded
                .filter { $0.stillsAvailable(in: available) }
                .map { scenario -> ReplayScenario in
                    var sorted = scenario
                    sorted.frames.sort { $0.t < $1.t }
                    return sorted
                }
        } catch {
            scenarios = []
            addNotice(error.localizedDescription)
        }
        if options.first(where: { $0.id == selectedID }) == nil {
            selectedID = options.first?.id ?? ""
        }
    }

    /// Selecting always starts at 0:00, paused — even re-selecting the
    /// scenario already loaded. State clears synchronously so no stale
    /// frame survives, and the load carries a generation token so only
    /// the latest selection assigns results.
    func select(_ id: String, timing: TimingProfile, needs: [Need]) {
        selectedID = id
        loadingID = id
        pause()
        clock.reset(duration: 0)
        index = 0
        loadTask?.cancel()
        loadToken += 1
        frames = []
        statuses = []
        times = []
        markers = []
        stripSnapshots = []
        stripMemory = ReplayStripMemory()
        stripStart = nil
        notices = []
        isLoading = true
        loadError = nil
        let token = loadToken
        loadTask = Task {
            await loadSelected(timing: timing, needs: needs, token: token)
        }
    }

    func togglePlay() {
        guard !frames.isEmpty, !isLoading else {
            return
        }
        if isPlaying {
            pause()
        } else {
            if clock.isAtEnd {
                clock.seek(to: 0)
            }
            clock.play(at: Self.realNow())
            index = clock.index(in: times)
            isPlaying = true
            playTask?.cancel()
            playTask = Task {
                await tick()
            }
        }
    }

    func pause() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    func seek(_ fraction: Double) {
        guard !frames.isEmpty else {
            return
        }
        clock.seek(to: fraction * clock.duration)
        if isPlaying {
            clock.play(at: Self.realNow())
        }
        index = clock.index(in: times)
    }

    func skip(_ seconds: TimeInterval) {
        guard !times.isEmpty else {
            return
        }
        clock.seek(to: clock.playhead + seconds)
        if isPlaying {
            clock.play(at: Self.realNow())
        }
        index = clock.index(in: times)
    }

    private static let realEpoch = ContinuousClock.now

    private static func realNow() -> TimeInterval {
        let elapsed = realEpoch.duration(to: ContinuousClock.now)
        return TimeInterval(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: - Precompute

    /// One load's results, built locally and assigned only while its
    /// generation is current, so a superseded load can never mix into
    /// the next selection.
    private struct LoadResult {
        var frames: [ReplayFrame] = []
        var statuses: [SessionStatus] = []
        var times: [TimeInterval] = []
        var stripSnapshots: [[DemoStripItem]] = []
        var markers: [ReplayMarker] = []
        var notices: [String] = []
        var memory = ReplayStatusMemory()
        var strip = ReplayStripMemory()

        mutating func append(step: PipelineStep, view: SessionView, gateLine: String) {
            frames.append(ReplayFrame(step: step, view: view, gateLine: gateLine))
            if times.isEmpty {
                times.append(0)
            } else if let first = frames.first {
                times.append(view.now.timeIntervalSince(first.view.now))
            }
            memory.advance(view: view, spoken: step.spoken)
            statuses.append(memory.status())
            strip.ingest(step: step, view: view)
            stripSnapshots.append(strip.buffer.items)
        }
    }

    private func loadSelected(timing: TimingProfile, needs: [Need], token: Int) async {
        guard let option = options.first(where: { $0.id == selectedID }) else {
            finishLoad(token: token, result: LoadResult(), error: "Pick a replay first.")
            return
        }
        var result = LoadResult()
        do {
            switch option.kind {
            case .scenario:
                guard let scenario = scenarios.first(where: { $0.scenarioID == option.name }) else {
                    throw ScenarioBundleError.unreadable(option.name)
                }
                try await loadScenario(scenario, timing: timing, result: &result)
            case .clip:
                guard let url = clips.first(where: { $0.lastPathComponent == option.name }) else {
                    throw ClipLibraryError.noClips
                }
                try await loadClip(url: url, timing: timing, needs: needs, result: &result)
            }
            result.markers = Self.markers(for: result.frames, duration: result.times.last ?? 0)
            finishLoad(token: token, result: result, error: nil)
        } catch is CancellationError {
            // A newer selection superseded this load: touch nothing.
        } catch {
            finishLoad(token: token, result: LoadResult(), error: error.localizedDescription)
        }
    }

    /// Assigns a finished load, but only while its generation is current.
    /// A superseded load leaves the controller (including `isLoading`)
    /// for its successor to finish.
    private func finishLoad(token: Int, result: LoadResult, error: String?) {
        guard token == loadToken else {
            return
        }
        frames = result.frames
        statuses = result.statuses
        times = result.times
        stripSnapshots = result.stripSnapshots
        stripMemory = result.strip
        markers = result.markers
        for notice in result.notices {
            addNotice(notice)
        }
        stripStart = result.frames.first?.view.now
        clock.reset(duration: result.times.last ?? 0)
        index = 0
        pause()
        loadError = error
        loadingID = nil
        isLoading = false
    }

    private func loadScenario(_ scenario: ReplayScenario, timing: TimingProfile, result: inout LoadResult) async throws {
        result.notices.append("Recorded replay. Runs offline with this scenario's own list.")
        let effective = scenario.timingName == nil ? timing : scenario.resolvedTiming
        let playback = try ScenarioPlayback(scenario: scenario, speaker: SilentCueSpeaker(), timing: effective)
        var collected: [(PipelineStep, SessionView)] = []
        _ = try await playback.run(pace: nil) { step, view in
            guard !Task.isCancelled else { return }
            collected.append((step, view))
        }
        try Task.checkCancellation()
        for (step, view) in collected {
            result.append(step: step, view: view, gateLine: "Scripted gate: \(scenario.people)")
        }
    }

    private func loadClip(url: URL, timing: TimingProfile, needs: [Need], result: inout LoadResult) async throws {
        let extracted = try await ClipLibrary.extractFrames(from: url)
        guard let first = extracted.first else {
            throw ClipLibraryError.noFrames
        }
        let recording = try ClipLibrary.makeRecording()
        if recording.skippedTruncated > 0 {
            result.notices.append("Skipped \(recording.skippedTruncated) truncated fixture(s). Those files are error samples.")
        }
        let clock = SessionClock.manual(startingAt: first.capturedAt)
        let session = try SessionPipeline(
            clock: clock,
            needs: needs,
            model: recording.client,
            speaker: SilentCueSpeaker(),
            timing: timing
        )
        let gate = SignalFrameGate()
        await gate.reset()
        let source = ReplayFrameSource(frames: extracted)
        while let frame = try await source.nextFrame() {
            try Task.checkCancellation()
            clock.advance(to: frame.capturedAt)
            let needOpen = await session.view().openNeeds.isEmpty == false
            let decision = await gate.evaluate(frame, needOpen: needOpen)
            let step = try await session.ingest(frame: frame, gate: decision.snapshot)
            result.append(
                step: step,
                view: await session.view(),
                gateLine: Self.describe(decision)
            )
        }
    }

    private static func markers(for frames: [ReplayFrame], duration: TimeInterval) -> [ReplayMarker] {
        guard let last = frames.last, duration > 0 else {
            return []
        }
        let start = frames.first?.view.now ?? last.view.now
        return last.view.log.compactMap { event in
            let color: Color?
            switch event.kind {
            case .needLatched: color = Theme.noticed
            case .cueFired: color = Theme.cue
            case .caughtHimself: color = Theme.gotIt
            case .headStartExtended: color = Theme.headstart
            default: color = nil
            }
            guard let color else {
                return nil
            }
            let fraction = event.at.timeIntervalSince(start) / duration
            guard fraction >= 0, fraction <= 1 else {
                return nil
            }
            return ReplayMarker(fraction: fraction, color: color)
        }
    }

    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.tickInterval)
            guard !Task.isCancelled else {
                return
            }
            clock.tick(at: Self.realNow())
            index = clock.index(in: times)
            if clock.isAtEnd {
                break
            }
        }
        isPlaying = false
    }

    private func addNotice(_ message: String) {
        guard !notices.contains(message) else {
            return
        }
        notices.append(message)
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
        default:
            return event.kind.rawValue + who
        }
    }

    private static func describe(_ decision: GateDecision) -> String {
        decision.passes ? "admitted" : "held"
    }
}

// MARK: - Per-frame status memory (scenario clock)

/// Walks the recorded views once, resolving each frame's glanceable status
/// on the scenario clock: a cue or self-notice reads as "just happened"
/// while no later frame supersedes it.
private struct ReplayStatusMemory {
    private var openNeedID: String?
    private var openName = ""
    private var openSince: Date?
    private var lastCue: (text: String, at: Date)?
    private var lastSelfNotice: (name: String, at: Date, shared: Bool)?
    private var seenLogCount = 0
    private var current: SessionStatus = .listening(checking: false)

    mutating func advance(view: SessionView, spoken: [Cue]) {
        if let open = view.openNeeds.first {
            if open.needID != openNeedID {
                openNeedID = open.needID
                openName = ReplayStatusMemory.words(for: open.needID, in: view)
                openSince = view.now
            }
        } else {
            openNeedID = nil
        }
        if let cue = spoken.last {
            lastCue = (cue.kind == .chime ? "Chime" : cue.text, view.now)
        }
        for event in view.log.dropFirst(seenLogCount) {
            if event.kind == .caughtHimself, let needID = event.needID {
                lastSelfNotice = (ReplayStatusMemory.words(for: needID, in: view), event.at, event.isSharedFinish)
            }
        }
        seenLogCount = view.log.count

        // A newer moment supersedes an older one on the scenario clock.
        let selfFresh = lastSelfNotice.map { view.now.timeIntervalSince($0.at) < 8 } ?? false
        let cueFresh = lastCue.map { view.now.timeIntervalSince($0.at) < 8 } ?? false
        let selfWins: Bool = if let selfAt = lastSelfNotice?.at, let cueAt = lastCue?.at {
            selfAt >= cueAt
        } else {
            lastSelfNotice != nil
        }
        if selfFresh, selfWins {
            current = .gotIt(needName: lastSelfNotice?.name ?? "", shared: lastSelfNotice?.shared == true)
            return
        }
        if cueFresh, !selfWins || lastSelfNotice == nil {
            current = .cue(whisper: lastCue?.text ?? "")
            return
        }
        if let open = view.openNeeds.first {
            if view.now >= open.cueDeadline {
                // The head start is over (the cue fired or is due): an
                // open need reads as noticed, never as a 0s head start.
                current = .noticed(needName: openName)
                return
            }
            let remaining = max(0, open.cueDeadline.timeIntervalSince(view.now))
            let total = max(1, open.cueDeadline.timeIntervalSince(open.latchedAt))
            if let since = openSince, view.now.timeIntervalSince(since) < 3, remaining >= total - 0.5 {
                current = .noticed(needName: openName)
            } else {
                current = .headStart(
                    needName: openName,
                    fraction: max(0, min(1, remaining / total)),
                    secondsLeft: max(0, Int(remaining.rounded()))
                )
            }
            return
        }
        current = .listening(checking: false)
    }

    func status() -> SessionStatus {
        current
    }

    private static func words(for needID: String, in view: SessionView) -> String {
        if let need = view.needs.first(where: { $0.id == needID }),
           !need.authorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return need.authorText
        }
        return needID
    }
}

private struct SilentCueSpeaker: CueSpeaker {
    func speak(_ cue: Cue) async throws {}
    func stop() async {}
}

// MARK: - Per-frame Live steps (scenario clock)

/// Replays the same Live steps list the live session shows: spoken cues
/// caption as whispers, engine events map through `DemoStripMapper`, and
/// row times use the scenario clock. Countdowns freeze as text — a
/// recording never counts down.
private struct ReplayStripMemory {
    var buffer = DemoStripBuffer()
    private var started = false
    private var seenLogCount = 0
    private var seenCueIDs = Set<String>()

    mutating func ingest(step: PipelineStep, view: SessionView) {
        if !started {
            buffer.reset(sessionStart: view.now)
            started = true
        }
        let headStartSeconds: (String) -> TimeInterval? = { needID in
            view.openNeeds.first(where: { $0.needID == needID }).map {
                $0.cueDeadline.timeIntervalSince($0.latchedAt)
            }
        }
        for event in view.log.dropFirst(seenLogCount) {
            if let row = DemoStripMapper.item(for: event, needs: view.needs, headStartSeconds: headStartSeconds) {
                buffer.append(row.0, style: row.1, at: event.at, countdownEndsAt: row.2, needID: event.needID)
            }
            if event.kind == .needLatched,
                let followUp = DemoStripMapper.headStartFollowUp(for: event, headStartSeconds: headStartSeconds, now: view.now) {
                buffer.append(followUp.0, style: followUp.1, at: event.at, needID: event.needID)
            }
        }
        seenLogCount = view.log.count
        for cue in step.spoken where !seenCueIDs.contains(cue.id) {
            seenCueIDs.insert(cue.id)
            guard cue.kind != .chime else { continue }
            buffer.append(
                DemoStripMapper.stepCaption(spoken: cue.text, isRepeat: cue.isRepeat),
                style: .whisper,
                at: view.now,
                needID: cue.needID
            )
        }
    }
}
