import Foundation

/// Time source for head-start timers. Tests pass `ManualClock` instead of sleeping.
public protocol Clock: Sendable {
    func now() -> Date
}
