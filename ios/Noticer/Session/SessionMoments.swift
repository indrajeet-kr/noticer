import Foundation
import NoticerCore

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
    /// The session that recorded the moment. Nil for moments saved before
    /// session tracking existed; those use the legacy day/window fallback.
    /// Synthesized decoding reads a missing key as nil.
    var sessionID: UUID?
    /// She started it, he wrapped it up. Nil for moments saved before the
    /// shared finish existed; those decode unchanged.
    var sharedWithPartner: Bool?

    init(id: UUID = UUID(), at: Date, needID: String, kind: Kind, text: String, sessionID: UUID? = nil, sharedWithPartner: Bool? = nil) {
        self.id = id
        self.at = at
        self.needID = needID
        self.kind = kind
        self.text = text
        self.sessionID = sessionID
        self.sharedWithPartner = sharedWithPartner
    }
}

/// Tonight's wins, kept on the phone. Old days are dropped on load.
enum SessionMomentsStore {
    private static let key = "noticer.moments.v1"
    private static let sessionKey = "noticer.session.v1"
    private static let cap = 200
    /// Legacy moments join the latest session when they fall on its day
    /// and within this window of its last moment.
    static let legacyWindow: TimeInterval = 6 * 3600

    /// The latest session's boundaries, persisted alongside the moments so
    /// the Wins header can name the session's start after a restart.
    struct SessionInfo: Codable, Equatable, Sendable {
        var id: UUID
        var startedAt: Date
        var endedAt: Date?
    }

    static func loadSessionInfo(defaults: UserDefaults = .standard) -> SessionInfo? {
        guard let data = defaults.data(forKey: sessionKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SessionInfo.self, from: data)
    }

    static func saveSessionInfo(_ info: SessionInfo, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(info) else {
            return
        }
        defaults.set(data, forKey: sessionKey)
    }

    static func loadTonight() -> [SessionMoment] {
        loadRecent().filter { $0.at >= Calendar.current.startOfDay(for: Date()) }
    }

    /// Recent moments across days, newest last, capped. Views pick the
    /// latest session out of these; see `latestSessionMoments(from:)`.
    static func loadRecent(defaults: UserDefaults = .standard) -> [SessionMoment] {
        guard let data = defaults.data(forKey: key),
              let moments = try? JSONDecoder().decode([SessionMoment].self, from: data) else {
            return []
        }
        return Array(moments.suffix(cap))
    }

    static func save(_ moments: [SessionMoment], defaults: UserDefaults = .standard) {
        let trimmed = Array(moments.suffix(cap))
        guard let data = try? JSONEncoder().encode(trimmed) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    /// The latest session's moments. The Tonight timeline does not use this;
    /// it uses `TonightList` (local day, needs still on her list). Kept so
    /// a session-scoped read stays available.
    static func latestSessionMoments(from moments: [SessionMoment]) -> [SessionMoment] {
        guard !moments.isEmpty else {
            return []
        }
        let latestIdentified = moments.filter { $0.sessionID != nil }.max { $0.at < $1.at }
        let anchor = (latestIdentified ?? moments.max { $0.at < $1.at })!.at
        let anchorDay = Calendar.current.startOfDay(for: anchor)
        return moments.filter { moment in
            if let id = moment.sessionID, let anchorID = latestIdentified?.sessionID {
                return id == anchorID
            }
            return Calendar.current.startOfDay(for: moment.at) == anchorDay
                && abs(moment.at.timeIntervalSince(anchor)) <= legacyWindow
        }
    }
}

/// One wording per need: moments display the need's current words, falling
/// back to the snapshot only when the need no longer exists.
enum MomentWords {
    static func text(for moment: SessionMoment, needs: [Need]) -> String {
        if let need = needs.first(where: { $0.id == moment.needID }),
           !need.authorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return need.authorText
        }
        return moment.text
    }
}
