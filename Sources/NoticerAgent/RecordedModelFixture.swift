import Foundation
import NoticerCore

/// A cached model turn. `rawCompletion` is reserved for the real HTTP body.
/// Step 0 reads `normalized` and routes it with `ModelTurnNormalizer`.
public struct RecordedModelFixture: Equatable, Sendable, Codable {
    public var fixtureID: String
    public var normalized: NormalizedModelTurn
    public var rawCompletion: JSONValue?
    /// Set by the recording client. Older tapes omit it and still decode.
    /// Replay matches on `request.fingerprint`. Ordered playback ignores it.
    public var request: RecordedModelRequest?

    public init(
        fixtureID: String,
        normalized: NormalizedModelTurn,
        rawCompletion: JSONValue? = nil,
        request: RecordedModelRequest? = nil
    ) {
        self.fixtureID = fixtureID
        self.normalized = normalized
        self.rawCompletion = rawCompletion
        self.request = request
    }

    public func makeVerdict() throws -> ModelVerdict {
        try ModelTurnNormalizer.verdict(
            finishReason: normalized.finishReason,
            tool: normalized.tool,
            assessment: normalized.assessment,
            extensionReason: normalized.extensionReason
        )
    }

    public struct NormalizedModelTurn: Equatable, Sendable, Codable {
        public var finishReason: FinishReason
        public var tool: ToolName?
        public var assessment: SceneAssessment
        public var extensionReason: String?

        public init(
            finishReason: FinishReason,
            tool: ToolName?,
            assessment: SceneAssessment,
            extensionReason: String? = nil
        ) {
            self.finishReason = finishReason
            self.tool = tool
            self.assessment = assessment
            self.extensionReason = extensionReason
        }

        private enum CodingKeys: String, CodingKey {
            case finishReason = "finish_reason"
            case tool
            case assessment
            case extensionReason = "extension_reason"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case fixtureID = "fixture_id"
        case normalized
        case rawCompletion = "raw_completion"
        case request
    }
}

/// Request identity stored next to a cached response. JPEG bytes are not included.
public struct RecordedModelRequest: Equatable, Sendable, Codable {
    public var fingerprint: String
    public var keyframeIDs: [String]
    public var keyframeAgeMillis: [Int]
    public var keyframeByteCounts: [Int]
    public var needIDs: [String]

    public init(
        fingerprint: String,
        keyframeIDs: [String],
        keyframeAgeMillis: [Int],
        keyframeByteCounts: [Int],
        needIDs: [String]
    ) {
        self.fingerprint = fingerprint
        self.keyframeIDs = keyframeIDs
        self.keyframeAgeMillis = keyframeAgeMillis
        self.keyframeByteCounts = keyframeByteCounts
        self.needIDs = needIDs
    }

    public init(modelRequest: ModelRequest) {
        self.init(
            fingerprint: ModelRequestFingerprint.make(modelRequest),
            keyframeIDs: modelRequest.keyframes.map(\.id),
            keyframeAgeMillis: modelRequest.keyframes.map { Int(($0.ageSeconds * 1000).rounded()) },
            keyframeByteCounts: modelRequest.keyframes.map(\.jpegData.count),
            needIDs: modelRequest.needs.map(\.id)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case fingerprint
        case keyframeIDs = "keyframe_ids"
        case keyframeAgeMillis = "keyframe_age_millis"
        case keyframeByteCounts = "keyframe_byte_counts"
        case needIDs = "need_ids"
    }
}
