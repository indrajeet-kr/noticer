import Foundation

public enum CueSpeakerError: Error, Equatable, Sendable {
    case notImplemented
}

/// Plays a cue. The iOS track routes this to `AVSpeechSynthesizer` and the glasses speaker.
public protocol CueSpeaker: Sendable {
    func prepare(needs: [Need]) async
    func speak(_ cue: Cue) async throws
    func stop() async
}

public extension CueSpeaker {
    func prepare(needs: [Need]) async {}
}
