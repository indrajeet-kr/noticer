import Foundation

/// What a model client needs from the phone. Prompt text and HTTP bodies are the agent track's.
/// Whether `needs` is the full list or only open needs is not decided here.
public struct ModelRequest: Equatable, Sendable {
    public var keyframes: [Keyframe]
    public var needs: [Need]

    public init(keyframes: [Keyframe], needs: [Need]) {
        self.keyframes = keyframes
        self.needs = needs
    }
}

/// Live Muse Spark, a recorded tape, or a later backend. All three return a `ModelVerdict`.
public protocol ModelClient: Sendable {
    func complete(_ request: ModelRequest) async throws -> ModelVerdict
}
