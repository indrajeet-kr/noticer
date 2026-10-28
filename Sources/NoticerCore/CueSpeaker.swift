import Foundation

public enum CueSpeakerError: Error, Equatable, Sendable {
    case notImplemented
}

/// Plays a cue. The iOS track routes this to `AVSpeechSynthesizer` and the glasses speaker.
public protocol CueSpeaker: Sendable {
    func speak(_ cue: Cue) async throws
    func stop() async
}
