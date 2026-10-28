import AVFoundation
import Foundation
import os

/// Playback-only session for cues.
///
/// The category is `.playback`, so this does not record. `.allowBluetooth` is the
/// HFP option and is valid only for record categories; it is not set. Nothing in
/// this app requests `Permission.microphone` or adds a microphone usage string.
///
/// TODO(verify): on Ray-Ban Meta hardware, confirm the spoken route stays A2DP
/// and that opening this session never drops the DAT frame rate or ends the
/// session (github.com/facebook/meta-wearables-dat-ios/discussions/323, issue #342).
/// The `.playback` / `.spokenAudio` / `.duckOthers` combination is the PRD's N18
/// and was not re-checked on device.
enum PlaybackAudioSession {
    private static let logger = Logger(subsystem: "app.noticer.Noticer", category: "audio")

    @MainActor
    static func activateForCues() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            logger.error("Audio session failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        if session.category != .playback {
            logger.error(
                "Audio session category is \(session.category.rawValue, privacy: .public); expected playback"
            )
        }
    }
}
