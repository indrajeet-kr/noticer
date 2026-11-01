import Foundation
import NoticerCore

public struct DetailedModelCompletion: Equatable, Sendable {
    public var verdict: ModelVerdict
    public var usage: ModelUsage?
    public var rawCompletion: JSONValue?

    public init(verdict: ModelVerdict, usage: ModelUsage?, rawCompletion: JSONValue?) {
        self.verdict = verdict
        self.usage = usage
        self.rawCompletion = rawCompletion
    }
}

struct ParsedToolCall: Equatable {
    var name: ToolName
    var arguments: JSONValue
}

enum ChatCompletionResponse {
    /// `resolved_by` onto the engine's resolution. Unknown strings pass
    /// through raw; the engine validator drops what it doesn't recognize.
    static func resolution(forResolvedBy raw: String) -> Resolution {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "wearer":
            return .caughtHimself
        case "other_adult":
            return .resolvedByPartner
        case "unclear":
            return .unknown
        default:
            return Resolution(rawValue: raw)
        }
    }

    static func parse(data: Data, rates: UsageCostRates) throws -> DetailedModelCompletion {
        let raw: JSONValue
        do {
            raw = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ModelClientError.malformedResponse("The completion body was not JSON.")
        }
        guard case .object(let root) = raw else {
            throw ModelClientError.malformedResponse("The completion body was not a JSON object.")
        }
        guard case .array(let choices)? = root["choices"], let first = choices.first, case .object(let choice) = first else {
            throw ModelClientError.malformedResponse("The completion had no choices.")
        }
        let usage = ModelUsage.read(usage: root["usage"], rates: rates)
        let message = object(choice["message"]) ?? [:]
        let finishRaw = string(choice["finish_reason"]) ?? ""
        // Branch on finish_reason. A non-null content string does not outrank a tool call.
        let prose = proseText(message["content"])

        switch finishRaw {
        case FinishReason.length.rawValue:
            do {
                _ = try ModelTurnNormalizer.verdict(finishReason: .length, tool: nil)
            } catch ModelContractError.truncated {
                throw ModelClientError.responseTruncated(
                    message: "finish_reason was length. The token cap cut the turn off before a tool call finished. Reasoning tokens count toward max_tokens, so raise the cap to at least \(MuseSparkModelClient.minimumMaxTokens) or leave it unset.",
                    usage: usage
                )
            }
            throw ModelClientError.responseTruncated(
                message: "finish_reason was length.",
                usage: usage
            )
        case FinishReason.stop.rawValue:
            let verdict = try ModelTurnNormalizer.verdict(
                finishReason: .stop,
                tool: nil,
                assessment: SceneAssessment(),
                extensionReason: nil,
                content: prose
            )
            return DetailedModelCompletion(verdict: verdict, usage: usage, rawCompletion: raw)
        case FinishReason.toolCalls.rawValue:
            let calls = try toolCalls(in: message)
            if calls.isEmpty {
                throw ModelClientError.malformedResponse(
                    "finish_reason was tool_calls but the message had no tool call. A content string does not replace the call."
                )
            }
            if calls.count > 1 {
                throw ModelClientError.multipleToolCalls(count: calls.count)
            }
            let call = calls[0]
            let parsed = try parseArguments(call.arguments)
            // tool_calls wins when the same message also has content.
            let verdict = try ModelTurnNormalizer.verdict(
                finishReason: .toolCalls,
                tool: call.name,
                assessment: parsed.assessment,
                extensionReason: parsed.extensionReason,
                content: prose
            )
            return DetailedModelCompletion(verdict: verdict, usage: usage, rawCompletion: raw)
        default:
            do {
                _ = try ModelTurnNormalizer.verdict(finishReason: .other, tool: nil)
            } catch {
                throw ModelClientError.malformedResponse(
                    "finish_reason \"\(finishRaw)\" is not tool_calls, stop, or length."
                )
            }
            throw ModelClientError.malformedResponse(
                "finish_reason \"\(finishRaw)\" is not tool_calls, stop, or length."
            )
        }
    }

    static func toolCalls(in message: [String: JSONValue]) throws -> [ParsedToolCall] {
        switch message["tool_calls"] {
        case .none, .some(.null):
            return []
        case .some(.array(let calls)):
            return try calls.map(oneCall)
        default:
            throw ModelClientError.malformedResponse("tool_calls was not an array.")
        }
    }

    private static func oneCall(_ value: JSONValue) throws -> ParsedToolCall {
        guard case .object(let call) = value else {
            throw ModelClientError.malformedResponse("A tool call was not an object.")
        }
        let function = object(call["function"]) ?? call
        guard let nameRaw = string(function["name"]) else {
            throw ModelClientError.malformedResponse("A tool call had no function name.")
        }
        guard let name = ToolName(rawValue: nameRaw) else {
            throw ModelClientError.malformedResponse(
                "Tool \(nameRaw) is not one of the six Noticer tools."
            )
        }
        let arguments = function["arguments"] ?? .object([:])
        return ParsedToolCall(name: name, arguments: arguments)
    }

    static func parseArguments(_ value: JSONValue) throws -> (assessment: SceneAssessment, extensionReason: String?) {
        let object: [String: JSONValue]
        switch value {
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                throw ModelClientError.malformedResponse("Tool arguments were not UTF-8 JSON.")
            }
            let decoded: JSONValue
            do {
                decoded = try JSONDecoder().decode(JSONValue.self, from: data)
            } catch {
                throw ModelClientError.malformedResponse("Tool arguments were not JSON.")
            }
            guard case .object(let parsed) = decoded else {
                throw ModelClientError.malformedResponse("Tool arguments were not a JSON object.")
            }
            object = parsed
        case .object(let parsed):
            object = parsed
        case .null:
            object = [:]
        default:
            throw ModelClientError.malformedResponse("Tool arguments were not a JSON object.")
        }

        var fields = normalizeAssessmentFields(object)
        var extensionReason: String?
        if let reason = fields.removeValue(forKey: ToolCatalog.extensionReasonField) {
            switch reason {
            case .string(let text):
                extensionReason = isNullPlaceholder(text) ? nil : text
            case .null:
                extensionReason = nil
            default:
                throw ModelClientError.malformedResponse("extension_reason was not a string.")
            }
        }
        // Only the resolution tool sends this. It wins over a resolution
        // riding alongside, so the engine API stays the same.
        var resolvedBy: String?
        if let raw = fields.removeValue(forKey: ToolCatalog.resolvedByField) {
            switch raw {
            case .string(let text):
                resolvedBy = isNullPlaceholder(text) ? nil : text
            case .null:
                resolvedBy = nil
            default:
                throw ModelClientError.malformedResponse("resolved_by was not a string.")
            }
        }

        let assessmentData: Data
        do {
            assessmentData = try JSONEncoder().encode(JSONValue.object(fields))
        } catch {
            throw ModelClientError.malformedResponse("Tool arguments could not be read.")
        }
        do {
            var assessment = try JSONDecoder().decode(SceneAssessment.self, from: assessmentData)
            if let resolvedBy {
                assessment.resolution = Self.resolution(forResolvedBy: resolvedBy)
            }
            return (assessment, extensionReason)
        } catch {
            throw ModelClientError.malformedResponse(
                "Tool arguments did not match the assessment fields (\(SecretRedaction.clip(String(describing: error))))."
            )
        }
    }

    private static let booleanFields: Set<String> = [
        AssessmentField.sustainedAcrossStrip,
        AssessmentField.wearerHandsOccupied,
        AssessmentField.partnerInView,
        AssessmentField.wearerHandsVisible,
        AssessmentField.partnerAsleep,
    ]

    private static let nullableStringFields: Set<String> = [
        AssessmentField.resolution,
        AssessmentField.actionCode,
    ]

    private static func isNullPlaceholder(_ raw: String) -> Bool {
        let folded = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded.isEmpty || folded == "null" || folded == "nil" || folded == "none"
    }

    /// Strict-mode tool replies sometimes quote `null`, `true`, `false`, or numbers
    /// as JSON strings. Coerce those literals so valid model turns don't fail decoding.
    private static func normalizeAssessmentFields(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var result = fields
        for (key, value) in fields {
            guard case .string(let text) = value else { continue }
            let folded = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if booleanFields.contains(key) {
                if isNullPlaceholder(folded) {
                    result[key] = .null
                } else if folded == "true" {
                    result[key] = .bool(true)
                } else if folded == "false" {
                    result[key] = .bool(false)
                }
            } else if nullableStringFields.contains(key) {
                if isNullPlaceholder(folded) {
                    result[key] = .null
                }
            } else if key == AssessmentField.confidence {
                if isNullPlaceholder(folded) {
                    result[key] = .null
                } else if let number = Double(folded) {
                    result[key] = .number(number)
                }
            } else if key == AssessmentField.partnerStateEvidence, isNullPlaceholder(folded) {
                result[key] = .null
            }
        }
        return result
    }
}

struct APIErrorBody: Equatable {
    var message: String
    var code: String?
}

enum APIErrorParser {
    static func parse(_ data: Data) -> APIErrorBody {
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let root) = raw,
              case .object(let error)? = root["error"] else {
            let text = String(data: data, encoding: .utf8) ?? ""
            return APIErrorBody(message: SecretRedaction.clip(text), code: nil)
        }
        let message = string(error["message"]) ?? "The model API returned an error."
        let code = string(error["code"])
        return APIErrorBody(message: SecretRedaction.clip(message), code: code)
    }
}

private func object(_ value: JSONValue?) -> [String: JSONValue]? {
    guard case .object(let object)? = value else {
        return nil
    }
    return object
}

private func string(_ value: JSONValue?) -> String? {
    guard case .string(let text)? = value else {
        return nil
    }
    return text
}

/// Assistant prose, when the message carried a string. Null, arrays, and blanks are ignored.
private func proseText(_ value: JSONValue?) -> String? {
    guard let text = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        return nil
    }
    return text
}
