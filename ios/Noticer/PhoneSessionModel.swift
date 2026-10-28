import Foundation
import MWDATCore
import NoticerCore

enum CaptureMode: String, CaseIterable, Identifiable, Hashable {
    case live = "Live"
    case replay = "Replay"

    var id: String { rawValue }
}

/// Phone session: frames, the Vision gate, the stub engine, then a cue.
@MainActor
@Observable
final class PhoneSessionModel {
    var needs: [Need] = NeedListStore.load()
    var mode: CaptureMode = .replay
    var selectedClip: String?
    var phase = "Idle"
    var keepsScreenOn = false
    var framesSeen = 0
    var framesPassed = 0
    var gateLine = "No frame yet"
    var toolLine = "No model turn yet"
    var cueLine = "No cue yet"
    var runError: String?
    var notices: [String] = []
    var dat = DATLiveStatus()
    var registration = "Glasses toolkit not configured"
    var configured = false
    var keyStatus = ModelKeyStore.statusLine()
    var sceneActive = true

    private var clips: [URL] = []
    private var loop: Task<Void, Never>?
    private var liveSource: DATFrameSource?
    private let speaker = GlassesCueSpeaker()
    private let gate = PersonHandGate()
    private var watching = false

    var clipLabels: [String] {
        clips.map(\.lastPathComponent)
    }

    var isRunning: Bool {
        loop != nil
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

    func reloadClips() {
        clips = ClipLibrary.videoURLs()
        if selectedClip == nil || !clipLabels.contains(selectedClip ?? "") {
            selectedClip = clipLabels.first
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
        keepsScreenOn = true
        phase = mode == .replay ? "Reading the clip" : "Starting glasses"
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
        Task {
            await speaker.stop()
        }
    }

    private func run() async {
        var outcome = "Idle"
        do {
            let source: any FrameSource
            let client: any ModelClient
            switch mode {
            case .replay:
                guard let name = selectedClip, let url = clips.first(where: { $0.lastPathComponent == name }) else {
                    throw ClipLibraryError.noClips
                }
                source = try await ClipLibrary.makeFrameSource(for: url)
                let recording = try ClipLibrary.makeRecording()
                client = recording.client
                if recording.skippedTruncated > 0 {
                    addNotice("Skipped \(recording.skippedTruncated) truncated fixture(s). Those files are error samples.")
                }
            case .live:
                let live = DATFrameSource()
                await live.setStatusHandler { [weak self] status in
                    Task { @MainActor in
                        self?.apply(status)
                    }
                }
                liveSource = live
                try await live.start()
                source = live
                client = AgentSeam.makeLiveClient()
            }
            await gate.reset()
            let stub = StubSessionEngine(model: client)
            phase = "Watching"
            let pace = mode == .replay
            let interval = Duration.milliseconds(1_000 / SessionLimits.requestedFramesPerSecond)
            while !Task.isCancelled {
                while !sceneActive, !Task.isCancelled {
                    phase = "Paused — bring the app to the front"
                    try await Task.sleep(for: .milliseconds(200))
                }
                if Task.isCancelled {
                    break
                }
                phase = "Watching"
                guard let frame = try await source.nextFrame() else {
                    outcome = "Finished"
                    break
                }
                let decision = await gate.evaluate(frame)
                framesSeen += 1
                gateLine = Self.describe(decision)
                if pace {
                    try await Task.sleep(for: interval)
                }
                guard decision.passes else {
                    continue
                }
                framesPassed += 1
                let turn = await stub.takeTurn(frame: frame, needs: needs)
                if let line = Self.describe(turn) {
                    toolLine = line
                }
                if let cue = turn.cue {
                    cueLine = cue.text
                    do {
                        try await speaker.speak(cue)
                    } catch {
                        addNotice("Cue audio failed: \(error.localizedDescription)")
                    }
                }
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

    private static func describe(_ turn: StubTurn) -> String? {
        switch turn.note {
        case .asked(let tool):
            if tool == .latchNeedHypothesis, turn.cue == nil {
                return "Latched, but that need is not on the list or the cue is empty."
            }
            return tool.rawValue
        case .liveClientNotImplemented:
            return "Live model client is still a stub. Replay uses the recorded responses."
        case .missingAPIKey:
            return "No API key. Save one in the Keychain, or use Replay."
        case .recordingExhausted:
            return "Recorded responses are used up."
        case .standingBy:
            return nil
        case .failed(let message):
            return message
        }
    }
}
