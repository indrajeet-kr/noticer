import Foundation
import NoticerCore

/// Cue speaker seam. Step 0 does not call `AVSpeechSynthesizer`.
///
/// The iOS track plays whispers on a playback-only audio session
/// (`.playback`, `.spokenAudio`, `.duckOthers`) routed to the glasses.
/// Do not open HFP, and do not add a microphone usage string.
struct GlassesCueSpeaker: CueSpeaker, Sendable {
    func speak(_ cue: Cue) async throws {
        throw CueSpeakerError.notImplemented
    }

    func stop() async {}
}
