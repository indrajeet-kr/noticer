import Foundation
import NoticerAgent
import NoticerCore

/// The app talks to models only through `ModelClient`.
enum AgentSeam {
    static let liveModelID = MuseSparkModelClient.modelID

    static func makeLiveClient() -> MuseSparkModelClient {
        MuseSparkModelClient(apiKey: ModelKeyStore.currentKey())
    }
}
