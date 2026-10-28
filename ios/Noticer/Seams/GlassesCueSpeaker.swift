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

    nonisolated func speak(_ cue: Cue) async throws {
        guard let text = Self.spokenText(for: cue, maxCharacters: 160) else {
            return
        }
        let quietChime = cue.kind == .chime
        try await MainActor.run {
            try PlaybackAudioSession.activateForCues()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.arm(continuation)
            Task { @MainActor in
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
        let utterance = AVSpeechUtterance(string: text)
        utterance.volume = quietChime ? 0.2 : 0.35
        if quietChime {
            utterance.rate = AVSpeechUtteranceMaximumSpeechRate
        }
        synthesizer.delegate = self
        synthesizer.speak(utterance)
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
