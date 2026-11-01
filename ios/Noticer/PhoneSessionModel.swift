import AVFoundation
import Foundation
import MWDATCore
import NoticerCore
import NoticerPipeline
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable, Hashable {
    case live = "Live"
    case replay = "Replay"

    var id: String { rawValue }
}

/// The one idle-timer switch. Session keep-awake and Demo mode both decide
/// through `IdleTimerPolicy`, then this writes the result. Tests replace it
/// because unit tests run hostless and the real property does not round-trip there.
@MainActor
enum DemoIdleTimer {
    static var setDisabled: (Bool) -> Void = { disabled in
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
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

/// Phone session. Frames go through the signal gate, then `SessionPipeline`.
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
    var modelCalls = 0
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
    /// Shorter waits for a test or a demo. The running session keeps the profile it started with.
    var quickTiming = UserDefaults.standard.bool(forKey: PhoneSessionModel.quickTimingKey)
    /// Shared mom's-list conversation. Her list and the Add sheet read the
    /// same instance, so the read-back cards survive the sheet closing.
    var intentService = NeedsIntentService()
    /// Need ids paused for tonight. Phone-side only; the engine never sees
    /// these, and the set clears at the next calendar day.
    var pausedNeedIDs: Set<String> = PausedNeedsStore.load()

    // MARK: - Live display state (additive; the engine never reads these)

    /// Timing the running session started with, for display math.
    var runTiming = TimingProfile.standard
    var liveOpenNeedID: String?
    var liveHeadStartRemaining: TimeInterval?
    var liveHeadStartTotal: TimeInterval?
    var liveLastCueText = ""
    var liveLastCueIsChime = false
    var liveLastCueAt: Date?
    var liveNoticedAt: Date?
    var liveSelfNoticeAt: Date?
    var liveSelfNoticeNeedID: String?
    /// Ids the engine dropped as unknown, oldest first. Shows what the model
    /// actually sent when a turn names an id that isn't on mom's list.
    var liveDroppedNeedIDs: [String] = []
    /// Last model turn or engine event. Drives "Checking the scene…".
    var liveLastModelActivityAt: Date?
    /// Last latch, kept after the need closes so a completed cycle reads.
    var liveLastLatchedNeedID: String?
    var liveLastLatchedAt: Date?
    /// Engine event timeline for the dev panel, oldest first, capped.
    var liveEventTimeline: [String] = []
    /// Demo mode's live strip and last-call chip. Written only while
    /// `demoModeActive`; contents survive stop so the final outcome stays
    /// on screen for the recording.
    private(set) var demoStrip = DemoStripBuffer()
    private(set) var demoChip: String?
    private(set) var demoModeActive = false
    /// True while this session's Demo mode wants the screen kept awake.
    private var demoOwnsIdleTimer = false
    /// False after the root view leaves, so a disappeared screen can sleep.
    private var idleTimerViewVisible = true
    /// Last value written through `DemoIdleTimer`, so unchanged decisions do not rewrite it.
    private var appliedIdleTimerDisabled: Bool?
    /// Bumped on every scene change so a stale foreground task cannot rewrite a newer one.
    private var foregroundTicket = 0
    /// Last log time per skip detail. Skip lines are chatty by design; the
    /// transcript keeps one per detail per 5 s.
    private var lastSkipLogAt: [String: Date] = [:]
    /// Developer-mode transcript: lifecycle, frames, model turns, engine
    /// events, speech, errors. Cleared on start, kept after stop for review.
    var sessionLog = SessionLog()
    /// Tonight's wins for the Wins tab. Saved on the phone only.
    var moments: [SessionMoment] = SessionMomentsStore.loadRecent()
    /// Latest session boundaries, persisted with the moments so the Wins
    /// header can name the session's start after a restart.
    var currentSessionID: UUID? = SessionMomentsStore.loadSessionInfo()?.id
    var sessionStartedAt: Date? = SessionMomentsStore.loadSessionInfo()?.startedAt
    var sessionEndedAt: Date? = SessionMomentsStore.loadSessionInfo()?.endedAt
    /// Cue counts per day, loaded once and updated with each cue so
    /// Learning re-renders. Persisted through `CueHistoryStore`.
    var cueHistory: [String: Int] = CueHistoryStore.load()
    /// Per-need mastery samples, oldest first, capped. For the Learning sparklines.
    var masterySamples: [String: [Double]] = [:]

    private static let quickTimingKey = "noticer.timing.quick"

    private var clips: [URL] = []
    private var scenarios: [ReplayScenario] = []
    private var loop: Task<Void, Never>?
    private var liveSource: DATFrameSource?
    private var pipeline: SessionPipeline?
    private var replaceTask: Task<Void, Never>?
    /// Internal so tests can drive the speech-start callback directly.
    let speaker = GlassesCueSpeaker()
    private let gate = SignalFrameGate()
    private var watching = false
    private var activeTiming = TimingProfile.standard
    private var seenCueIDs: Set<String> = []
    private var seenLogCount = 0
    private var lastSeenModelCalls = 0
    private var activeIngestTasks: [UUID: Task<Void, Never>] = [:]

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

    var timing: TimingProfile {
        quickTiming ? .quick : .standard
    }

    var timingLine: String {
        let profile = isRunning ? activeTiming : timing
        return "Timing \(profile.name)"
    }

    func setQuickTiming(_ enabled: Bool) {
        let old = quickTiming
        quickTiming = enabled
        UserDefaults.standard.set(enabled, forKey: Self.quickTimingKey)
        if old != enabled {
            sessionLog.appendActivity("SETTINGS", "quick-timing \(old) -> \(enabled)")
        }
    }

    private var selectedOption: ReplayOption? {
        replayOptions.first { $0.id == selectedReplayID }
    }

    private var audioRouteObserver: NSObjectProtocol?

    /// Logs output-route changes (glasses vs speaker vs earpiece) for
    /// cue-audibility debugging. Called once at launch.
    func watchAudioRoutes() {
        guard audioRouteObserver == nil else {
            return
        }
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else {
                return
            }
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                .map { String(describing: $0) } ?? "?"
            let output = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "?"
            self.sessionLog.appendActivity("GLASSES", "audio-route \(reason) (\(output))")
        }
    }

    func configureWearables() {
        guard !configured else {
            return
        }
        do {
            try Wearables.configure()
            configured = true
            registration = Self.registrationLabel(Wearables.shared.registrationState)
            sessionLog.appendActivity("GLASSES", "configured (\(registration))")
            watchWearables()
        } catch {
            if case .alreadyConfigured = error {
                configured = true
                registration = Self.registrationLabel(Wearables.shared.registrationState)
                sessionLog.appendActivity("GLASSES", "already configured (\(registration))")
                watchWearables()
                return
            }
            registration = error.description
            sessionLog.append("ERROR", "wearables: \(error.description)")
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
        sessionLog.appendActivity("GLASSES", "openURL metaWearablesAction")
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

    /// Saves the authored list and, when a live or clip session is already
    /// running, swaps that list into the engine. A scenario replay keeps its
    /// own needs. Without this, "Looks right" updated the phone list and the
    /// running session kept the list it started with. Swaps serialize: each
    /// commit waits for the previous swap to land, so accept-then-undo can't
    /// apply out of order.
    /// State snapshots for the activity log: full list plus Tonight
    /// contents. Called at session start/stop and whenever either changes.
    func snapshotStateForLog() {
        for line in NeedListDiff.snapshotLines(rows: needs.map {
            NeedListDiff.Row(need: $0, paused: isPaused($0.id))
        }) {
            sessionLog.appendActivity("LIST", line)
        }
        snapshotTonightForLog()
    }

    func snapshotTonightForLog() {
        for line in ActivityTonight.snapshotLines(tonightMoments.map {
            ActivityTonight.Entry(at: $0.at, kind: $0.kind.rawValue, needID: $0.needID, text: $0.text)
        }) {
            sessionLog.appendActivity("TONIGHT", line)
        }
    }

    func commitNeeds() {
        let snapshot = needsForSession()
        saveNeeds()
        snapshotStateForLog()
        Task {
            await self.speaker.prepare(needs: snapshot)
        }
        guard let pipeline, sessionUsesAuthoredNeeds else {
            return
        }
        let previous = replaceTask
        previous?.cancel()
        replaceTask = Task {
            _ = await previous?.result
            guard !Task.isCancelled else {
                return
            }
            do {
                try await pipeline.replaceNeeds(snapshot)
            } catch {
                self.runError = String(describing: error)
            }
        }
    }

    private var sessionUsesAuthoredNeeds: Bool {
        if mode == .replay, selectedOption?.kind == .scenario {
            return false
        }
        return true
    }

    /// Turns a freshly added need's UUID into a slug from her words. Existing ids such as
    /// `take-baby` stay put. Called when she leaves the card, and again when a session starts.
    /// A row that was already removed is left alone.
    func nameNeed(uiID: UUID) {
        guard NeedListEditing.nameNeed(&needs, uiID: uiID) else {
            return
        }
        saveNeeds()
    }

    func nameUnnamedNeeds() {
        for uiID in needs.map(\.uiID) {
            nameNeed(uiID: uiID)
        }
    }

    func isPaused(_ needID: String) -> Bool {
        pausedNeedIDs.contains(needID)
    }

    func setPaused(_ needID: String, paused: Bool) {
        let changed = pausedNeedIDs.contains(needID) != paused
        if paused {
            pausedNeedIDs.insert(needID)
        } else {
            pausedNeedIDs.remove(needID)
        }
        PausedNeedsStore.save(pausedNeedIDs)
        intentService.markPendingSuperseded()
        if changed {
            sessionLog.appendActivity("LIST", "pause id=\(needID) \(paused ? "on" : "off") cause=pause-toggle")
        }
    }

    /// Toggles the safety flag the engine reads (`isUrgent`: zero head
    /// start, latches on one clear keyframe). Saves immediately; pending
    /// read-backs keep it through `toNeeds`, so nothing is superseded.
    func setUrgent(_ needID: String, urgent: Bool) {
        guard let index = needs.firstIndex(where: { $0.id == needID }),
              needs[index].isUrgent != urgent
        else {
            return
        }
        let before = needs
        needs[index].isUrgent = urgent
        logListDiff(old: before, cause: "priority-toggle")
        commitNeeds()
    }

    /// Sets every need's mastery back to initial. Refused (nil) while a
    /// session is running. Returns the prior mastery by need id for Undo.
    /// Tonight's wins are untouched. Never called automatically.
    @discardableResult
    func resetLearningProgress() -> [String: MasteryState]? {
        guard !isRunning else {
            return nil
        }
        var stash: [String: MasteryState] = [:]
        for index in needs.indices {
            stash[needs[index].id] = needs[index].mastery
            needs[index].mastery = .initial
        }
        saveNeeds()
        sessionLog.appendActivity("SETTINGS", "learning reset (\(stash.count) needs)")
        return stash
    }

    /// Restores mastery stashed by `resetLearningProgress()`.
    func restoreMastery(_ stash: [String: MasteryState]) {
        for index in needs.indices {
            if let mastery = stash[needs[index].id] {
                needs[index].mastery = mastery
            }
        }
        saveNeeds()
        sessionLog.appendActivity("SETTINGS", "learning reset undone (\(stash.count) needs)")
    }

    /// Blank whisper uses her words. The list on screen can leave that line empty.
    /// Needs paused for tonight are excluded from the session.
    func needsForSession() -> [Need] {
        nameUnnamedNeeds()
        let filled = needs.map { need in
            var copy = need
            if copy.cueWording.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copy.cueWording = copy.authorText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return copy
        }
        return PausedNeedsStore.active(needs: filled, pausedIDs: pausedNeedIDs)
    }

    func addNeed() {
        guard needs.count < SessionLimits.maxAuthoredNeeds else {
            return
        }
        let before = needs
        needs.append(NeedListStore.blankNeed(priority: needs.count))
        logListDiff(old: before, cause: "add-blank")
        saveNeeds()
    }

    func deleteNeed(uiID: UUID) {
        let before = needs
        guard NeedListEditing.delete(&needs, uiID: uiID) else {
            return
        }
        logListDiff(old: before, cause: "delete")
        saveNeeds()
    }

    /// Ask flow: check-ins on/off for every need, logged as one diff.
    func setAllCheckIns(_ allowed: Bool) {
        let before = needs
        for index in needs.indices {
            needs[index].allowsCheckIn = allowed
        }
        logListDiff(old: before, cause: "ask-checkins")
        saveNeeds()
    }

    private func logListDiff(old: [Need], cause: String) {
        let rows = { (needs: [Need]) in
            needs.map { NeedListDiff.Row(need: $0, paused: self.isPaused($0.id)) }
        }
        for line in NeedListDiff.lines(old: rows(old), new: rows(needs), cause: cause) {
            sessionLog.appendActivity("LIST", line)
        }
    }

    func refreshKeyStatus() {
        keyStatus = ModelKeyStore.statusLine()
    }

    /// Scene phase, applied immediately so the idle timer does not wait on the stream.
    @discardableResult
    func setSceneActive(_ active: Bool) -> Int {
        foregroundTicket += 1
        if sceneActive != active {
            sessionLog.appendActivity("APP", active ? "foreground" : "background")
        }
        sceneActive = active
        if !active, keepsScreenOn {
            phase = "Paused — bring the app to the front"
        }
        applyIdleTimer()
        return foregroundTicket
    }

    /// Stream follow-up for a scene change. Drops the work if a newer change won.
    func propagateForeground(_ ticket: Int) async {
        guard foregroundTicket == ticket else { return }
        await liveSource?.setForeground(sceneActive)
    }

    /// Root view is on screen again. Reapplies whatever the session and Demo mode want.
    func refreshIdleTimer() {
        idleTimerViewVisible = true
        applyIdleTimer()
    }

    /// Root view left. Allows sleep until it returns, without clearing session demand.
    func releaseIdleTimer() {
        idleTimerViewVisible = false
        applyIdleTimer()
    }

    /// Writes the idle timer from every current reason. A repeat of the same decision does nothing.
    private func applyIdleTimer() {
        let disabled = IdleTimerPolicy.disableIdleTimer(
            keepsScreenOn: keepsScreenOn,
            demoSession: demoOwnsIdleTimer,
            sceneActive: sceneActive && idleTimerViewVisible
        )
        guard disabled != appliedIdleTimerDisabled else { return }
        appliedIdleTimerDisabled = disabled
        DemoIdleTimer.setDisabled(disabled)
    }

    /// Drops Tonight entries from before the current evening (noon to
    /// noon). Runs on launch and on start; never on stop, so Tonight stays
    /// identical across Stop.
    func resetTonightIfNeeded(now: Date = Date()) {
        let reset = TonightReset.reset(moments, at: \.at, now: now)
        guard reset.dropped > 0 else {
            return
        }
        moments = reset.kept
        SessionMomentsStore.save(moments)
        sessionLog.appendActivity(
            "TONIGHT",
            "reset dropped=\(reset.dropped) before=\(Self.shortTime(TonightReset.eveningStart(now: now)))"
        )
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    func start() {
        guard loop == nil else {
            return
        }
        resetTonightIfNeeded()
        runError = nil
        framesSeen = 0
        framesPassed = 0
        gateLine = "No frame yet"
        toolLine = "No model turn yet"
        modelCalls = 0
        cueLine = "No cue yet"
        masteryLine = "Mastery not running"
        headStartLine = "Head start not running"
        keepsScreenOn = true
        activeTiming = timing
        runTiming = activeTiming
        resetLiveState()
        currentSessionID = UUID()
        sessionStartedAt = Date()
        sessionEndedAt = nil
        saveSessionInfo()
        sessionLog.clear()
        speaker.log = { [log = sessionLog] tag, message in
            Task { @MainActor in log.append(tag, message) }
        }
        demoModeActive = UserDefaults.standard.bool(forKey: "noticer.demo.mode")
        if demoModeActive {
            demoStrip.reset(sessionStart: Date())
            demoChip = nil
            demoOwnsIdleTimer = true
        }
        applyIdleTimer()
        // Replay pipelines speak through this same speaker, so the speech
        // callback is live-only: replays caption whispers from cueFired
        // instead. Each mode gets exactly one whisper source.
        if demoModeActive && mode == .live {
            speaker.onSpeechStart = demoSpeechCallback()
        } else {
            speaker.onSpeechStart = nil
        }
        let activeNeeds = needsForSession()
        sessionLog.append("SESSION", "start mode=\(mode == .replay ? "replay" : "live") timing=\(quickTiming ? "quick" : "standard") needs=\(activeNeeds.count) key=\(ModelKeyStore.currentKey() == nil ? "missing" : "saved")")
        sessionLog.noteSessionStart()
        snapshotStateForLog()
        for need in activeNeeds {
            let dwell = need.dwellSeconds.map { String(Int($0)) } ?? "—"
            let signal = need.selfNoticeSignal ?? "—"
            let handled = need.handledCondition.map { Self.truncate($0) } ?? "—"
            sessionLog.append("SESSION", "need \(need.id) author=\(Self.truncate(need.authorText)) whisper=\(Self.truncate(need.cueWording)) visual=\(Self.truncate(need.visualCondition ?? "—")) handled=\(handled) urgent=\(need.isUrgent) checkin=\(need.allowsCheckIn) dwell=\(dwell) signal=\(signal)")
        }
        Task {
            await self.speaker.prepare(needs: activeNeeds)
        }
        phase = mode == .replay ? "Reading the replay" : "Starting glasses"
        loop = Task {
            await self.run()
        }
    }

    func stop() {
        let source = liveSource
        let current = pipeline
        liveSource = nil
        loop?.cancel()
        loop = nil
        endDemoSession()
        keepsScreenOn = false
        applyIdleTimer()
        phase = "Idle"
        sessionLog.append("SESSION", "stop frames=\(framesSeen)/\(framesPassed) calls=\(modelCalls)")
        snapshotStateForLog()
        SessionLogStore.save(sessionLog.text)
        resetLiveState(clearLastCue: false)
        saveNeeds()
        SessionMomentsStore.save(moments)
        sessionEndedAt = Date()
        saveSessionInfo()
        recordSessionDayHistory()
        Task {
            await current?.stopSession()
            await self.speaker.stop()
            await source?.stop()
        }
    }

    private func saveSessionInfo() {
        guard let id = currentSessionID, let startedAt = sessionStartedAt else {
            return
        }
        SessionMomentsStore.saveSessionInfo(.init(id: id, startedAt: startedAt, endedAt: sessionEndedAt))
    }

    /// The speech-start caption wiring. Factored so tests can drive the real
    /// callback headlessly; live sessions cannot start in tests.
    func demoSpeechCallback() -> (@Sendable (String) -> Void) {
        { [weak self] text in
            Task { @MainActor in
                let caption = DemoStripMapper.stepCaption(spoken: text, isRepeat: SpokenCueForm.isRepeat(text))
                self?.demoStrip.append(caption, style: .whisper, at: Date())
            }
        }
    }

    /// Demo teardown: drop Demo mode's claim on the screen, speech callback
    /// off. The strip contents stay for the recording. The session's own
    /// keep-awake demand is left for the caller. Internal so tests can drop
    /// Demo mode without ending the session.
    func endDemoSession() {
        if demoOwnsIdleTimer {
            demoOwnsIdleTimer = false
            applyIdleTimer()
        }
        speaker.onSpeechStart = nil
        demoModeActive = false
    }

    /// Records one fired cue into the observable history. Internal so
    /// tests can drive the real wiring without running a session.
    func recordCueHistory() {
        cueHistory = CueHistoryStore.recordingCue(in: cueHistory)
        CueHistoryStore.save(cueHistory)
    }

    func recordSessionDayHistory() {
        cueHistory = CueHistoryStore.recordingSessionDay(in: cueHistory)
        CueHistoryStore.save(cueHistory)
    }

    func resumeGlasses() {
        let source = liveSource
        sessionLog.appendActivity("GLASSES", "resume requested")
        Task {
            do {
                try await source?.resume()
            } catch {
                self.runError = error.localizedDescription
                self.sessionLog.append("ERROR", "resume: \(error.localizedDescription)")
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
            sessionLog.append("ERROR", "run: \(error.localizedDescription)")
            outcome = "Stopped"
        }
        let source = liveSource
        liveSource = nil
        await source?.stop()
        endDemoSession()
        keepsScreenOn = false
        applyIdleTimer()
        if outcome == "Finished", framesSeen > 0, framesPassed == 0 {
            outcome = "Finished. The gate held every frame, so nothing was sent on."
        }
        if !Task.isCancelled {
            phase = outcome
            loop = nil
            sessionLog.append("SESSION", "end: \(outcome) frames=\(framesSeen)/\(framesPassed) calls=\(modelCalls)")
            SessionLogStore.save(sessionLog.text)
            saveNeeds()
            SessionMomentsStore.save(moments)
            sessionEndedAt = Date()
            saveSessionInfo()
            recordSessionDayHistory()
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
            let playback = try ScenarioPlayback(scenario: scenario, speaker: speaker, timing: activeTiming)
            pipeline = playback.pipeline
            await playback.pipeline.setCueRepeatsEnabled(demoModeActive)
            phase = "Replaying \(scenario.scenarioID)"
            gateLine = "Scripted gate: \(scenario.people)"
            _ = try await playback.run(pace: .milliseconds(40)) { step, view in
                self.framesSeen += 1
                self.framesPassed += 1
                self.noteFirstFrameForDemo()
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
                needs: needsForSession(),
                model: recording.client,
                speaker: speaker,
                timing: activeTiming
            )
            pipeline = session
            await session.setCueRepeatsEnabled(demoModeActive)
            await gate.reset()
            phase = DemoStripMapper.listeningStatus
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
            needs: needsForSession(),
            model: AgentSeam.makeLiveClient(log: { [log = sessionLog] tag, message in
                Task { await MainActor.run { log.append(tag, message) } }
            }),
            speaker: speaker,
            timing: activeTiming
        )
        pipeline = session
        await session.setCueRepeatsEnabled(true)
        await gate.reset()
        await session.prepareSpeaker()
        phase = DemoStripMapper.listeningStatus
        var lastDroppedBusyLog: Date?
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isRunning, self.sceneActive, !Task.isCancelled else { continue }
                guard self.activeIngestTasks.isEmpty else { continue }
                if let step = try? await session.tick() {
                    self.apply(step, await session.view())
                }
            }
        }
        defer {
            ticker.cancel()
            for task in activeIngestTasks.values {
                task.cancel()
            }
        }
        while !Task.isCancelled {
            while !sceneActive, !Task.isCancelled {
                phase = "Paused — bring the app to the front"
                try await Task.sleep(for: .milliseconds(200))
            }
            if Task.isCancelled {
                break
            }
            phase = DemoStripMapper.listeningStatus
            guard let frame = try await live.nextFrame() else {
                break
            }
            if activeIngestTasks.count >= (session.latency.maxInFlight + 1) {
                let now = Date()
                if lastDroppedBusyLog == nil || now.timeIntervalSince(lastDroppedBusyLog!) >= 1.0 {
                    lastDroppedBusyLog = now
                    sessionLog.append("FRAME", "dropped busy")
                }
                continue
            }
            let snapshot = await evaluateFrame(frame, session: session)
            let taskID = UUID()
            let ingestTask = Task { @MainActor [weak self] in
                defer {
                    self?.activeIngestTasks.removeValue(forKey: taskID)
                }
                do {
                    let step = try await session.ingest(frame: frame, gate: snapshot)
                    if let self, self.isRunning, !Task.isCancelled {
                        self.apply(step, await session.view())
                    }
                } catch is CancellationError {
                    // Normal stop cancellation.
                } catch let urlError as URLError where urlError.code == .cancelled {
                    // Normal stop cancellation.
                } catch {
                    if let self, self.isRunning, !Task.isCancelled {
                        self.runError = error.localizedDescription
                        self.sessionLog.append("ERROR", "ingest: \(error.localizedDescription)")
                    }
                }
            }
            activeIngestTasks[taskID] = ingestTask
        }
        ticker.cancel()
        for task in activeIngestTasks.values {
            task.cancel()
        }
        for task in activeIngestTasks.values {
            await task.value
        }
        activeIngestTasks.removeAll()
    }

    private func evaluateFrame(_ frame: CameraFrame, session: SessionPipeline) async -> FrameGateSnapshot {
        let needOpen = await session.view().openNeeds.isEmpty == false
        let decision = await gate.evaluate(frame, needOpen: needOpen, timing: activeTiming)
        framesSeen += 1
        noteFirstFrameForDemo()
        gateLine = Self.describe(decision)
        if decision.passes {
            framesPassed += 1
            sessionLog.append("FRAME", "#\(framesSeen) admitted \(Self.describe(decision)) \(frame.jpegData.count / 1024)KB")
        }
        if framesSeen % 30 == 0 {
            sessionLog.append("FRAME", "summary seen=\(framesSeen) passed=\(framesPassed) calls=\(modelCalls)")
        }
        return decision.snapshot
    }

    private func take(frame: CameraFrame, session: SessionPipeline, pace: Duration?) async throws {
        let snapshot = await evaluateFrame(frame, session: session)
        let step = try await session.ingest(frame: frame, gate: snapshot)
        apply(step, await session.view())
        if let pace {
            try await Task.sleep(for: pace)
        }
    }

    private func resetLiveState(clearLastCue: Bool = true) {
        liveOpenNeedID = nil
        liveHeadStartRemaining = nil
        liveHeadStartTotal = nil
        if clearLastCue {
            liveLastCueText = ""
            liveLastCueIsChime = false
            liveLastCueAt = nil
        }
        liveNoticedAt = nil
        liveSelfNoticeAt = nil
        liveSelfNoticeNeedID = nil
        liveDroppedNeedIDs = []
        liveLastModelActivityAt = nil
        liveLastLatchedNeedID = nil
        liveLastLatchedAt = nil
        liveEventTimeline = []
        seenCueIDs = []
        seenLogCount = 0
        lastSeenModelCalls = 0
        lastSkipLogAt = [:]
    }

    private func apply(_ step: PipelineStep, _ view: SessionView) {
        guard isRunning else { return }
        masteryLine = view.masterySummary
        headStartLine = view.headStartSummary
        for line in step.timingLines {
            sessionLog.append("TIMING", line)
        }
        if demoModeActive {
            for line in step.timingLines {
                if let chip = DemoStripMapper.latencyChip(fromTimingLine: line) {
                    demoChip = chip
                }
            }
        }
        if let cue = step.spoken.last {
            let text = cue.kind == .chime ? "Chime" : cue.text
            cueLine = "\(text)\(SessionTelemetry.timeSuffix(Date()))"
            sessionLog.append("SPEAK", cue.kind == .chime ? "chime" : "whisper \"\(Self.truncate(cue.text, limit: 120))\"")
        }
        applyLiveState(view)
        modelCalls = view.modelCalls
        // Sticky: a step without a model turn keeps the last verdict line
        // instead of burying it under a per-frame event describe.
        if let error = step.modelError {
            toolLine = error
            sessionLog.append("ERROR", "model: \(error)")
        } else if let summary = step.modelSummary {
            toolLine = summary
        } else if toolLine == "No model turn yet", let event = view.log.last {
            toolLine = Self.describe(event)
        }
        if let speech = step.speechError {
            addNotice("Cue audio failed: \(speech)")
            sessionLog.append("ERROR", "speech: \(speech)")
        }
    }

    private static func truncate(_ text: String, limit: Int = 100) -> String {
        guard text.count > limit else {
            return text
        }
        return String(text.prefix(limit)) + "…"
    }

    /// Display-only mirror of the pipeline view. Writes the live display
    /// state, tonight's wins, and the authored list's mastery. Never feeds
    /// anything back into the session.
    /// Drain one pipeline view into live state, moments, and the transcript.
    /// Internal so tests can feed engine events directly.
    func applyLiveState(_ view: SessionView) {
        if view.modelCalls != lastSeenModelCalls {
            lastSeenModelCalls = view.modelCalls
            liveLastModelActivityAt = Date()
        }
        if let open = view.openNeeds.first {
            if liveOpenNeedID != open.needID {
                liveOpenNeedID = open.needID
                liveNoticedAt = Date()
                liveLastLatchedNeedID = open.needID
                liveLastLatchedAt = Date()
            }
            liveHeadStartRemaining = max(0, open.cueDeadline.timeIntervalSince(view.now))
            liveHeadStartTotal = max(1, open.cueDeadline.timeIntervalSince(open.latchedAt))
        } else {
            liveOpenNeedID = nil
            liveHeadStartRemaining = nil
            liveHeadStartTotal = nil
        }
        for cue in view.cues where !seenCueIDs.contains(cue.id) {
            seenCueIDs.insert(cue.id)
            liveLastCueText = cue.kind == .chime ? "Chime" : cue.text
            liveLastCueIsChime = cue.kind == .chime
            liveLastCueAt = Date()
        }
        let fresh = Array(view.log.dropFirst(seenLogCount))
        for event in fresh {
            if event.kind == .skip, shouldThrottleSkip(event.detail, now: view.now) {
                continue
            }
            if event.kind == .frameDark {
                sessionLog.append("FRAME", "dark")
                continue
            }
            sessionLog.append("ENGINE", Self.describeLogEvent(event))
            switch event.kind {
            case .caughtHimself:
                liveSelfNoticeAt = Date()
                liveSelfNoticeNeedID = event.needID
                if event.isSharedFinish, let needID = event.needID {
                    let outcome = view.lastResolution.flatMap { $0.needID == needID ? $0 : nil }
                    let partner = outcome?.partnerSeenSecondsAgo.map { "\(Int($0))s" } ?? "?"
                    let acted = outcome?.wearerActedSecondsAgo.map { "\(Int($0))s" } ?? "?"
                    sessionLog.append("ENGINE", "sharedFinish \(needID) partnerSeen=\(partner) wearerActed=\(acted)")
                }
                if let needID = event.needID {
                    // One completed action, one entry: a completion in the
                    // same episode upgrades the reminder row in place.
                    if let episodeID = event.episodeID,
                       let row = moments.firstIndex(where: { $0.episodeID == episodeID && $0.kind == .cued }) {
                        moments[row].kind = .nudge
                        moments[row].sharedWithPartner = event.isSharedFinish
                        sessionLog.appendActivity(
                            "TONIGHT",
                            "upgrade need=\(needID) episode=\(episodeID) cued->nudge"
                        )
                        snapshotTonightForLog()
                    } else {
                        moments.append(SessionMoment(
                            at: Date(),
                            needID: needID,
                            kind: .selfNotice,
                            text: Self.words(for: needID, in: view),
                            sessionID: currentSessionID,
                            sharedWithPartner: event.isSharedFinish,
                            episodeID: event.episodeID
                        ))
                        sessionLog.appendActivity(
                            "TONIGHT",
                            ActivityTonight.addLine(kind: SessionMoment.Kind.selfNotice.rawValue, needID: needID, why: "caught-himself")
                        )
                        snapshotTonightForLog()
                    }
                }
            case .cueFired:
                let isRepeat = event.detail == CueSpeechTuning.repeatEventDetail
                if !isRepeat {
                    recordCueHistory()
                    if let needID = event.needID {
                        moments.append(SessionMoment(
                            at: Date(),
                            needID: needID,
                            kind: .cued,
                            text: Self.words(for: needID, in: view),
                            sessionID: currentSessionID,
                            episodeID: event.episodeID
                        ))
                        sessionLog.appendActivity(
                            "TONIGHT",
                            ActivityTonight.addLine(kind: SessionMoment.Kind.cued.rawValue, needID: needID, why: "cue-fired")
                        )
                        snapshotTonightForLog()
                    }
                }
            case .needLatched:
                // Event-driven: a snapshot between ingests can miss a whole
                // open→close cycle, but the log never does.
                if let needID = event.needID {
                    liveLastLatchedNeedID = needID
                    liveLastLatchedAt = event.at
                }
            case .selfNoticedUnprompted:
                // No episode by definition: always its own new entry.
                if let needID = event.needID {
                    moments.append(SessionMoment(
                        at: Date(),
                        needID: needID,
                        kind: .selfNotice,
                        text: Self.words(for: needID, in: view),
                        sessionID: currentSessionID
                    ))
                    sessionLog.appendActivity(
                        "TONIGHT",
                        ActivityTonight.addLine(kind: SessionMoment.Kind.selfNotice.rawValue, needID: needID, why: "unprompted")
                    )
                    snapshotTonightForLog()
                }
            default:
                break
            }
            if demoModeActive {
                demoStripIngest(event, in: view)
            }
        }
        liveEventTimeline.append(contentsOf: SessionTelemetry.eventTimeline(from: fresh, cap: fresh.count))
        liveEventTimeline = Array(liveEventTimeline.suffix(12))
        for dropped in SessionTelemetry.droppedNeedIDs(from: fresh) {
            if liveDroppedNeedIDs.last != dropped {
                liveDroppedNeedIDs.append(dropped)
            }
        }
        liveDroppedNeedIDs = Array(liveDroppedNeedIDs.suffix(8))
        if !fresh.isEmpty {
            liveLastModelActivityAt = Date()
        }
        seenLogCount = view.log.count
        if moments.count > 200 {
            let dropped = moments.count - 200
            moments = Array(moments.suffix(200))
            sessionLog.appendActivity("TONIGHT", ActivityTonight.trimLine(dropped: dropped, cap: 200))
        }
        for need in view.needs {
            guard let index = needs.firstIndex(where: { $0.id == need.id }) else {
                continue
            }
            needs[index].mastery = need.mastery
            var samples = masterySamples[need.id] ?? []
            if samples.last != need.mastery.score {
                samples.append(need.mastery.score)
                masterySamples[need.id] = Array(samples.suffix(30))
            }
        }
    }

    /// Demo strip ingest for one drained event. Pure observer: reads the
    /// view, appends rows, changes nothing else.
    private func demoStripIngest(_ event: EngineEvent, in view: SessionView) {
        if mode == .replay, event.kind == .cueFired {
            if event.detail == CueSpeechTuning.repeatEventDetail {
                demoStrip.append(DemoStripMapper.repeatCaption, style: .whisper, at: Date())
            } else if let cue = view.cues.last(where: { $0.needID == event.needID && !$0.isRepeat })
                ?? view.cues.last(where: { !$0.isRepeat }),
                cue.kind != .chime {
                demoStrip.append(DemoStripMapper.whisperCaption(cue.text), style: .whisper, at: Date())
            }
            return
        }
        let headStartSeconds: (String) -> TimeInterval? = { needID in
            view.openNeeds.first(where: { $0.needID == needID }).map {
                $0.cueDeadline.timeIntervalSince($0.latchedAt)
            }
        }
        guard let row = DemoStripMapper.item(for: event, needs: view.needs, headStartSeconds: headStartSeconds) else {
            return
        }
        demoStrip.append(row.0, style: row.1, at: Date(), countdownEndsAt: row.2)
        if event.kind == .needLatched,
           let followUp = DemoStripMapper.headStartFollowUp(for: event, headStartSeconds: headStartSeconds) {
            demoStrip.append(followUp.0, style: followUp.1, at: Date(), countdownEndsAt: followUp.2)
        }
    }

    /// Demo strip's first row, once per session, on the first frame through.
    private func noteFirstFrameForDemo() {
        if demoModeActive, framesSeen == 1 {
            demoStrip.append(DemoStripMapper.firstFrame, style: .neutral, at: Date())
        }
    }

    /// True when this skip line was logged less than 5 s ago for its detail.
    private func shouldThrottleSkip(_ detail: String?, now: Date) -> Bool {
        let key = detail ?? ""
        if let last = lastSkipLogAt[key], now.timeIntervalSince(last) < 5 {
            return true
        }
        lastSkipLogAt[key] = now
        return false
    }

    private static func describeLogEvent(_ event: EngineEvent) -> String {
        // The line stamp is drain time; the event stamp is record time. Both
        // matter: a late drain looks identical to a late event otherwise.
        var parts = ["@\(SessionLog.stamp(event.at))", event.kind.rawValue]
        if let needID = event.needID {
            parts.append(needID)
        }
        if let detail = event.detail {
            parts.append(detail)
        }
        return parts.joined(separator: " ")
    }

    private static func words(for needID: String, in view: SessionView) -> String {
        if let need = view.needs.first(where: { $0.id == needID }),
           !need.authorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return need.authorText
        }
        return needID
    }

    private func apply(_ status: DATLiveStatus) {
        if status.stream != dat.stream {
            sessionLog.appendActivity("GLASSES", "stream: \(dat.stream) → \(status.stream)")
        }
        if status.deviceType != dat.deviceType {
            sessionLog.appendActivity("GLASSES", "link \(dat.deviceType) → \(status.deviceType)")
        }
        if status.battery != dat.battery, dat.battery == "—" || status.battery == "—" {
            sessionLog.appendActivity("GLASSES", "battery \(dat.battery) → \(status.battery)")
        }
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
        sessionLog.append("NOTICE", message)
    }

    private func watchWearables() {
        guard !watching else {
            return
        }
        watching = true
        Task {
            for await state in Wearables.shared.registrationStateStream() {
                let label = Self.registrationLabel(state)
                if label != self.registration {
                    self.sessionLog.appendActivity("GLASSES", "registration: \(label)")
                }
                self.registration = label
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
        let motion = decision.snapshot.motionScore.map { String(format: "%.3f", $0) } ?? "—"
        let sharp = decision.snapshot.sharpness.map { String(format: "%.4f", $0) } ?? "—"
        let decisionText: String
        if decision.snapshot.activityEdge {
            decisionText = "activity edge"
        } else if decision.passes {
            decisionText = "admitted"
        } else {
            decisionText = "held"
        }
        return "motion \(motion), sharpness \(sharp), \(decisionText)"
    }

    /// One human line per engine event, for the verdict line. Internal so
    /// tests can pin the shared-finish copy.
    static func describe(_ event: EngineEvent) -> String {
        let who = event.needID.map { " \($0)" } ?? ""
        switch event.kind {
        case .needLatched:
            return "Latched\(who). Head start running."
        case .cueFired:
            return "Cue fired\(who)."
        case .caughtHimself:
            if event.isSharedFinish {
                return "You finished it\(who). She started, you wrapped it up."
            }
            return "Caught it himself\(who)."
        case .headStartExtended:
            return "Head start extended\(who)."
        case .cueDeferredHandsBusy:
            return "Deferring the cue\(who). Hands are busy."
        case .cueDeferredPartnerCheck:
            return "Holding the cue\(who). She may be handling it."
        case .resolvedByOther:
            return "She handled it\(who)."
        default:
            let detail = event.detail.map { " \($0)" } ?? ""
            return event.kind.rawValue + who + detail
        }
    }
}
