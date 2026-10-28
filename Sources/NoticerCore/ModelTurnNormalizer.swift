import Foundation

/// Routes `finish_reason` the way the PRD's contract sentence describes.
///
/// - `stop` becomes `report_no_transition`, even if a tool name was also present.
/// - `tool_calls` keeps that tool.
/// - `length` throws. It is not a silent no-op.
///
/// This does not check `need_id`, action codes, rate limits, or confidence.
public enum ModelTurnNormalizer {
    public static func verdict(
        finishReason: FinishReason,
        tool: ToolName?,
        assessment: SceneAssessment = SceneAssessment(),
        extensionReason: String? = nil
    ) throws -> ModelVerdict {
        switch finishReason {
        case .stop:
            return ModelVerdict(
                finishReason: .stop,
                tool: .reportNoTransition,
                assessment: assessment,
                extensionReason: nil
            )
        case .toolCalls:
            guard let tool else {
                throw ModelContractError.toolCallsMissingTool
            }
            return ModelVerdict(
                finishReason: .toolCalls,
                tool: tool,
                assessment: assessment,
                extensionReason: extensionReason
            )
        case .length:
            throw ModelContractError.truncated
        case .other:
            throw ModelContractError.unrecognizedFinishReason
        }
    }
}
