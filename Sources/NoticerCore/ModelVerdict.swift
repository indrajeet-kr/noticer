import Foundation

/// `finish_reason` values the shared router understands.
/// The agent track maps any other API string to `other` before routing.
public enum FinishReason: String, Codable, Sendable, Equatable {
    case toolCalls = "tool_calls"
    case stop
    case length
    case other
}

/// The six tools. Raw values are the chat-completions function names.
public enum ToolName: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case latchNeedHypothesis = "latch_need_hypothesis"
    case deferCueWearerBusy = "defer_cue_wearer_busy"
    case logWearerIntervention = "log_wearer_intervention"
    case requestHeadStartExtension = "request_head_start_extension"
    case reportNoTransition = "report_no_transition"
    case reportNeedResolved = "report_need_resolved"
}

/// One routed model turn: a single tool plus the assessment it carried.
/// `parallel_tool_calls` is false, so this type holds one tool, not a list.
public struct ModelVerdict: Equatable, Sendable, Codable {
    public var finishReason: FinishReason
    public var tool: ToolName
    public var assessment: SceneAssessment
    /// Set only for `request_head_start_extension`. The phone grants the step, not this string.
    public var extensionReason: String?

    public init(
        finishReason: FinishReason,
        tool: ToolName,
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

public enum ModelContractError: Error, Equatable, Sendable {
    /// `finish_reason` was `length`. Callers log it and do not invent a tool call.
    case truncated
    /// `finish_reason` was `tool_calls` but no function name was present.
    case toolCallsMissingTool
    /// The finish reason was not one this router accepts.
    case unrecognizedFinishReason
}
