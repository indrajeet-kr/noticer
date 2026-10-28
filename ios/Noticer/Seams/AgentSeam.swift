import NoticerAgent

/// The app talks to models only through `ModelClient`.
/// Live chat completions are a stub. Recorded playback reads `fixtures/model-responses`.
enum AgentSeam {
    static let liveModelID = MuseSparkModelClient.modelID

    static func makeLiveClient() -> MuseSparkModelClient {
        MuseSparkModelClient.fromEnvironment()
    }
}
