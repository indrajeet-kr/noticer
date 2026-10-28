import Foundation

public enum ScenarioLibrary {
    public static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    public static func load(directory: URL) throws -> [ReplayScenario] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try load(urls: urls)
    }

    public static func load(urls: [URL]) throws -> [ReplayScenario] {
        let decoder = JSONDecoder()
        return try urls.map { url in
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw ScenarioError.unreadable(url.lastPathComponent)
            }
            let scenario: ReplayScenario
            do {
                scenario = try decoder.decode(ReplayScenario.self, from: data)
            } catch {
                throw ScenarioError.unreadable("\(url.lastPathComponent): \(error)")
            }
            try scenario.validate()
            return scenario
        }
    }

    /// Walks up from the calling source file until `fixtures/scenarios` exists.
    /// `#filePath` is the caller, so this works for tests and `swift run` in this repo.
    public static func sourceTreeDirectory(file: String = #filePath) -> URL? {
        var url = URL(fileURLWithPath: file).deletingLastPathComponent()
        let manager = FileManager.default
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent("fixtures/scenarios")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                break
            }
            url = parent
        }
        return nil
    }
}
