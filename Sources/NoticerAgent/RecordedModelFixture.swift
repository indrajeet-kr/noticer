import Foundation
import NoticerCore

/// A cached model turn. `rawCompletion` is reserved for the real HTTP body.
/// Step 0 reads `normalized` and routes it with `ModelTurnNormalizer`.
public struct RecordedModelFixture: Equatable, Sendable, Codable {
    public var fixtureID: String
    public var normalized: NormalizedModelTurn
    public var rawCompletion: JSONValue?

    public init(
        fixtureID: String,
        normalized: NormalizedModelTurn,
        rawCompletion: JSONValue? = nil
    ) {
        self.fixtureID = fixtureID
        self.normalized = normalized
        self.rawCompletion = rawCompletion
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
    }
}
