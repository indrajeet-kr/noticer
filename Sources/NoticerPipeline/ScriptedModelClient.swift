import Foundation
import NoticerAgent
import NoticerCore
import Synchronization

/// Recorded verdicts in order, then an optional repeating tail.
///
/// A 90 s head start issues a heartbeat every 8 s. The tail answers those
/// without a fixture file per call. Nothing here reads an API key.
public final class ScriptedModelClient: ModelClient, Sendable {
    private struct State: Sendable {
        var pending: [ModelVerdict]
        var tail: ModelVerdict?
    }

    private let state: Mutex<State>

    public init(verdicts: [ModelVerdict], tail: ModelVerdict? = nil) {
        state = Mutex(State(pending: verdicts, tail: tail))
    }

    public init(responses: [ScenarioResponse]) throws {
        var pending: [ModelVerdict] = []
        var tail: ModelVerdict?
        for (index, response) in responses.enumerated() {
            let verdict = try response.makeVerdict()
            if response.repeats {
                guard index == responses.count - 1 else {
                    throw ScenarioError.badRepeat
                }
                tail = verdict
            } else {
                pending.append(verdict)
            }
        }
        state = Mutex(State(pending: pending, tail: tail))
    }

    public func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        try state.withLock { state in
            if !state.pending.isEmpty {
                return state.pending.removeFirst()
            }
            if let tail = state.tail {
                return tail
            }
            throw ModelClientError.recordingExhausted
        }
    }
}
