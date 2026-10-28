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
                extensionReason: nil
            )
            return DetailedModelCompletion(verdict: verdict, usage: usage, rawCompletion: raw)
        case FinishReason.toolCalls.rawValue:
            let calls = try toolCalls(in: message)
            if calls.isEmpty {
                throw ModelClientError.malformedResponse(
                    "finish_reason was tool_calls but the message had no tool call. content is allowed to be null; the call itself was missing."
                )
            }
            if calls.count > 1 {
                throw ModelClientError.multipleToolCalls(count: calls.count)
            }
            let call = calls[0]
            let parsed = try parseArguments(call.arguments)
            let verdict = try ModelTurnNormalizer.verdict(
                finishReason: .toolCalls,
                tool: call.name,
                assessment: parsed.assessment,
                extensionReason: parsed.extensionReason
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
                "Tool \(nameRaw) is not one of the five Noticer tools."
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

        var fields = object
        var extensionReason: String?
        if let reason = fields.removeValue(forKey: ToolCatalog.extensionReasonField) {
            switch reason {
            case .string(let text):
                extensionReason = text
            case .null:
                extensionReason = nil
            default:
                throw ModelClientError.malformedResponse("extension_reason was not a string.")
            }
        }

        let assessmentData: Data
        do {
            assessmentData = try JSONEncoder().encode(JSONValue.object(fields))
        } catch {
            throw ModelClientError.malformedResponse("Tool arguments could not be read.")
        }
        do {
            let assessment = try JSONDecoder().decode(SceneAssessment.self, from: assessmentData)
            return (assessment, extensionReason)
        } catch {
            throw ModelClientError.malformedResponse(
                "Tool arguments did not match the assessment fields (\(SecretRedaction.clip(String(describing: error))))."
            )
        }
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
