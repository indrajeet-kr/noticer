import Foundation

public struct SystemClock: Clock, Sendable {
    public init() {}

    public func now() -> Date {
        Date()
    }
}
