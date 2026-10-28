import Foundation

public enum CueKind: String, Codable, Sendable, Equatable {
    /// Spoken offer, routed to the glasses speaker.
    case whisper
    /// Quiet phase: a sound with no words.
    case chime
    /// Used only after an inconclusive re-check when mom allowed it.
    case checkIn = "check_in"
}

/// A cue the engine asks the speaker to play. Building and scheduling one is core-track work.
public struct Cue: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var needID: String
    public var text: String
    public var kind: CueKind
    public var createdAt: Date

    public init(id: String, needID: String, text: String, kind: CueKind, createdAt: Date) {
        self.id = id
        self.needID = needID
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case needID = "need_id"
        case text
        case kind
        case createdAt = "created_at"
    }
}
