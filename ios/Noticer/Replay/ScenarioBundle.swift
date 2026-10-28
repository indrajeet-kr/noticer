import Foundation
import NoticerPipeline

enum ScenarioBundleError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message):
            return message
        }
    }
}

/// Scenario JSON bundled from `fixtures/scenarios`. No clip and no API key.
enum BundledScenarios {
    static func load() throws -> [ReplayScenario] {
        let urls = resourceURLs()
        guard !urls.isEmpty else {
            return []
        }
        do {
            return try ScenarioLibrary.load(urls: urls)
        } catch {
            throw ScenarioBundleError.unreadable(String(describing: error))
        }
    }

    private static func resourceURLs() -> [URL] {
        var found: [URL] = []
        if let folder = Bundle.main.url(forResource: "scenarios", withExtension: nil) {
            let nested = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )) ?? []
            found.append(contentsOf: nested)
        }
        found.append(contentsOf: Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "scenarios") ?? [])
        var seen = Set<String>()
        return found
            .filter { $0.pathExtension.lowercased() == "json" }
            .filter { $0.deletingLastPathComponent().lastPathComponent == "scenarios" }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
