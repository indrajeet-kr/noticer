import Foundation
import NoticerAgent
import NoticerCore

/// The app talks to models only through `ModelClient`.
enum AgentSeam {
    static let liveModelID = MuseSparkModelClient.modelID

    /// A saved key uses the live chat-completions client. No key stays offline
    /// and fails with `missingAPIKey` when a turn is sent. Replay does not call this.
    static func makeLiveClient(log: @escaping @Sendable (String, String) -> Void) -> any ModelClient {
        guard let key = ModelKeyStore.currentKey(), !key.isEmpty else {
            return MuseSparkModelClient(apiKey: nil)
        }
        // Scene checks favor speed: minimal reasoning keeps the latch call
        // fast, and max_tokens stays omitted so a turn never truncates.
        // One-line rollback if latch quality drops: delete this override.
        var configuration = MuseSparkConfiguration()
        configuration.reasoningEffort = "minimal"
        let inner = MuseSparkModelClient.live(apiKey: key, configuration: configuration, log: log)
        return LoggingModelClient(inner: inner, log: log)
    }
}
