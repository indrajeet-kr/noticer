import Foundation

/// Routes `finish_reason` the way the PRD's contract sentence describes.
///
/// Branch on `finish_reason`, not on whether `content` is null.
/// - `stop` becomes `report_no_transition`, even if a tool name or prose was also present.
/// - `tool_calls` keeps that tool. Muse Spark 1.3 can return a non-null `content`
///   string beside `tool_calls`. The tool wins. The string is not a verdict.
/// - `length` throws. It is not a silent no-op.
///
/// This does not check `need_id`, action codes, rate limits, or confidence.
public enum ModelTurnNormalizer {
    public static func verdict(
        finishReason: FinishReason,
        tool: ToolName?,
        assessment: SceneAssessment = SceneAssessment(),
        extensionReason: String? = nil,
        content: String? = nil
    ) throws -> ModelVerdict {
        switch finishReason {
        case .stop:
            // Prose in `content` is not a tool call.
            _ = content
            return ModelVerdict(
                finishReason: .stop,
                tool: .reportNoTransition,
                assessment: assessment,
                extensionReason: nil
            )
        case .toolCalls:
            // A content string may sit beside the tool call. It does not replace it.
            _ = content
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
