import Foundation
import NoticerCore
import Synchronization

/// Clock the session pipeline can share with a replay driver.
///
/// `manual` stays put until `advance`. `wall` reads the current time and ignores advances.
/// `NeedEngine` stores this reference, so moving it moves the engine's deadlines.
/// The name is qualified because Swift's own `Clock` protocol is also in scope.
public final class SessionClock: NoticerCore.Clock, Sendable {
    private struct State: Sendable {
        var instant: Date
        var followsWallClock: Bool
    }

    private let state: Mutex<State>

    public static func manual(startingAt date: Date) -> SessionClock {
        SessionClock(instant: date, followsWallClock: false)
    }

    public static func wall() -> SessionClock {
        SessionClock(instant: Date(), followsWallClock: true)
    }

    private init(instant: Date, followsWallClock: Bool) {
        state = Mutex(State(instant: instant, followsWallClock: followsWallClock))
    }

    public func now() -> Date {
        state.withLock { state in
            if state.followsWallClock {
                return Date()
            }
            return state.instant
        }
    }

    public func advance(by seconds: TimeInterval) {
        guard seconds > 0 else { return }
        state.withLock { state in
            guard !state.followsWallClock else { return }
            state.instant = state.instant.addingTimeInterval(seconds)
        }
    }

    public func advance(to date: Date) {
        advance(by: date.timeIntervalSince(now()))
    }
}
