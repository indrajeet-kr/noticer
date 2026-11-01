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
    /// The one slower "Again," replay of a whisper. Never a new need.
    public var isRepeat: Bool

    public init(id: String, needID: String, text: String, kind: CueKind, createdAt: Date, isRepeat: Bool = false) {
        self.id = id
        self.needID = needID
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
        self.isRepeat = isRepeat
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case needID = "need_id"
        case text
        case kind
        case createdAt = "created_at"
        case isRepeat = "is_repeat"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        needID = try container.decode(String.self, forKey: .needID)
        text = try container.decode(String.self, forKey: .text)
        kind = try container.decode(CueKind.self, forKey: .kind)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isRepeat = try container.decodeIfPresent(Bool.self, forKey: .isRepeat) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(needID, forKey: .needID)
        try container.encode(text, forKey: .text)
        try container.encode(kind, forKey: .kind)
        try container.encode(createdAt, forKey: .createdAt)
        if isRepeat {
            try container.encode(true, forKey: .isRepeat)
        }
    }
}
