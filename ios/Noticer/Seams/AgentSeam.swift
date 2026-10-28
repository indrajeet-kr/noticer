import Foundation
import NoticerAgent
import NoticerCore

/// The app talks to models only through `ModelClient`.
enum AgentSeam {
    static let liveModelID = MuseSparkModelClient.modelID

    /// A saved key uses the live chat-completions client. No key stays offline
    /// and fails with `missingAPIKey` when a turn is sent. Replay does not call this.
    static func makeLiveClient() -> any ModelClient {
        guard let key = ModelKeyStore.currentKey(), !key.isEmpty else {
            return MuseSparkModelClient(apiKey: nil)
        }
        return MuseSparkModelClient.live(apiKey: key)
    }
}
