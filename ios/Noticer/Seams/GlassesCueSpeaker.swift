import AVFoundation
import Foundation
import NoticerCore

/// Quiet, short cues on a playback-only audio session.
///
/// TODO(verify): a chime has no words. `AVSpeechSynthesizer` has no tone, so a
/// chime is the syllable "mm". Whisper and check-in speak `cue.text`.
@MainActor
final class GlassesCueSpeaker: NSObject, CueSpeaker, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let waiter = SpeechWaiter()
    private var audioSessionActive = false
    private var preparedUtterances: [String: AVSpeechUtterance] = [:]
    private var cachedVoice: AVSpeechSynthesisVoice?
    private var currentCueFiredAt: Date?
    var log: (@Sendable (String, String) -> Void)?

    nonisolated func prepare(needs: [Need]) async {
        await MainActor.run {
            self.synthesizer.delegate = self
            if !self.audioSessionActive {
                if (try? PlaybackAudioSession.activateForCues()) != nil {
                    self.audioSessionActive = true
                }
            }
            if self.cachedVoice == nil {
                self.cachedVoice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
            }
            var nextCache: [String: AVSpeechUtterance] = [:]
            nextCache["chime:mm"] = self.makeUtterance("mm", quietChime: true)
            for need in needs {
                let fakeCue = Cue(id: need.id, needID: need.id, text: need.cueWording, kind: .whisper, createdAt: Date())
                if let text = Self.spokenText(for: fakeCue, maxCharacters: 160) {
                    let key = "whisper:\(text)"
                    nextCache[key] = self.preparedUtterances[key] ?? self.makeUtterance(text, quietChime: false)
                }
            }
            self.preparedUtterances = nextCache
        }
    }

    nonisolated func speak(_ cue: Cue) async throws {
        guard let text = Self.spokenText(for: cue, maxCharacters: 160) else {
            return
        }
        let quietChime = cue.kind == .chime
        let cueCreatedAt = cue.createdAt
        try await MainActor.run {
            if !self.audioSessionActive {
                try PlaybackAudioSession.activateForCues()
                self.audioSessionActive = true
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.arm(continuation)
            Task { @MainActor in
                self.currentCueFiredAt = cueCreatedAt
                self.deliver(text, quietChime: quietChime)
            }
            Task {
                try? await Task.sleep(for: .seconds(12))
                self.waiter.resume()
            }
        }
    }

    nonisolated func stop() async {
        await MainActor.run {
            _ = self.synthesizer.stopSpeaking(at: .immediate)
        }
        waiter.resume()
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let startedAt = Date()
        Task { @MainActor in
            if let firedAt = self.currentCueFiredAt {
                let ms = max(0, Int((startedAt.timeIntervalSince(firedAt) * 1_000).rounded()))
                self.log?("SPEAK", "speakLatency=\(ms)ms")
                self.currentCueFiredAt = nil
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        waiter.resume()
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        waiter.resume()
    }

    private func deliver(_ text: String, quietChime: Bool) {
        let key = quietChime ? "chime:\(text)" : "whisper:\(text)"
        let utterance = preparedUtterances.removeValue(forKey: key) ?? makeUtterance(text, quietChime: quietChime)
        // Replenish a fresh instance so a later repeat never re-enqueues the same object.
        preparedUtterances[key] = makeUtterance(text, quietChime: quietChime)
        synthesizer.delegate = self
        synthesizer.speak(utterance)
    }

    private func makeUtterance(_ text: String, quietChime: Bool) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if let cachedVoice {
            utterance.voice = cachedVoice
        }
        utterance.volume = quietChime ? 0.2 : 0.35
        if quietChime {
            utterance.rate = AVSpeechUtteranceMaximumSpeechRate
        }
        return utterance
    }

    private nonisolated static func spokenText(for cue: Cue, maxCharacters: Int) -> String? {
        let raw: String
        switch cue.kind {
        case .chime:
            raw = "mm"
        case .whisper, .checkIn:
            raw = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !raw.isEmpty else {
            return nil
        }
        if raw.count <= maxCharacters {
            return raw
        }
        return String(raw.prefix(maxCharacters - 1)) + "…"
    }
}

private final class SpeechWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let previous = self.continuation
        self.continuation = continuation
        lock.unlock()
        previous?.resume()
    }

    func resume() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
