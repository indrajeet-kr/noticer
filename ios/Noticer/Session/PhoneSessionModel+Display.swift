import Foundation
import MWDATCore
import NoticerCore
import SwiftUI

// MARK: - Display helpers (read-only; the engine never reads these)

extension PhoneSessionModel {
    /// Current glanceable status. The hero refreshes on a 1 s tick so the
    /// countdown and recency windows stay live between pipeline steps.
    var sessionStatus: SessionStatus {
        let openName = liveOpenNeedID.flatMap { needWords(for: $0) }
        let headStart: (TimeInterval, TimeInterval)? = if let remaining = liveHeadStartRemaining,
            let total = liveHeadStartTotal {
            (remaining, total)
        } else {
            nil
        }
        let cue: (String, Date)? = if let at = liveLastCueAt, !liveLastCueText.isEmpty {
            (liveLastCueText, at)
        } else {
            nil
        }
        let selfNotice: (String, Date)? = if let at = liveSelfNoticeAt {
            (liveSelfNoticeNeedID.flatMap { needWords(for: $0) } ?? "that one", at)
        } else {
            nil
        }
        let checking = liveLastModelActivityAt.map {
            Date().timeIntervalSince($0) < SessionStatusResolver.activityWindow
        } ?? false
        return SessionStatusResolver.resolve(
            isRunning: isRunning,
            openNeedName: openName,
            headStart: headStart,
            noticedAt: liveNoticedAt,
            lastCue: cue,
            lastSelfNotice: selfNotice,
            checking: checking,
            now: Date()
        )
    }

    func needWords(for needID: String) -> String {
        if let need = needs.first(where: { $0.id == needID }),
           !need.authorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return need.authorText
        }
        return needID
    }

    /// Display-only mirror of the engine's `H = H0 * (1 + 2m)`, capped.
    /// Read from the run timing; never written back anywhere.
    func displayHeadStart(for need: Need) -> TimeInterval {
        let base = need.dwellSeconds.map { max(0, $0) } ?? runTiming.defaultHeadStartSeconds
        let scaled = base * (1 + CueFadeSpec.headStartMasteryCoefficient * need.mastery.score)
        return min(scaled, runTiming.headStartCapSeconds)
    }

    func displayHeadStartBaseline(for need: Need) -> TimeInterval {
        let base = need.dwellSeconds.map { max(0, $0) } ?? runTiming.defaultHeadStartSeconds
        return min(base, runTiming.headStartCapSeconds)
    }

    // MARK: - Glasses link (read-only; onboarding's Connect step)

    /// What onboarding can say about the glasses link without starting a session.
    var glassesLink: GlassesLink {
        guard configured else {
            return .unknown
        }
        let wearables = Wearables.shared
        let seen = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        if seen.contains(where: { $0.linkState == .connected }) {
            return .connected
        }
        if seen.isEmpty {
            return .none
        }
        return .notConnected
    }
}

/// Read-only link summary for the Connect step.
enum GlassesLink {
    case unknown
    case none
    case notConnected
    case connected
}
