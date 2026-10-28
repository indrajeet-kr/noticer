import Foundation

public protocol RetrySleeper: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct TaskRetrySleeper: RetrySleeper {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        let clamped = max(0, seconds)
        let nanoseconds = UInt64((clamped * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public protocol JitterSource: Sendable {
    func seconds() -> TimeInterval
}

public struct SystemJitter: JitterSource {
    public init() {}

    public func seconds() -> TimeInterval {
        TimeInterval.random(in: 0...0.5)
    }
}

public struct ZeroJitter: JitterSource {
    public init() {}

    public func seconds() -> TimeInterval { 0 }
}

enum ChatCompletionRetry {
    /// 429 and 5xx are transient. 408 is a timeout. 400 and 404 are not.
    static func shouldRetry(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    static func isTransientTransport(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        guard let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// Exponential backoff plus jitter, at least `Retry-After` when that header is a number of seconds.
    static func delay(
        attempt: Int,
        initial: TimeInterval,
        maximum: TimeInterval,
        jitter: TimeInterval,
        retryAfter: TimeInterval?
    ) -> TimeInterval {
        let exponential = initial * pow(2.0, Double(attempt)) + max(0, jitter)
        var wait = min(max(0, exponential), maximum)
        if let retryAfter {
            wait = min(max(wait, retryAfter), maximum)
        }
        return wait
    }

    static func retryAfterSeconds(headers: [String: String]) -> TimeInterval? {
        guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = TimeInterval(raw) else {
            return nil
        }
        return seconds
    }
}
