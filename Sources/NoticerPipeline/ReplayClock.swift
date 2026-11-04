import Foundation

/// Pure replay playhead math. Real time comes from the caller (the phone
/// passes ContinuousClock readings), so tests inject simulated seconds.
public struct ReplayClock: Equatable, Sendable {
    public private(set) var duration: TimeInterval
    public var speed: Double
    public private(set) var playhead: TimeInterval
    private var anchorReal: TimeInterval?
    private var anchorPlayhead: TimeInterval

    public init(duration: TimeInterval = 0, speed: Double = 1) {
        self.duration = max(0, duration)
        self.speed = speed
        self.playhead = 0
        self.anchorReal = nil
        self.anchorPlayhead = 0
    }

    public var fraction: Double {
        guard duration > 0 else { return 0 }
        return playhead / duration
    }

    public var isAtEnd: Bool {
        playhead >= duration
    }

    public mutating func reset(duration: TimeInterval) {
        self.duration = max(0, duration)
        playhead = 0
        anchorReal = nil
        anchorPlayhead = 0
    }

    public mutating func play(at realNow: TimeInterval) {
        anchorReal = realNow
        anchorPlayhead = playhead
    }

    public mutating func tick(at realNow: TimeInterval) {
        guard let anchor = anchorReal else { return }
        playhead = min(duration, max(0, anchorPlayhead + (realNow - anchor) * speed))
    }

    public mutating func seek(to time: TimeInterval) {
        playhead = min(duration, max(0, time))
        anchorReal = nil
        anchorPlayhead = playhead
    }

    /// Last index with `times[i] <= playhead`. Times must be ascending.
    public func index(in times: [TimeInterval]) -> Int {
        var result = 0
        var low = 0
        var high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] <= playhead {
                result = mid
                low = mid + 1
            } else {
                high = mid
            }
        }
        return result
    }

    /// Scenario offset of `at`, clamped into the run. Never negative and
    /// never past the end, even for rows stamped by another run.
    public static func clampedOffset(at: Date, start: Date, duration: TimeInterval) -> TimeInterval {
        min(max(0, duration), max(0, at.timeIntervalSince(start)))
    }
}
