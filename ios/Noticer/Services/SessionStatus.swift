import Foundation
import SwiftUI

// MARK: - Session status (read-only view of the running session)

///
/// Glanceable status for the live and replay heroes. Computed only; the
/// engine never reads it. Live values come from the model's additive live
/// state; replay values are resolved per frame from recorded pipeline views.
///

enum SessionStatus: Equatable {
    case idle
    case listening(checking: Bool)
    case noticed(needName: String)
    case headStart(needName: String, fraction: Double, secondsLeft: Int)
    case cue(whisper: String)
    case gotIt(needName: String, shared: Bool = false)

    var word: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .noticed: return "Need noticed"
        case .headStart: return "Your head start"
        case .cue: return "Cue whispered"
        case .gotIt(_, let shared): return shared ? "You finished it" : "You got it"
        }
    }

    var line: String {
        switch self {
        case .idle: return "Tap Start when you're both settled."
        case .listening(let checking): return checking ? "Checking the scene…" : "All calm."
        case .noticed(let name): return name
        case .headStart: return "Take a look around."
        case .cue(let whisper): return "“\(whisper)”"
        case .gotIt(_, let shared): return shared ? "Nice teamwork." : "Nice catch."
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "moon.stars"
        case .listening(let checking): return checking ? "magnifyingglass" : "ear"
        case .noticed: return "eye"
        case .headStart: return "hourglass"
        case .cue: return "speaker.wave.2"
        case .gotIt: return "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .idle, .listening: return Theme.listening
        case .noticed: return Theme.noticed
        case .headStart: return Theme.headstart
        case .cue: return Theme.cue
        case .gotIt: return Theme.gotIt
        }
    }

    /// Stable per state (and per need), for cross-fades and announcements.
    /// The head-start countdown is intentionally not part of the key.
    var animationKey: String {
        switch self {
        case .idle: return "idle"
        case .listening(let checking): return checking ? "listening-checking" : "listening"
        case .noticed(let name): return "noticed-\(name)"
        case .headStart(let name, _, _): return "headstart-\(name)"
        case .cue(let whisper): return "cue-\(whisper)"
        case .gotIt(let name): return "gotit-\(name)"
        }
    }

    var voiceOver: String {
        switch self {
        case .headStart(_, _, let secondsLeft):
            return "Status: Your head start, \(secondsLeft) seconds left"
        default:
            return "Status: \(word). \(line)"
        }
    }

    var breathing: Bool {
        switch self {
        case .listening, .idle: return true
        default: return false
        }
    }

    var headStartFraction: Double? {
        guard case .headStart(_, let fraction, _) = self else {
            return nil
        }
        return fraction
    }
}

/// Pure resolver shared by the live session and replay playback.
enum SessionStatusResolver {
    /// Moments younger than this still read as "just happened".
    static let recencyWindow: TimeInterval = 6
    /// A fresh latch reads as "noticed" for this long before the head start.
    static let noticedWindow: TimeInterval = 3
    /// Pipeline activity (a model turn, new engine events) younger than this
    /// reads as "Checking the scene…" instead of "All calm."
    static let activityWindow: TimeInterval = 8

    static func resolve(
        isRunning: Bool,
        openNeedName: String?,
        headStart: (remaining: TimeInterval, total: TimeInterval)?,
        noticedAt: Date?,
        lastCue: (text: String, at: Date)?,
        lastSelfNotice: (name: String, at: Date, shared: Bool)?,
        checking: Bool,
        now: Date
    ) -> SessionStatus {
        guard isRunning else {
            return .idle
        }
        if let selfNotice = lastSelfNotice,
           now.timeIntervalSince(selfNotice.at) < recencyWindow {
            return .gotIt(needName: selfNotice.name, shared: selfNotice.shared)
        }
        if let cue = lastCue, now.timeIntervalSince(cue.at) < recencyWindow {
            return .cue(whisper: cue.text)
        }
        if let name = openNeedName {
            if let noticedAt, now.timeIntervalSince(noticedAt) < noticedWindow,
               headStart == nil {
                return .noticed(needName: name)
            }
            if let headStart {
                let fraction = max(0, min(1, headStart.remaining / max(1, headStart.total)))
                return .headStart(
                    needName: name,
                    fraction: fraction,
                    secondsLeft: max(0, Int(headStart.remaining.rounded()))
                )
            }
            return .noticed(needName: name)
        }
        return .listening(checking: checking)
    }
}
