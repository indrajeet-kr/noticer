import Foundation
import NoticerCore

/// Builds the chat-completions body. Images are inline keyframes, not files.
enum ChatCompletionRequest {
    static let maxImages = 50

    static func body(request: ModelRequest, configuration: MuseSparkConfiguration) throws -> Data {
        try JSONEncoder().encode(json(request: request, configuration: configuration))
    }

    static func json(request: ModelRequest, configuration: MuseSparkConfiguration) throws -> JSONValue {
        if request.keyframes.count > maxImages {
            throw ModelClientError.invalidConfiguration(
                "A chat completion accepts at most \(maxImages) images. This request has \(request.keyframes.count)."
            )
        }
        var root: [String: JSONValue] = [
            "model": .string(configuration.modelID),
            "messages": .array([
                .object([
                    "role": .string(MuseSparkModelClient.instructionRole),
                    "content": .string(configuration.developerPrompt),
                ]),
                .object([
                    "role": .string("user"),
                    "content": userContent(request),
                ]),
            ]),
            "tools": .array(MetaToolSchema.wireTools()),
            "tool_choice": .string(MuseSparkModelClient.toolChoice),
            "parallel_tool_calls": .bool(MuseSparkModelClient.parallelToolCalls),
            "reasoning_effort": .string(configuration.reasoningEffort),
        ]
        if let maxTokens = configuration.maxTokens {
            root["max_tokens"] = .number(Double(maxTokens))
        }
        return .object(root)
    }

    private static func userContent(_ request: ModelRequest) -> JSONValue {
        var parts: [JSONValue] = [
            .object([
                "type": .string("text"),
                "text": .string(sceneText(request)),
            ]),
        ]
        for (ordinal, frame) in orderedKeyframes(request.keyframes).enumerated() {
            parts.append(.object([
                "type": .string("text"),
                "text": .string(
                    "kf\(ordinal + 1) id=\(frame.id) age_seconds=\(frame.ageSeconds)"
                ),
            ]))
            let encoded = frame.jpegData.base64EncodedString()
            parts.append(.object([
                "type": .string("image_url"),
                "image_url": .object([
                    "url": .string("data:image/jpeg;base64,\(encoded)"),
                ]),
            ]))
        }
        return .array(parts)
    }

    /// Oldest keyframe first. Equal ages keep the caller's order.
    private static func orderedKeyframes(_ keyframes: [Keyframe]) -> [Keyframe] {
        keyframes.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.ageSeconds == rhs.element.ageSeconds {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.ageSeconds > rhs.element.ageSeconds
            }
            .map(\.element)
    }

    static func sceneText(_ request: ModelRequest) -> String {
        var lines = ["Needs:"]
        if request.needs.isEmpty {
            lines.append("(none)")
        } else {
            for need in request.needs {
                lines.append("need_id=\(need.id)")
                if need.visualCondition == nil {
                    lines.append("author_text=\(need.authorText)")
                }
                if let visual = need.visualCondition {
                    lines.append("visual_condition=\(visual)")
                }
                if let unknown = need.unknownCondition?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !unknown.isEmpty {
                    if let handled = need.handledCondition {
                        lines.append("handled_when=\(handled)")
                    }
                    lines.append("unknown_when=\(unknown)")
                }
                if let signal = need.selfNoticeSignal {
                    lines.append("self_notice_signal=\(signal)")
                }
                if need.isUrgent {
                    lines.append("urgent=true")
                }
            }
        }
        if request.openNeeds.isEmpty {
            lines.append("Open now: (none)")
        } else {
            lines.append("Open now:")
            for open in request.openNeeds {
                let matchingNeed = request.needs.first { $0.id == open.needID }
                let problem: String = {
                    let trimmed = open.problemCondition.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                    return matchingNeed?.visualCondition ?? matchingNeed?.authorText ?? "unspecified"
                }()
                let handled: String = {
                    let trimmed = open.resolutionSignal.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || trimmed == matchingNeed?.visualCondition {
                        return NeedEngine<SystemClock>.resolutionSignal(for: matchingNeed)
                    }
                    return trimmed
                }()
                var openLine = "need_id=\(open.needID) cue_spoken=\(open.cueSpoken) problem=\(problem) handled_when=\(handled)"
                if let acted = open.wearerActedSecondsAgo {
                    openLine += " wearer_acted_seconds_ago=\(Int(acted))"
                }
                lines.append(openLine)
            }
        }
        if let focus = request.focusNeedID {
            lines.append("focus=\(focus) (check only this need)")
        }
        if !request.unpromptedStartedIDs.isEmpty {
            lines.append("Started by wearer: \(request.unpromptedStartedIDs.joined(separator: ", "))")
        }
        lines.append("Keyframes follow, oldest first.")
        return lines.joined(separator: "\n")
    }
}

/// Meta rejects `strict: true` unless `required` lists every property.
/// `ToolCatalog` keeps the narrower required subsets. This adapts the wire schema
/// by listing every property and allowing null for the ones the catalog does not require.
enum MetaToolSchema {
    static func wireTools() -> [JSONValue] {
        ToolCatalog.all.map(wireEntry)
    }

    static func wireEntry(_ tool: ToolDefinition) -> JSONValue {
        guard case .object(var entry) = tool.chatCompletionsEntry,
              case .object(var function)? = entry["function"],
              let parameters = function["parameters"] else {
            return tool.chatCompletionsEntry
        }
        function["parameters"] = strictParameters(parameters, catalogRequired: tool.requiredParameterNames())
        function["strict"] = .bool(true)
        entry["function"] = .object(function)
        return .object(entry)
    }

    static func strictParameters(_ parameters: JSONValue, catalogRequired: [String]) -> JSONValue {
        guard case .object(var root) = parameters,
              case .object(let properties)? = root["properties"] else {
            return parameters
        }
        let requiredSet = Set(catalogRequired)
        var wired: [String: JSONValue] = [:]
        for (name, schema) in properties {
            if requiredSet.contains(name) {
                wired[name] = schema
            } else {
                wired[name] = .object([
                    "anyOf": .array([
                        schema,
                        .object(["type": .string("null")]),
                    ]),
                ])
            }
        }
        var required = catalogRequired.filter { properties[$0] != nil }
        let extras = properties.keys.filter { !requiredSet.contains($0) }.sorted()
        required.append(contentsOf: extras)
        root["type"] = .string("object")
        root["additionalProperties"] = .bool(false)
        root["properties"] = .object(wired)
        root["required"] = .array(required.map(JSONValue.string))
        return .object(root)
    }
}
