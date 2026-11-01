import AVFoundation
import Foundation
import Speech

/// Speech-to-text behind the composer's mic button. The mic toggles
/// recording; live partial transcripts fill the draft, and she taps send
/// herself. Recording stops on a second tap or after 2 s of silence.
///
/// The record audio session only ever opens when no Noticer session is
/// running, so the glasses playback session is never disturbed. While a
/// session runs, the mic falls back to focusing the keyboard.
@MainActor
protocol SpeechTranscribing: AnyObject {
    func requestPermissions() async -> DictationPermissions
    func start(onPartial: @escaping @Sendable (String, Bool) -> Void) throws
    func stop()
}

/// Microphone / speech-recognition authorization, as words for the log.
enum DictationPermission: String, Sendable {
    case authorized
    case denied
    case restricted
    case undetermined
}

struct DictationPermissions: Sendable, Equatable {
    var mic: DictationPermission
    var speech: DictationPermission

    /// The audio engine and the recognizer start only when both are granted.
    var allAuthorized: Bool {
        mic == .authorized && speech == .authorized
    }
}

@MainActor
@Observable
final class DictationService {
    /// Latest partial transcript. Hosts copy it into the draft.
    var transcript = ""
    var isRecording = false
    /// One-line calm notice (session fallback, denied permissions).
    /// Clears itself after a few seconds.
    var notice: String?
    /// Set by the host from `model.isRunning`.
    var sessionRunning = false
    /// Set by the host to log speech notices (failures, fallbacks).
    var noteHandler: ((String) -> Void)?
    /// Set by the host to log voice-input taps, permission answers, and
    /// failures as tagged activity lines.
    var logHandler: ((String, String) -> Void)?

    static let silenceTimeout: Duration = .seconds(2)
    static let noticeDuration: Duration = .seconds(4)

    private let transcriber: any SpeechTranscribing
    private var silenceTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(transcriber: (any SpeechTranscribing)? = nil) {
        self.transcriber = transcriber ?? LiveSpeechTranscriber()
    }

    /// Toggles recording. Returns false when falling back to keyboard
    /// dictation (session running, denied permissions, unavailable), in
    /// which case the caller focuses the field instead.
    @discardableResult
    func toggle() async -> Bool {
        if isRecording {
            stop()
            return true
        }
        log("UI", "voice-input tapped")
        guard !sessionRunning else {
            postNotice("Voice typing is off during a session")
            return false
        }
        let permissions = await transcriber.requestPermissions()
        log("APP", "permission mic=\(permissions.mic.rawValue) speech=\(permissions.speech.rawValue)")
        guard permissions.allAuthorized else {
            postNotice("Mic is off. You can type instead.")
            log(
                "ERROR",
                "voice-input permission mic=\(permissions.mic.rawValue) speech=\(permissions.speech.rawValue)"
            )
            return false
        }
        do {
            transcript = ""
            try transcriber.start(onPartial: { [weak self] text, isFinal in
                Task { @MainActor [weak self] in
                    self?.receivePartial(text, isFinal: isFinal)
                }
            })
            isRecording = true
            scheduleSilenceStop()
            return true
        } catch {
            postNotice("Voice typing isn't available right now.")
            log("ERROR", "voice-input unavailable")
            return false
        }
    }

    func stop() {
        silenceTask?.cancel()
        silenceTask = nil
        transcriber.stop()
        isRecording = false
    }

    private func receivePartial(_ text: String, isFinal: Bool) {
        transcript = text
        if isFinal {
            stop()
        } else {
            scheduleSilenceStop()
        }
    }

    private func scheduleSilenceStop() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceTimeout)
            guard !Task.isCancelled else {
                return
            }
            self?.stop()
        }
    }

    private func log(_ tag: String, _ message: String) {
        logHandler?(tag, message)
    }

    private func postNotice(_ text: String) {
        notice = text
        noteHandler?(text)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else {
                return
            }
            self?.notice = nil
        }
    }
}

enum DictationError: Error {
    case unavailable
}

/// Live speech recognition: on-device when the recognizer supports it,
/// partial results into an audio-engine tap.
@MainActor
final class LiveSpeechTranscriber: SpeechTranscribing {
    private var recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: .current)
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func requestPermissions() async -> DictationPermissions {
        DictationPermissions(mic: await Self.microphonePermission(), speech: await Self.speechPermission())
    }

    /// Current answer without prompting when decided; prompts once when
    /// undetermined. Never prompts twice for the same tap.
    nonisolated static func microphonePermission(
        current: () -> AVAudioSession.RecordPermission = { AVAudioSession.sharedInstance().recordPermission },
        request: (@escaping (Bool) -> Void) -> Void = AVAudioApplication.requestRecordPermission
    ) async -> DictationPermission {
        switch current() {
        case .granted:
            return .authorized
        case .denied:
            return .denied
        case .undetermined:
            return await microphoneAuthorization(request: request) ? .authorized : .denied
        @unknown default:
            return .denied
        }
    }

    nonisolated static func speechPermission(
        current: () -> SFSpeechRecognizerAuthorizationStatus = { SFSpeechRecognizer.authorizationStatus() },
        request: (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = SFSpeechRecognizer.requestAuthorization
    ) async -> DictationPermission {
        switch current() {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                request { status in
                    continuation.resume(returning: status)
                }
            }
            switch status {
            case .authorized:
                return .authorized
            case .restricted:
                return .restricted
            case .denied, .notDetermined:
                return .denied
            @unknown default:
                return .denied
            }
        @unknown default:
            return .denied
        }
    }

    /// The authorization callbacks arrive on background queues (TCC reply),
    /// so these helpers are nonisolated: a MainActor-isolated resume closure
    /// traps with EXC_BREAKPOINT when the OS calls it off the main thread.
    /// The `request` seam lets tests fire the callback from any queue.
    nonisolated static func microphoneAuthorization(
        request: (@escaping (Bool) -> Void) -> Void = AVAudioApplication.requestRecordPermission
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            request { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated static func speechAuthorization(
        request: (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = SFSpeechRecognizer.requestAuthorization
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            request { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func start(onPartial: @escaping @Sendable (String, Bool) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.unavailable
        }
        // Second gate behind toggle(): the engine and the recognizer never
        // start without authorization. Reads only; never prompts here.
        guard AVAudioSession.sharedInstance().recordPermission == .granted,
              SFSpeechRecognizer.authorizationStatus() == .authorized
        else {
            throw DictationError.unavailable
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        // A tap on a zero-rate format traps (the input route is not up yet
        // on first activation). Refuse instead of crashing.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw DictationError.unavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        self.request = request
        self.engine = engine
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { result, _ in
            guard let result else {
                return
            }
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor in
                onPartial(text, isFinal)
            }
        }
    }

    func stop() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
