import Foundation
import NoticerCore

/// One live Muse Spark call for Gate G0.
///
/// Pass is a `finish_reason` of `tool_calls`. `stop` is reachable but not a pass:
/// the normalizer maps it to `report_no_transition`. This type does not call Baseten.
/// Tests inject a `ModelClient`. The executable is what talks to the network.
public enum GateG0 {
    public static let probeDeveloperPrompt = """
    You are running a connectivity check for Noticer. Call the tool latch_need_hypothesis exactly once. \
    Use need_id "gate-g0", sustained_across_strip true, partner_state_evidence ["eating_one_handed"], \
    wearer_hands_occupied false, and confidence 0.5. Also set partner_in_view false, wearer_hands_visible false, \
    resolution null, and action_code null. Do not answer with prose. \
    tool_choice is auto, so you must choose that tool yourself.
    """

    public static let help = """
    Noticer Gate G0: one live Muse Spark check.

    Confirms the model is reachable, the reasoning setting is accepted, and a tool call comes back.
    Does not call Baseten. CI does not run this. The API key is read from META_API_KEY and is not printed.

    Options:
      --reasoning-effort <minimal|low|medium|high|xhigh|max>   default low
          API field reasoning_effort. "none" is rejected locally. The API returns HTTP 400 for it.
      --max-tokens <int|unset>   default unset
          API field max_tokens. Reasoning tokens count toward this cap. Values under 1024 are rejected. "unset" omits the field.
      --model <id>               default muse-spark-1.3
      --base-url <url>           default https://api.meta.ai/v1
          A full .../chat/completions URL is also accepted.
      --repeats <n>              default 1, maximum 50
          Prints each latency and an informational p95. Pass still means every call returned a tool call.
      --timeout <seconds>        default 60
      --record <directory>       save the request/response pair for replay
          JPEG bytes are not stored. Use fixtures/model-responses when you want a fixture in the repo.
      --help

    Environment (flags win):
      META_API_KEY
      NOTICER_REASONING_EFFORT
      NOTICER_MAX_TOKENS
      NOTICER_MODEL_ID
      NOTICER_BASE_URL

    Exit codes:
      0  a tool call came back
      1  configuration or a missing key
      2  the model answered, but finish_reason was not tool_calls
      3  model_not_found
      4  finish_reason length
      5  another failure

    From a Mac, in this repo:
      swift run noticer-gate-g0
      swift run noticer-gate-g0 --reasoning-effort minimal --repeats 20
    """

    public static func probeRequest() -> ModelRequest {
        let jpeg = Data(base64Encoded: GateG0JPEG.base64) ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
        return ModelRequest(
            keyframes: [
                Keyframe(
                    id: "g0",
                    capturedAt: Date(timeIntervalSince1970: 0),
                    ageSeconds: 0,
                    episodeID: "g0",
                    jpegData: jpeg
                ),
            ],
            needs: [
                Need(
                    id: "gate-g0",
                    authorText: "eating one-handed while holding the baby",
                    cueWording: "Her plate is getting cold. Maybe take the baby?",
                    visualCondition: "partner eating with one hand and holding the baby",
                    selfNoticeSignal: "wearer_hands_receiving_baby",
                    priority: 0
                ),
            ]
        )
    }

    public static func run(
        arguments: [String],
        environment: [String: String],
        client: (any ModelClient)? = nil,
        write: @escaping @Sendable (String) -> Void = { print($0) }
    ) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            write(help)
            return 0
        }

        let parsed: Parsed
        do {
            parsed = try Parsed(arguments: arguments, environment: environment)
        } catch let error as ModelClientError {
            write(String(describing: error))
            return 1
        } catch {
            write(String(describing: error))
            return 1
        }

        write("gate: G0")
        write("model: \(parsed.configuration.modelID)")
        write("endpoint: \(parsed.endpointLine)")
        write("reasoning_effort: \(parsed.configuration.reasoningEffort)")
        write("max_tokens: \(parsed.maxTokensLine)")
        write("tool_choice: \(MuseSparkModelClient.toolChoice)")

        let runner: any ModelClient
        let usageSource: MuseSparkModelClient?
        if let client {
            runner = client
            usageSource = client as? MuseSparkModelClient
        } else {
            guard let key = environment[MuseSparkModelClient.apiKeyEnvironmentVariable], !key.isEmpty else {
                write(String(describing: ModelClientError.missingAPIKey(
                    environmentVariable: MuseSparkModelClient.apiKeyEnvironmentVariable
                )))
                write("result: failed")
                return 1
            }
            let live = MuseSparkModelClient.live(
                apiKey: key,
                configuration: parsed.configuration,
                callBudget: SessionCallBudget()
            )
            usageSource = live
            if let directory = parsed.recordDirectory {
                runner = RecordingModelClient(
                    upstream: live,
                    directory: directory,
                    redactions: [key]
                )
            } else {
                runner = live
            }
        }

        let request = probeRequest()
        var latencies: [TimeInterval] = []
        for index in 1...parsed.repeats {
            let started = Date()
            do {
                let verdict = try await runner.complete(request)
                let elapsed = Date().timeIntervalSince(started)
                latencies.append(elapsed)
                write("call: \(index)")
                write("finish_reason: \(verdict.finishReason.rawValue)")
                write("tool: \(verdict.tool.rawValue)")
                write(String(format: "latency_s: %.3f", elapsed))
                writeUsage(usageSource?.lastCompletion()?.usage, write: write)
                if verdict.finishReason != .toolCalls {
                    write("result: no_tool_call")
                    writeSummary(latencies, write: write)
                    return 2
                }
            } catch let error as ModelClientError {
                let elapsed = Date().timeIntervalSince(started)
                latencies.append(elapsed)
                write("call: \(index)")
                write(String(format: "latency_s: %.3f", elapsed))
                write(String(describing: error))
                if case .responseTruncated(_, let usage) = error {
                    writeUsage(usage, write: write)
                    write("result: truncated")
                    writeSummary(latencies, write: write)
                    return 4
                }
                if case .modelNotFound = error {
                    write("result: model_not_found")
                    write("Baseten is out of scope. This check does not switch backends.")
                    writeSummary(latencies, write: write)
                    return 3
                }
                write("result: failed")
                writeSummary(latencies, write: write)
                return exitCode(error)
            } catch is CancellationError {
                write("result: failed")
                return 5
            } catch {
                write(String(describing: error))
                write("result: failed")
                return 5
            }
        }
        write("result: pass")
        writeSummary(latencies, write: write)
        return 0
    }

    private static func writeUsage(_ usage: ModelUsage?, write: (String) -> Void) {
        guard let usage else {
            return
        }
        write("prompt_tokens: \(usage.promptTokens)")
        write("completion_tokens: \(usage.completionTokens)")
        write("reasoning_tokens: \(usage.reasoningTokens)")
        write("cached_prompt_tokens: \(usage.cachedPromptTokens)")
        write(String(format: "estimated_cost_usd: %.8f", usage.estimatedCostUSD))
        if let reported = usage.reportedCostUSD {
            write(String(format: "usage_cost_usd: %.8f", reported))
        }
    }

    private static func writeSummary(_ latencies: [TimeInterval], write: (String) -> Void) {
        guard !latencies.isEmpty else {
            return
        }
        let p95 = percentile(latencies, p: 0.95)
        write(String(format: "p95_s: %.3f", p95))
        write("p95_under_8s: \(p95 < 8 ? "yes" : "no")")
    }

    private static func percentile(_ values: [TimeInterval], p: Double) -> TimeInterval {
        let sorted = values.sorted()
        let rank = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[rank]
    }

    private static func exitCode(_ error: ModelClientError) -> Int32 {
        switch error {
        case .modelNotFound:
            return 3
        case .responseTruncated:
            return 4
        case .missingAPIKey, .invalidConfiguration:
            return 1
        default:
            return 5
        }
    }
}

private struct Parsed {
    var configuration: MuseSparkConfiguration
    var repeats: Int
    var recordDirectory: URL?
    var endpointLine: String
    var maxTokensLine: String

    init(arguments: [String], environment: [String: String]) throws {
        var reasoning = environment["NOTICER_REASONING_EFFORT"] ?? MuseSparkConfiguration.defaultReasoningEffort
        var maxTokensRaw = environment["NOTICER_MAX_TOKENS"]
        var model = environment["NOTICER_MODEL_ID"] ?? MuseSparkModelClient.modelID
        var endpoint = MuseSparkModelClient.chatCompletionsURL
        if let raw = environment["NOTICER_BASE_URL"], !raw.isEmpty {
            endpoint = try MuseSparkConfiguration.endpoint(parsing: raw)
        }
        var timeout: TimeInterval = 60
        var repeats = 1
        var record: URL?
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            func value() throws -> String {
                let next = index + 1
                guard next < arguments.count else {
                    throw ModelClientError.invalidConfiguration("\(flag) needs a value.")
                }
                index = next
                return arguments[next]
            }
            switch flag {
            case "--reasoning-effort":
                reasoning = try value()
            case "--max-tokens":
                maxTokensRaw = try value()
            case "--model":
                model = try value()
            case "--base-url":
                endpoint = try MuseSparkConfiguration.endpoint(parsing: try value())
            case "--repeats":
                let raw = try value()
                guard let parsed = Int(raw), parsed >= 1, parsed <= 50 else {
                    throw ModelClientError.invalidConfiguration("--repeats must be from 1 to 50.")
                }
                repeats = parsed
            case "--timeout":
                let raw = try value()
                guard let parsed = TimeInterval(raw), parsed > 0 else {
                    throw ModelClientError.invalidConfiguration("--timeout must be a positive number of seconds.")
                }
                timeout = parsed
            case "--record":
                record = URL(fileURLWithPath: try value())
            default:
                throw ModelClientError.invalidConfiguration("Unknown argument \(flag). Run with --help.")
            }
            index += 1
        }

        let maxTokens = try Self.maxTokens(from: maxTokensRaw)
        let configuration = MuseSparkConfiguration(
            endpoint: endpoint,
            modelID: model,
            reasoningEffort: reasoning,
            maxTokens: maxTokens,
            requestTimeout: timeout,
            developerPrompt: GateG0.probeDeveloperPrompt
        )
        try configuration.validate()
        self.configuration = configuration
        self.repeats = repeats
        self.recordDirectory = record
        self.endpointLine = (try? configuration.postURL().absoluteString) ?? endpoint.absoluteString
        if let maxTokens {
            self.maxTokensLine = String(maxTokens)
        } else {
            self.maxTokensLine = "unset"
        }
    }

    private static func maxTokens(from raw: String?) throws -> Int? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "unset" || trimmed == "omit" {
            return nil
        }
        guard let value = Int(trimmed) else {
            throw ModelClientError.invalidConfiguration("max_tokens must be an integer or unset.")
        }
        return value
    }
}

enum GateG0JPEG {
    /// 16×16 white JPEG produced locally. Sent only as a keyframe on the live check.
    static let base64 = "/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYwLjMxLjEwMgD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABLAAEBAAAAAAAAAAAAAAAAAAAABwEBAAAAAAAAAAAAAAAAAAAAABABAAAAAAAAAAAAAAAAAAAAABEBAAAAAAAAAAAAAAAAAAAAAP/AABEIABAAEAMBIgACEQADEQD/2gAMAwEAAhEDEQA/AL+AD//Z"
}
