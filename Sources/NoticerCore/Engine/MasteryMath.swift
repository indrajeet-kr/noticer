import Foundation

/// Pure fade math. `MasteryState.phase` only classifies; these functions write
/// the stored score and streaks the phase reads.
enum MasteryMath {
    /// `H = H0 * (1 + 2m)`, then the profile's head-start cap.
    /// `dwellSeconds` overrides H0 only when mom set it (non-nil).
    static func headStartSeconds(for need: Need, timing: TimingProfile = .standard) -> TimeInterval {
        let base: TimeInterval
        if let dwell = need.dwellSeconds {
            base = max(0, dwell)
        } else {
            base = timing.defaultHeadStartSeconds
        }
        let scaled = base * (1 + CueFadeSpec.headStartMasteryCoefficient * need.mastery.score)
        return min(scaled, timing.headStartCapSeconds)
    }

    static func applySelfNotice(_ state: MasteryState) -> MasteryState {
        var state = state
        state.score = state.score + CueFadeSpec.selfNoticeStep * (1 - state.score)
        state.consecutiveSelfNotices += 1
        state.consecutiveMisses = 0
        return state
    }

    /// A played cue. A dismissed false cue restores the previous value instead.
    static func applyCueFired(_ state: MasteryState) -> MasteryState {
        var state = state
        state.score = CueFadeSpec.cueFiredMultiplier * state.score
        state.consecutiveSelfNotices = 0
        state.consecutiveMisses += 1
        return state
    }

    /// `action_code` is an open string. A code counts as his action when it
    /// uses the `wearer_` prefix from the PRD examples, or when it equals the
    /// compile step's `selfNoticeSignal`. `water_glass_present` does neither.
    static func isWearerAction(_ code: String?, selfNoticeSignal: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        if code.hasPrefix("wearer_") { return true }
        if let selfNoticeSignal, !selfNoticeSignal.isEmpty, code == selfNoticeSignal {
            return true
        }
        return false
    }
}
