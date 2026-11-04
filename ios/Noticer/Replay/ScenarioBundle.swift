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

/// Recorded glasses stills bundled from `fixtures/keyframes`. Paths are
/// bundle-relative (`water-table/0007.jpg`); anything else fails closed.
enum BundledStills {
    static func url(for image: String) -> URL? {
        guard !image.isEmpty, !image.contains("..") else { return nil }
        let url = Bundle.main.bundleURL
            .appendingPathComponent("keyframes")
            .appendingPathComponent(image)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return nil
        }
        return url
    }

    /// Bundle-relative paths of the stills actually present.
    static func availableImages() -> Set<String> {
        let root = Bundle.main.bundleURL.appendingPathComponent("keyframes")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var found = Set<String>()
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "jpg" || ext == "jpeg" else { continue }
            found.insert(String(url.path.dropFirst(root.path.count + 1)))
        }
        return found
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
