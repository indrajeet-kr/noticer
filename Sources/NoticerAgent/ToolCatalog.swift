import Foundation
import NoticerCore

/// One function tool in the chat-completions `tools` array.
public struct ToolDefinition: Equatable, Sendable {
    public var name: ToolName
    public var description: String
    public var strict: Bool
    public var parameters: JSONValue

    public init(name: ToolName, description: String, strict: Bool = true, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.strict = strict
        self.parameters = parameters
    }

    public var chatCompletionsEntry: JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name.rawValue),
                "description": .string(description),
                "strict": .bool(strict),
                "parameters": parameters,
            ]),
        ])
    }

    public func parameterPropertyNames() -> [String] {
        guard case .object(let root) = parameters,
              case .object(let properties)? = root["properties"] else {
            return []
        }
        return properties.keys.sorted()
    }

    public func requiredParameterNames() -> [String] {
        guard case .object(let root) = parameters,
              case .array(let required)? = root["required"] else {
            return []
        }
        return required.compactMap { value in
            if case .string(let name) = value {
                return name
            }
            return nil
        }
    }

    public func allowsAdditionalProperties() -> Bool {
        guard case .object(let root) = parameters,
              case .bool(let allowed)? = root["additionalProperties"] else {
            return true
        }
        return allowed
    }
}

/// The six tools. Schemas describe arguments. They do not enforce caps.
///
/// Every tool's properties include the shared assessment fields. Required
/// subsets differ. `extension_reason` exists only on the head-start tool and
/// `resolved_by` only on the resolution tool.
/// `strict` is true. Whether Meta requires every property to also be required
/// is unconfirmed; see CONTRIBUTING.
public enum ToolCatalog {
    public static let extensionReasonField = "extension_reason"
    public static let resolvedByField = "resolved_by"
    public static let resolvedByValues = ["wearer", "other_adult", "unclear"]

    public static let all: [ToolDefinition] = [
        latchNeedHypothesis,
        deferCueWearerBusy,
        logWearerIntervention,
        requestHeadStartExtension,
        reportNoTransition,
        reportNeedResolved,
    ]

    public static func chatCompletionsTools() -> [JSONValue] {
        all.map(\.chatCompletionsEntry)
    }

    public static func definition(named name: ToolName) -> ToolDefinition? {
        all.first { $0.name == name }
    }

    private static let latchNeedHypothesis = ToolDefinition(
        name: .latchNeedHypothesis,
        description: "Open an unmet need, including when already true in the older keyframe.",
        parameters: objectSchema(
            properties: assessmentProperties(),
            required: [
                AssessmentField.needID,
                AssessmentField.sustainedAcrossStrip,
                AssessmentField.partnerStateEvidence,
                AssessmentField.wearerHandsOccupied,
                AssessmentField.confidence,
            ]
        )
    )

    private static let deferCueWearerBusy = ToolDefinition(
        name: .deferCueWearerBusy,
        description: "Hold the whisper.",
        parameters: objectSchema(
            properties: assessmentProperties(),
            required: [
                AssessmentField.needID,
                AssessmentField.wearerHandsOccupied,
            ]
        )
    )

    private static let logWearerIntervention = ToolDefinition(
        name: .logWearerIntervention,
        description: "Record a wearer action.",
        parameters: objectSchema(
            properties: assessmentProperties(),
            required: [
                AssessmentField.needID,
                AssessmentField.actionCode,
            ]
        )
    )

    private static let requestHeadStartExtension = ToolDefinition(
        name: .requestHeadStartExtension,
        description: "Ask for more time before a cue.",
        parameters: objectSchema(
            properties: assessmentProperties().merging([
                extensionReasonField: jsonString(),
            ]) { _, new in new },
            required: [
                AssessmentField.needID,
                extensionReasonField,
            ]
        )
    )

    private static let reportNoTransition = ToolDefinition(
        name: .reportNoTransition,
        description: "No need is visibly unmet and no open need changed. A problem already visible is not this tool.",
        parameters: objectSchema(
            properties: assessmentProperties(),
            required: []
        )
    )

    private static let reportNeedResolved = ToolDefinition(
        name: .reportNeedResolved,
        description: "An open need is handled. Say who.",
        parameters: objectSchema(
            properties: assessmentProperties().merging([
                resolvedByField: jsonStringEnum(resolvedByValues),
            ]) { _, new in new },
            required: [
                AssessmentField.needID,
                resolvedByField,
            ]
        )
    )
}

private func objectSchema(properties: [String: JSONValue], required: [String]) -> JSONValue {
    .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object(properties),
        "required": .array(required.map(JSONValue.string)),
    ])
}

private func jsonString() -> JSONValue {
    .object(["type": .string("string")])
}

private func jsonBool() -> JSONValue {
    .object(["type": .string("boolean")])
}

private func jsonNumber() -> JSONValue {
    .object(["type": .string("number")])
}

private func jsonStringArray() -> JSONValue {
    .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
    ])
}

private func jsonStringEnum(_ values: [String]) -> JSONValue {
    .object([
        "type": .string("string"),
        "enum": .array(values.map(JSONValue.string)),
    ])
}

private func assessmentProperties() -> [String: JSONValue] {
    [
        AssessmentField.needID: jsonString(),
        AssessmentField.sustainedAcrossStrip: jsonBool(),
        AssessmentField.partnerStateEvidence: jsonStringArray(),
        AssessmentField.wearerHandsOccupied: jsonBool(),
        AssessmentField.partnerInView: jsonBool(),
        AssessmentField.wearerHandsVisible: jsonBool(),
        AssessmentField.resolution: jsonStringEnum(Resolution.recognized.map(\.rawValue)),
        AssessmentField.actionCode: jsonString(),
        AssessmentField.confidence: jsonNumber(),
        AssessmentField.partnerAsleep: jsonBool(),
        AssessmentField.evidenceKeyframeIDs: jsonStringArray(),
        AssessmentField.newestAnchorState: jsonStringEnum(AnchorState.recognized.map(\.rawValue)),
    ]
}
