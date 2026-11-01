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
        let sharedSelfNotice = moments.last(where: { $0.needID == liveSelfNoticeNeedID })?.sharedWithPartner == true
        let selfNotice: (name: String, at: Date, shared: Bool)? = if let at = liveSelfNoticeAt {
            (liveSelfNoticeNeedID.flatMap { needWords(for: $0) } ?? "that one", at, sharedSelfNotice)
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

    /// Most recent spoken cue, with a relative time, for a glance at Tonight.
    func lastCueGlance(at now: Date) -> String? {
        guard let at = liveLastCueAt else { return nil }
        let spoken: String
        if liveLastCueIsChime {
            spoken = "Quiet note"
        } else {
            let text = liveLastCueText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            spoken = text
        }
        return CueRecency.line(spoken: spoken, at: at, now: now)
    }

    func needWords(for needID: String) -> String {
        if let need = needs.first(where: { $0.id == needID }),
           !need.authorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return need.authorText
        }
        return needID
    }

    /// One wording per need: a moment displays the need's current words,
    /// falling back to the recorded snapshot only when the need is gone.
    func momentWords(for moment: SessionMoment) -> String {
        MomentWords.text(for: moment, needs: needs)
    }

    /// Tonight's timeline: today's moments for needs still on her list.
    /// The same selection while a session is running and after it stops.
    /// A need she removed does not keep its old row.
    var tonightMoments: [SessionMoment] {
        let active = Set(needs.map(\.id))
        let now = Date()
        return TonightList.select(moments, at: \.at, needID: \.needID, activeNeedIDs: active, now: now)
    }

    /// True when the recorded session is the one on screen (as opposed to
    /// restored moments from an older session after a restart).
    private var shownSessionIsRecorded: Bool {
        guard let current = currentSessionID else {
            return false
        }
        return tonightMoments.contains { $0.sessionID == current }
    }

    /// The calendar day "tonight" counts belong to: the latest session's
    /// start day, else the latest moment's day, else today.
    var tonightSessionDay: Date {
        let calendar = Calendar.current
        if shownSessionIsRecorded, let started = sessionStartedAt {
            return calendar.startOfDay(for: started)
        }
        if let last = tonightMoments.map(\.at).max() {
            return calendar.startOfDay(for: last)
        }
        return calendar.startOfDay(for: Date())
    }

    /// Cues "tonight": the session window's moments win over the day count,
    /// so sessions spanning midnight and pre-history moments still agree
    /// with Wins. The two sources increment together going forward.
    var tonightCueCount: Int {
        let dayCount = CueHistoryStore.count(on: tonightSessionDay, in: cueHistory)
        let momentCount = tonightMoments.filter { $0.kind != .selfNotice }.count
        return max(dayCount, momentCount)
    }

    /// The latest session's start, for the Wins header. Prefers the
    /// recorded start; falls back to the earliest shown moment.
    var latestSessionStart: Date {
        if shownSessionIsRecorded, let started = sessionStartedAt {
            return started
        }
        return tonightMoments.map(\.at).min() ?? sessionStartedAt ?? Date()
    }

    /// Display-only mirror of the engine's `H = H0 * (1 + 2m)`, capped.
    /// Read from the run timing; never written back anywhere. Mirrors the
    /// engine's urgent rule: safety needs skip the head start entirely.
    func displayHeadStart(for need: Need) -> TimeInterval {
        if LatencyTuning.default.urgentNeedsEnabled, need.isUrgent {
            return 0
        }
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
