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
    private var currentCueKind: CueKind?
    private var leadInPlayer: AVAudioPlayer?
    private var stopped = false
    var log: (@Sendable (String, String) -> Void)?
    /// Demo mode sets this to caption speech as it starts. Called with the
    /// exact spoken string; never called for chimes.
    var onSpeechStart: (@Sendable (String) -> Void)?

    nonisolated func prepare(needs: [Need]) async {
        await MainActor.run {
            self.stopped = false
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
            nextCache["chime:mm"] = self.makeUtterance("mm", quietChime: true, slower: false)
            for need in needs {
                let spoken = SpokenCueForm.line(cueWording: need.cueWording, authorText: need.authorText)
                let fakeCue = Cue(id: need.id, needID: need.id, text: spoken, kind: .whisper, createdAt: Date())
                if let text = Self.spokenText(for: fakeCue, maxCharacters: 160) {
                    let key = "whisper:\(text)"
                    nextCache[key] = self.preparedUtterances[key] ?? self.makeUtterance(text, quietChime: false, slower: false)
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
        let slower = cue.isRepeat
        let cueCreatedAt = cue.createdAt
        if await MainActor.run(body: { self.stopped }) {
            return
        }
        try await MainActor.run {
            if !self.audioSessionActive {
                try PlaybackAudioSession.activateForCues()
                self.audioSessionActive = true
            }
        }
        if !quietChime {
            await playLeadIn()
        }
        let aborted = await MainActor.run { self.stopped }
        if aborted {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.arm(continuation)
            Task { @MainActor in
                self.currentCueFiredAt = cueCreatedAt
                self.currentCueKind = cue.kind
                self.deliver(text, quietChime: quietChime, slower: slower)
            }
            Task {
                try? await Task.sleep(for: .seconds(12))
                self.waiter.resume()
            }
        }
    }

    nonisolated func stop() async {
        await MainActor.run {
            self.stopped = true
            self.leadInPlayer?.stop()
            _ = self.synthesizer.stopSpeaking(at: .immediate)
        }
        waiter.resume()
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let startedAt = Date()
        let spoken = utterance.speechString
        Task { @MainActor in
            if let firedAt = self.currentCueFiredAt {
                let ms = max(0, Int((startedAt.timeIntervalSince(firedAt) * 1_000).rounded()))
                self.log?("SPEAK", "speakLatency=\(ms)ms")
                self.currentCueFiredAt = nil
            }
            let kind = self.currentCueKind
            self.currentCueKind = nil
            if kind != .chime {
                self.onSpeechStart?(spoken)
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

    private func deliver(_ text: String, quietChime: Bool, slower: Bool) {
        let key = quietChime ? "chime:\(text)" : "\(slower ? "slow" : "whisper"):\(text)"
        let utterance = preparedUtterances.removeValue(forKey: key) ?? makeUtterance(text, quietChime: quietChime, slower: slower)
        // Replenish a fresh instance so a later repeat never re-enqueues the same object.
        if !slower {
            preparedUtterances[key] = makeUtterance(text, quietChime: quietChime, slower: false)
        }
        synthesizer.delegate = self
        synthesizer.speak(utterance)
    }

    private func makeUtterance(_ text: String, quietChime: Bool, slower: Bool) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if let cachedVoice {
            utterance.voice = cachedVoice
        }
        if quietChime {
            utterance.volume = CueSpeechTuning.chimeVolume
            utterance.rate = AVSpeechUtteranceMaximumSpeechRate
            return utterance
        }
        let scale = slower ? CueSpeechTuning.repeatRateScale : CueSpeechTuning.speechRateScale
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * scale
        utterance.pitchMultiplier = CueSpeechTuning.pitchMultiplier
        utterance.volume = CueSpeechTuning.whisperVolume
        utterance.preUtteranceDelay = CueSpeechTuning.preUtteranceSilence
        return utterance
    }

    /// A short sine note on the playback session, so Bluetooth opens on the
    /// note instead of the first word. Off when the setting is off; the
    /// pre-utterance silence still runs.
    private func playLeadIn() async {
        let play = await MainActor.run { () -> TimeInterval in
            guard Self.leadInEnabled(), !self.stopped else { return 0 }
            let data = LeadInTone.wavData()
            guard let player = try? AVAudioPlayer(data: data) else { return 0 }
            player.volume = 1
            player.prepareToPlay()
            self.leadInPlayer = player
            guard player.play() else { return 0 }
            return player.duration
        }
        if play > 0 {
            try? await Task.sleep(for: .seconds(play))
        }
    }

    private nonisolated static func leadInEnabled() -> Bool {
        let key = CueSpeechTuning.leadInChimeDefaultsKey
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return CueSpeechTuning.leadInChimeDefault
        }
        return UserDefaults.standard.bool(forKey: key)
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

/// One quiet sine note, built in memory so the app has no audio asset.
private enum LeadInTone {
    static func wavData() -> Data {
        let sampleRate = 16_000
        let duration = CueSpeechTuning.leadInDuration
        let count = max(1, Int((duration * Double(sampleRate)).rounded()))
        let frequency = CueSpeechTuning.leadInFrequencyHz
        let amplitude = Double(CueSpeechTuning.leadInAmplitude)
        let attack = min(0.04, duration * 0.25)
        let release = min(0.06, duration * 0.35)
        var samples = [Int16]()
        samples.reserveCapacity(count)
        for index in 0..<count {
            let t = Double(index) / Double(sampleRate)
            let envelope: Double
            if t < attack {
                envelope = t / attack
            } else if t > duration - release {
                envelope = max(0, (duration - t) / release)
            } else {
                envelope = 1
            }
            let shaped = sin(2 * Double.pi * frequency * t) * envelope * amplitude
            let clamped = max(-1, min(1, shaped))
            samples.append(Int16(clamped * Double(Int16.max)))
        }
        return wav(samples: samples, sampleRate: sampleRate)
    }

    private static func wav(samples: [Int16], sampleRate: Int) -> Data {
        let dataBytes = samples.count * 2
        let chunkSize = 36 + dataBytes
        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        data.append(littleEndian: UInt32(chunkSize))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt 
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1)) // PCM
        data.append(littleEndian: UInt16(1)) // mono
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate * 2))
        data.append(littleEndian: UInt16(2)) // block align
        data.append(littleEndian: UInt16(16))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        data.append(littleEndian: UInt32(dataBytes))
        for sample in samples {
            data.append(littleEndian: UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(littleEndian value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
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
