import Foundation
import NoticerCore

/// Activity persistence: one JSON file beside the session logs.
enum ActivityFileStore {
    static let fileName = "activity.json"

    static func url(baseURL: URL? = nil) -> URL? {
        if let baseURL {
            return baseURL.appendingPathComponent(fileName)
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent(SessionLogStore.folderName).appendingPathComponent(fileName)
    }

    static func load(baseURL: URL? = nil) -> ActivityPersisted? {
        guard let url = url(baseURL: baseURL),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ActivityPersisted.self, from: data)
    }

    static func save(_ persisted: ActivityPersisted, baseURL: URL? = nil) {
        guard let url = url(baseURL: baseURL),
              let data = try? JSONEncoder().encode(persisted) else {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Serializes activity saves off the main thread, in call order.
actor ActivitySaver {
    static let shared = ActivitySaver()

    func save(_ persisted: ActivityPersisted, baseURL: URL?) {
        ActivityFileStore.save(persisted, baseURL: baseURL)
    }
}
