import Foundation
import NoticerCore

/// One moment worth showing on Team Wins Tonight: he noticed on his own,
/// or a cue helped. Stored on the phone only.
struct SessionMoment: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Legacy "noticed" rows migrate to selfNotice. Unknown values
        /// throw so the row-level catch skips just that row.
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if raw == "noticed" {
                self = .selfNotice
                return
            }
            guard let known = Self(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown moment kind")
            }
            self = known
        }

        /// Completed before any cue in its episode, or completed outside
        /// any episode. The only unprompted kind.
        case selfNotice
        /// A reminder row. Shown, but never counted as a win. Upgraded to
        /// nudge in place when its episode completes after the cue.
        case cued
        /// Completed after a cue in that same episode.
        case nudge

        /// Help with no cue behind it.
        var isUnprompted: Bool {
            self == .selfNotice
        }

        /// A completed win: done with or without a reminder. Cued rows
        /// are reminders, not wins.
        var isWin: Bool {
            self == .selfNotice || self == .nudge
        }
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
    /// The engine episode, when the moment belongs to one. A cue and its
    /// completion share it; the upgrade matches on this, never on need
    /// and time alone. Nil for unprompted completions and legacy rows.
    var episodeID: String?

    init(id: UUID = UUID(), at: Date, needID: String, kind: Kind, text: String, sessionID: UUID? = nil, sharedWithPartner: Bool? = nil, episodeID: String? = nil) {
        self.id = id
        self.at = at
        self.needID = needID
        self.kind = kind
        self.text = text
        self.sessionID = sessionID
        self.sharedWithPartner = sharedWithPartner
        self.episodeID = episodeID
    }
}

/// One stored row, good or bad. Decoding never throws: a bad row
/// keeps its short reason so the load can log and skip it.
private struct FailableMoment: Decodable {
    var moment: SessionMoment?
    var reason: String

    init(from decoder: Decoder) throws {
        do {
            moment = try SessionMoment(from: decoder)
            reason = "decode"
        } catch let error as DecodingError {
            moment = nil
            switch error {
            case .dataCorrupted: reason = "corrupt"
            case .keyNotFound: reason = "key"
            case .typeMismatch: reason = "type"
            case .valueNotFound: reason = "value"
            @unknown default: reason = "decode"
            }
        } catch {
            moment = nil
            reason = "decode"
        }
    }
}

/// Tonight's wins, kept on the phone. Old days are dropped on load.
enum SessionMomentsStore {
    static let key = "noticer.moments.v1"
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
    /// Loads row by row: one bad row logs `decode-skip` and the rest
    /// still load. `log` takes the line without its TONIGHT tag.
    static func loadRecent(
        defaults: UserDefaults = .standard,
        log: ((String) -> Void)? = nil
    ) -> [SessionMoment] {
        guard let data = defaults.data(forKey: key),
              let rows = try? JSONDecoder().decode([FailableMoment].self, from: data) else {
            return []
        }
        var moments: [SessionMoment] = []
        moments.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if let moment = row.moment {
                moments.append(moment)
            } else {
                log?("decode-skip index=\(index) reason=\(row.reason)")
            }
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
