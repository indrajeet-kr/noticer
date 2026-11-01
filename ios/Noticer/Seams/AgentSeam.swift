import Foundation
import NoticerAgent
import NoticerCore

/// The app talks to models only through `ModelClient`.
enum AgentSeam {
    static let liveModelID = MuseSparkModelClient.modelID

    /// Debug switch for frame capture. Read when the live client is
    /// built, so the toggle takes effect at the next Start.
    static let frameCaptureDefaultsKey = "debug.frameCapture"

    /// A saved key uses the live chat-completions client. No key stays offline
    /// and fails with `missingAPIKey` when a turn is sent. Replay does not call this.
    static func makeLiveClient(
        log: @escaping @Sendable (String, String) -> Void,
        needs: [Need],
        mode: String = "live"
    ) -> any ModelClient {
        guard let key = ModelKeyStore.currentKey(), !key.isEmpty else {
            return MuseSparkModelClient(apiKey: nil)
        }
        // Scene checks favor speed: minimal reasoning keeps the latch call
        // fast, and max_tokens stays omitted so a turn never truncates.
        // One-line rollback if latch quality drops: delete this override.
        var configuration = MuseSparkConfiguration()
        configuration.reasoningEffort = "minimal"
        let muse = MuseSparkModelClient.live(apiKey: key, configuration: configuration, log: log)
        guard UserDefaults.standard.bool(forKey: frameCaptureDefaultsKey) else {
            return LoggingModelClient(inner: muse, log: log)
        }
        let store = FrameCaptureStore(sessionStart: Date(), mode: mode, needs: needs, log: log)
        Task {
            await store.begin()
        }
        let captured = FrameCaptureModelClient(
            inner: muse,
            store: store,
            model: liveModelID,
            promptHash: FrameCapturePrompt.hash(DeveloperPrompt.text)
        )
        return LoggingModelClient(inner: captured, log: log)
    }
}
