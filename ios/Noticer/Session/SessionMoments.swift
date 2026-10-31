import Foundation

/// One moment worth showing on Team Wins Tonight: he noticed on his own,
/// or a cue helped. Stored on the phone only.
struct SessionMoment: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case selfNotice
        case cued
        /// He handled it after a whisper. Reads as nudged, like a cue.
        case nudge
    }

    var id: UUID
    var at: Date
    var needID: String
    var kind: Kind
    /// The need in her words, for the wins list.
    var text: String

    init(id: UUID = UUID(), at: Date, needID: String, kind: Kind, text: String) {
        self.id = id
        self.at = at
        self.needID = needID
        self.kind = kind
        self.text = text
    }
}

/// Tonight's wins, kept on the phone. Old days are dropped on load.
enum SessionMomentsStore {
    private static let key = "noticer.moments.v1"
    private static let cap = 200

    static func loadTonight() -> [SessionMoment] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        guard let data = UserDefaults.standard.data(forKey: key),
              let moments = try? JSONDecoder().decode([SessionMoment].self, from: data) else {
            return []
        }
        return moments.filter { $0.at >= startOfDay }.suffix(cap)
    }

    static func save(_ moments: [SessionMoment]) {
        let trimmed = Array(moments.suffix(cap))
        guard let data = try? JSONEncoder().encode(trimmed) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}
