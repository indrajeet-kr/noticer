import Foundation
import Synchronization

/// A clock tests move by hand. `advance(by:)` does not sleep.
public final class ManualClock: Clock, Sendable {
    private let instant: Mutex<Date>

    public init(now: Date) {
        instant = Mutex(now)
    }

    public func now() -> Date {
        instant.withLock { $0 }
    }

    public func advance(by seconds: TimeInterval) {
        instant.withLock { current in
            current = current.addingTimeInterval(seconds)
        }
    }
}
