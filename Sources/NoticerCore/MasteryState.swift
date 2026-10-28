import Foundation

public enum MasteryPhase: String, Codable, Sendable, Equatable {
    /// `m < 0.5`. Cues are spoken.
    case coaching
    /// `m >= 0.5` and not retired. The cue is a chime with no words.
    case quiet
    /// Three self-notices in a row and `m >= 0.5`. No cue; the event is only logged.
    case retired
}

/// Per-need fade state. The score and streaks are stored.
/// `phase` only classifies them. It does not apply a self-notice, a cue, or an un-retire.
public struct MasteryState: Equatable, Sendable, Codable {
    public var score: Double
    public var consecutiveSelfNotices: Int
    /// The phase getter ignores this. The core track clears retirement by editing the stored fields.
    public var consecutiveMisses: Int

    public init(score: Double, consecutiveSelfNotices: Int, consecutiveMisses: Int) {
        self.score = score
        self.consecutiveSelfNotices = consecutiveSelfNotices
        self.consecutiveMisses = consecutiveMisses
    }

    public static let initial = MasteryState(
        score: CueFadeSpec.initialScore,
        consecutiveSelfNotices: 0,
        consecutiveMisses: 0
    )

    public var phase: MasteryPhase {
        if consecutiveSelfNotices >= CueFadeSpec.retireSelfNoticeStreak,
           score >= CueFadeSpec.quietThreshold {
            return .retired
        }
        if score >= CueFadeSpec.quietThreshold {
            return .quiet
        }
        return .coaching
    }

    private enum CodingKeys: String, CodingKey {
        case score
        case consecutiveSelfNotices = "consecutive_self_notices"
        case consecutiveMisses = "consecutive_misses"
    }
}
