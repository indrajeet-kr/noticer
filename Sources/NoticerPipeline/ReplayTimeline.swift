import Foundation

/// One stop on the compressed replay timeline: the frame to show, its
/// scenario time, and how long to hold it.
public struct ReplayBeat: Equatable, Sendable {
    public var frameIndex: Int
    public var scenarioTime: TimeInterval
    public var dwell: TimeInterval

    public init(frameIndex: Int, scenarioTime: TimeInterval, dwell: TimeInterval) {
        self.frameIndex = frameIndex
        self.scenarioTime = scenarioTime
        self.dwell = dwell
    }
}

/// Compresses a precomputed replay into ~15 s of watchable beats: one for
/// frame 0, one for every frame where a Live steps row appears or the
/// phase changes, and a final outcome beat that holds. Quiet frames are
/// skipped, so the timer jumps honestly between beats.
public enum ReplayTimeline {
    public static let totalSeconds: TimeInterval = 15
    public static let openingDwell: TimeInterval = 1
    public static let outcomeHold: TimeInterval = 2.5
    public static let minStepDwell: TimeInterval = 1.5
    public static let maxStepDwell: TimeInterval = 2.5

    public static func beats(
        times: [TimeInterval],
        rowCounts: [Int],
        statusKeys: [String]
    ) -> [ReplayBeat] {
        let count = min(times.count, rowCounts.count, statusKeys.count)
        guard count > 0 else { return [] }
        var frames = [0]
        for index in 1..<count {
            if rowCounts[index] > rowCounts[index - 1] || statusKeys[index] != statusKeys[index - 1] {
                frames.append(index)
            }
        }
        if frames.last != count - 1 {
            frames.append(count - 1)
        }
        guard frames.count > 1 else {
            return [ReplayBeat(frameIndex: 0, scenarioTime: times[0], dwell: totalSeconds)]
        }
        let stepCount = frames.count - 2
        let stepDwell = stepCount > 0
            ? min(maxStepDwell, max(minStepDwell, (totalSeconds - openingDwell - outcomeHold) / Double(stepCount)))
            : 0
        let outcomeDwell = max(outcomeHold, totalSeconds - openingDwell - Double(stepCount) * stepDwell)
        return frames.enumerated().map { position, frame in
            let dwell: TimeInterval
            if position == 0 {
                dwell = openingDwell
            } else if position == frames.count - 1 {
                dwell = outcomeDwell
            } else {
                dwell = stepDwell
            }
            return ReplayBeat(frameIndex: frame, scenarioTime: times[frame], dwell: dwell)
        }
    }

    /// Scenario offset of `at`, clamped into the run. Never negative and
    /// never past the end, even for rows stamped by another run.
    public static func clampedOffset(at: Date, start: Date, duration: TimeInterval) -> TimeInterval {
        min(max(0, duration), max(0, at.timeIntervalSince(start)))
    }
}
