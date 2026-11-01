import Foundation
import NoticerCore
import XCTest
@testable import NoticerAgent

final class LiveModelClientTests: XCTestCase {
    func testPlainInitializerStaysOfflineAndEnvironmentClientIsLive() {
        XCTAssertFalse(MuseSparkModelClient(apiKey: "test-key-not-real").isLive)
        XCTAssertTrue(MuseSparkModelClient.fromEnvironment().isLive)
    }

    func testRequestCarriesDeveloperRoleToolsKeyframesAndReasoning() async throws {
        let jpeg = Data([0xFF, 0xD8, 0x11, 0x22])
        let transport = ScriptedTransport(steps: [.response(httpJSON(200, completionBody(
            finishReason: "tool_calls",
            toolName: "latch_need_hypothesis",
            arguments: toolArguments([
                "need_id": "eating-one-handed",
                "sustained_across_strip": true,
                "partner_state_evidence": ["eating_one_handed", "plate_untouched"],
                "wearer_hands_occupied": false,
                "confidence": 0.7,
            ]),
            usage: sampleUsage()
        )))])
        let client = liveClient(transport: transport)
        let verdict = try await client.complete(sampleRequest(jpeg: jpeg))

        XCTAssertEqual(verdict.tool, .latchNeedHypothesis)
        XCTAssertEqual(verdict.finishReason, .toolCalls)
        XCTAssertEqual(verdict.assessment.needID, "eating-one-handed")
        XCTAssertEqual(verdict.assessment.sustainedAcrossStrip, true)
        XCTAssertEqual(verdict.assessment.partnerStateEvidence, ["eating_one_handed", "plate_untouched"])
        let request = try XCTUnwrap(transport.requests().first)
        XCTAssertEqual(request.url, MuseSparkModelClient.chatCompletionsURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-key-not-real")
        XCTAssertFalse(request.body.contains(Data("test-key-not-real".utf8)))

        let body = try decodeJSON(request.body)
        guard case .object(let root) = body else {
            return XCTFail("body was not an object")
        }
        XCTAssertEqual(root["model"], .some(.string("muse-spark-1.3")))
        XCTAssertEqual(root["tool_choice"], .some(.string("auto")))
        XCTAssertEqual(root["parallel_tool_calls"], .some(.bool(false)))
        XCTAssertEqual(root["reasoning_effort"], .some(.string("low")))
        XCTAssertNil(root["max_tokens"])
        guard case .array(let messages)? = root["messages"] else {
            return XCTFail("missing messages")
        }
        guard case .object(let developer) = messages[0], case .object(let user) = messages[1] else {
            return XCTFail("messages were not objects")
        }
        XCTAssertEqual(developer["role"], .some(.string("developer")))
        XCTAssertEqual(user["role"], .some(.string("user")))
        guard case .array(let tools)? = root["tools"] else {
            return XCTFail("missing tools")
        }
        XCTAssertEqual(tools.count, 6)
        let urls = imageURLs(in: user["content"] ?? .null)
        XCTAssertEqual(urls.count, 2)
        let decoded = Data(base64Encoded: urls[0].replacingOccurrences(of: "data:image/jpeg;base64,", with: ""))
        XCTAssertEqual(decoded, jpeg)
        let texts = textParts(in: user["content"] ?? .null)
        XCTAssertTrue(texts.contains { $0.contains("age_seconds=28") })
        let older = try XCTUnwrap(texts.firstIndex { $0.contains("age_seconds=28") })
        let newer = try XCTUnwrap(texts.firstIndex { $0.contains("age_seconds=0") })
        XCTAssertLessThan(older, newer)

        let usage = try XCTUnwrap(client.lastCompletion()?.usage)
        XCTAssertEqual(usage.promptTokens, 1000)
        XCTAssertEqual(usage.completionTokens, 100)
        XCTAssertEqual(usage.reasoningTokens, 40)
        XCTAssertEqual(usage.cachedPromptTokens, 200)
        XCTAssertNil(usage.reportedCostUSD)
        XCTAssertEqual(usage.estimatedCostUSD, 0.001455, accuracy: 0.000000001)
        XCTAssertEqual(usage.costUSD, usage.estimatedCostUSD)
    }

    func testWireSchemaRequiresEveryPropertyAndCatalogSubsetsStayNarrow() {
        let wire = MetaToolSchema.wireTools()
        XCTAssertEqual(wire.count, ToolCatalog.all.count)
        for entry in wire {
            guard case .object(let tool) = entry,
                  case .object(let function)? = tool["function"],
                  case .object(let parameters)? = function["parameters"],
                  case .object(let properties)? = parameters["properties"],
                  case .array(let required)? = parameters["required"] else {
                return XCTFail("wire tool was not a strict object")
            }
            XCTAssertEqual(function["strict"], .some(.bool(true)))
            XCTAssertEqual(parameters["additionalProperties"], .some(.bool(false)))
            let requiredNames = Set(required.compactMap { value -> String? in
                if case .string(let name) = value { return name }
                return nil
            })
            XCTAssertEqual(requiredNames, Set(properties.keys))
        }

        let report = try! XCTUnwrap(ToolCatalog.definition(named: .reportNoTransition))
        let wiredReport = MetaToolSchema.wireEntry(report)
        guard case .object(let entry) = wiredReport,
              case .object(let function)? = entry["function"],
              case .object(let parameters)? = function["parameters"],
              case .object(let properties)? = parameters["properties"],
              case .object(let needID)? = properties[AssessmentField.needID],
              case .array(let anyOf)? = needID["anyOf"] else {
            return XCTFail("optional need_id was not nullable")
        }
        XCTAssertTrue(anyOf.contains(.object(["type": .string("null")])))
        XCTAssertTrue(report.requiredParameterNames().isEmpty)
        for name in ToolName.allCases {
            XCTAssertTrue(DeveloperPrompt.text.contains(name.rawValue))
        }
        XCTAssertTrue(DeveloperPrompt.text.contains(ToolCatalog.resolvedByField))
        XCTAssertTrue(DeveloperPrompt.text.contains("other_adult"))
        XCTAssertTrue(DeveloperPrompt.text.contains(AssessmentField.partnerInView))
        XCTAssertTrue(DeveloperPrompt.text.contains(AssessmentField.wearerHandsVisible))
        XCTAssertTrue(DeveloperPrompt.text.contains(AssessmentField.wearerHandsOccupied))
        XCTAssertTrue(DeveloperPrompt.text.contains(AssessmentField.partnerAsleep))
        XCTAssertTrue(DeveloperPrompt.text.contains("report it even when no need is open"))
        XCTAssertTrue(DeveloperPrompt.text.contains("focus=<need_id>"))
    }

    func testPartnerAsleepIsOnEveryTool() {
        for definition in ToolCatalog.all {
            let entry = definition.chatCompletionsEntry
            guard case .object(let tool) = entry,
                  case .object(let function)? = tool["function"],
                  case .object(let parameters)? = function["parameters"],
                  case .object(let properties)? = parameters["properties"] else {
                return XCTFail("tool was not a strict object: \(definition.name)")
            }
            XCTAssertNotNil(
                properties[AssessmentField.partnerAsleep],
                "\(definition.name.rawValue) must carry partner_asleep"
            )
        }
    }

    func testUnsetMaxTokensIsOmittedAndLowCapIsRejectedLocally() async {
        var configuration = MuseSparkConfiguration(maxTokens: nil)
        let transport = ScriptedTransport(steps: [.response(httpJSON(200, completionBody(
            finishReason: "stop",
            content: "nothing to add"
        )))])
        let client = liveClient(configuration: configuration, transport: transport)
        let verdict = try? await client.complete(sampleRequest())
        XCTAssertEqual(verdict?.tool, .reportNoTransition)
        XCTAssertEqual(verdict?.finishReason, .stop)
        let body = try! decodeJSON(transport.requests()[0].body)
        guard case .object(let root) = body else {
            return XCTFail("body was not an object")
        }
        XCTAssertNil(root["max_tokens"])

        configuration.maxTokens = 100
        let blocked = ScriptedTransport(steps: [])
        let rejected = liveClient(configuration: configuration, transport: blocked)
        do {
            _ = try await rejected.complete(sampleRequest())
            XCTFail("expected the low cap to be rejected")
        } catch let error as ModelClientError {
            XCTAssertTrue(blocked.requests().isEmpty)
            guard case .invalidConfiguration(let message) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("1024"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testReasoningNoneNeverReachesTheTransport() async {
        let transport = ScriptedTransport(steps: [])
        let client = liveClient(
            configuration: MuseSparkConfiguration(reasoningEffort: "none"),
            transport: transport
        )
        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected none to be rejected")
        } catch let error as ModelClientError {
            XCTAssertTrue(transport.requests().isEmpty)
            guard case .invalidConfiguration(let message) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("none"))
            XCTAssertTrue(message.contains("400"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testNullContentToolCallAndReportedCost() async throws {
        var usage = sampleUsage()
        usage["cost"] = 0.42
        let transport = ScriptedTransport(steps: [.response(httpJSON(200, completionBody(
            finishReason: "tool_calls",
            content: NSNull(),
            toolName: "report_no_transition",
            arguments: toolArguments([
                "resolution": "resolved_by_partner",
                "need_id": "water",
            ]),
            usage: usage
        )))])
        let client = liveClient(transport: transport)
        let verdict = try await client.complete(sampleRequest())
        XCTAssertEqual(verdict.tool, .reportNoTransition)
        XCTAssertEqual(verdict.assessment.resolution, .resolvedByPartner)
        XCTAssertEqual(verdict.assessment.needID, "water")
        XCTAssertEqual(client.lastCompletion()?.usage?.reportedCostUSD, 0.42)
        XCTAssertEqual(client.lastCompletion()?.usage?.costUSD, 0.42)
    }

    func testLengthIsAClearErrorAndStopIgnoresProse() async throws {
        let lengthTransport = ScriptedTransport(steps: [.response(httpJSON(200, completionBody(
            finishReason: "length",
            content: NSNull(),
            usage: sampleUsage()
        )))])
        let lengthClient = liveClient(transport: lengthTransport)
        do {
            _ = try await lengthClient.complete(sampleRequest())
            XCTFail("expected length to fail")
        } catch let error as ModelClientError {
            guard case .responseTruncated(let message, let usage) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("length"))
            XCTAssertTrue(message.contains("max_tokens"))
            XCTAssertEqual(usage?.reasoningTokens, 40)
        } catch {
            XCTFail("unexpected error \(error)")
        }

        let stopTransport = ScriptedTransport(steps: [.response(httpJSON(200, completionBody(
            finishReason: "stop",
            content: "She looks fine to me."
        )))])
        let stopClient = liveClient(transport: stopTransport)
        let verdict = try await stopClient.complete(sampleRequest())
        XCTAssertEqual(verdict.finishReason, .stop)
        XCTAssertEqual(verdict.tool, .reportNoTransition)
        XCTAssertNil(verdict.assessment.needID)
    }

    func testMultipleToolCallsHaveNoContract() async {
        let transport = ScriptedTransport(steps: [.response(httpJSON(200, completionBody(
            finishReason: "tool_calls",
            toolName: "latch_need_hypothesis",
            arguments: "{}",
            extraToolName: "report_no_transition"
        )))])
        let client = liveClient(transport: transport)
        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected multiple calls to fail")
        } catch ModelClientError.multipleToolCalls(let count) {
            XCTAssertEqual(count, 2)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testModelNotFoundAndClientErrorsDoNotRetry() async {
        let secret = "super-secret-test-key"
        let notFound = ScriptedTransport(steps: [
            .response(httpJSON(404, [
                "error": [
                    "message": "The model `muse-spark-1.3` does not exist",
                    "type": "invalid_request_error",
                    "code": "model_not_found",
                ],
            ])),
            .response(httpJSON(200, completionBody(finishReason: "stop"))),
        ])
        let notFoundClient = liveClient(key: secret, transport: notFound)
        do {
            _ = try await notFoundClient.complete(sampleRequest())
            XCTFail("expected model_not_found")
        } catch ModelClientError.modelNotFound(let message) {
            XCTAssertEqual(notFound.requests().count, 1)
            XCTAssertTrue(message.contains("does not exist"))
            XCTAssertFalse(message.contains(secret))
        } catch {
            XCTFail("unexpected error \(error)")
        }

        let rejected = ScriptedTransport(steps: [
            .response(httpJSON(400, [
                "error": [
                    "message": "bad key \(secret)",
                    "type": "invalid_request_error",
                    "code": NSNull(),
                ],
            ])),
            .response(httpJSON(200, completionBody(finishReason: "stop"))),
        ])
        let rejectedClient = liveClient(key: secret, transport: rejected)
        do {
            _ = try await rejectedClient.complete(sampleRequest())
            XCTFail("expected the 400 to surface")
        } catch let error as ModelClientError {
            XCTAssertEqual(rejected.requests().count, 1)
            let description = String(describing: error)
            XCTAssertFalse(description.contains(secret))
            XCTAssertTrue(description.contains("400"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testServerErrorsAndRateLimitsRetryThenSucceed() async throws {
        let sleeper = RecordingSleeper()
        let transport = ScriptedTransport(steps: [
            .response(httpJSON(500, ["error": ["message": "unavailable"]])),
            .response(httpJSON(503, ["error": ["message": "still unavailable"]])),
            .response(httpJSON(200, completionBody(
                finishReason: "tool_calls",
                toolName: "report_no_transition",
                arguments: "{}"
            ))),
        ])
        var configuration = MuseSparkConfiguration()
        configuration.maxAttempts = 3
        let client = liveClient(configuration: configuration, transport: transport, sleeper: sleeper)
        let verdict = try await client.complete(sampleRequest())
        XCTAssertEqual(verdict.tool, .reportNoTransition)
        XCTAssertEqual(transport.requests().count, 3)
        XCTAssertEqual(sleeper.delays().count, 2)
        XCTAssertEqual(sleeper.delays()[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(sleeper.delays()[1], 1.0, accuracy: 0.0001)

        let limited = RecordingSleeper()
        let rateTransport = ScriptedTransport(steps: [
            .response(httpJSON(429, ["error": ["message": "slow down"]], headers: ["Retry-After": "2"])),
            .response(httpJSON(200, completionBody(finishReason: "stop"))),
        ])
        let rateClient = liveClient(configuration: configuration, transport: rateTransport, sleeper: limited)
        _ = try await rateClient.complete(sampleRequest())
        XCTAssertEqual(rateTransport.requests().count, 2)
        XCTAssertEqual(limited.delays(), [2])
    }

    func testTransportTimeoutRetriesAndBasetenSendsNothing() async throws {
        let sleeper = RecordingSleeper()
        let transport = ScriptedTransport(steps: [
            .urlError(.timedOut),
            .response(httpJSON(200, completionBody(finishReason: "stop"))),
        ])
        var configuration = MuseSparkConfiguration()
        configuration.maxAttempts = 2
        let client = liveClient(configuration: configuration, transport: transport, sleeper: sleeper)
        let verdict = try await client.complete(sampleRequest())
        XCTAssertEqual(verdict.tool, .reportNoTransition)
        XCTAssertEqual(transport.requests().count, 2)
        XCTAssertEqual(sleeper.delays().count, 1)

        let basetenTransport = ScriptedTransport(steps: [])
        let baseten = MuseSparkModelClient(
            backend: .baseten,
            apiKey: "test-key-not-real",
            transport: basetenTransport,
            sleeper: sleeper,
            jitter: ZeroJitter()
        )
        do {
            _ = try await baseten.complete(sampleRequest())
            XCTFail("expected Baseten to stay out of scope")
        } catch ModelClientError.backendOutOfScope(let backend) {
            XCTAssertEqual(backend, .baseten)
            XCTAssertTrue(basetenTransport.requests().isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCallBudgetStopsBeforeTheNextRequest() async throws {
        let transport = ScriptedTransport(steps: [
            .response(httpJSON(200, completionBody(finishReason: "stop"))),
            .response(httpJSON(200, completionBody(finishReason: "stop"))),
        ])
        let client = liveClient(transport: transport, budget: SessionCallBudget(limit: 1))
        _ = try await client.complete(sampleRequest())
        do {
            _ = try await client.complete(sampleRequest())
            XCTFail("expected the budget to stop the second call")
        } catch ModelClientError.callBudgetExhausted(let limit) {
            XCTAssertEqual(limit, 1)
            XCTAssertEqual(transport.requests().count, 1)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testBaseURLCanBeTheAPIRoot() throws {
        let configuration = try MuseSparkConfiguration(
            endpoint: MuseSparkConfiguration.endpoint(parsing: "https://api.meta.ai/v1")
        )
        XCTAssertEqual(try configuration.postURL().absoluteString, "https://api.meta.ai/v1/chat/completions")
        let local = try MuseSparkConfiguration(
            endpoint: MuseSparkConfiguration.endpoint(parsing: "http://127.0.0.1:8080/v1")
        )
        XCTAssertEqual(try local.postURL().path, "/v1/chat/completions")
        XCTAssertThrowsError(try MuseSparkConfiguration(endpoint: URL(string: "http://example.com/v1")!).postURL())
    }

    func testOpenNeedsBlockListsCueSpokenAndHandledWhen() async throws {
        let transport = ScriptedTransport(steps: [.response(httpJSON(200, completionBody(finishReason: "stop")))])
        let client = liveClient(transport: transport)
        var request = sampleRequest()
        request.openNeeds = [
            OpenNeedContext(
                needID: "take-baby",
                latchedSecondsAgo: 12,
                cueSpoken: true,
                resolutionSignal: "wearer_hands_receiving_baby; eating one-handed"
            ),
            OpenNeedContext(needID: "water", latchedSecondsAgo: 3, cueSpoken: false, resolutionSignal: ""),
        ]
        _ = try await client.complete(request)

        let body = try decodeJSON(transport.requests()[0].body)
        guard case .object(let root) = body,
              case .array(let messages)? = root["messages"],
              case .object(let user) = messages[1] else {
            return XCTFail("missing user message")
        }
        let texts = textParts(in: user["content"] ?? .null)
        XCTAssertTrue(texts.contains { $0.contains("Open now:") })
        XCTAssertTrue(texts.contains {
            $0.contains("need_id=take-baby cue_spoken=true problem=")
                && $0.contains("handled_when=wearer_hands_receiving_baby; eating one-handed")
        })
        XCTAssertTrue(texts.contains { $0.contains("need_id=water cue_spoken=false") })
        XCTAssertFalse(texts.contains { $0.contains("Open now: (none)") })
    }

    func testEmptyOpenNeedsBlockReadsNone() async throws {
        let transport = ScriptedTransport(steps: [.response(httpJSON(200, completionBody(finishReason: "stop")))])
        let client = liveClient(transport: transport)
        _ = try await client.complete(sampleRequest())

        let body = try decodeJSON(transport.requests()[0].body)
        guard case .object(let root) = body,
              case .array(let messages)? = root["messages"],
              case .object(let user) = messages[1] else {
            return XCTFail("missing user message")
        }
        let texts = textParts(in: user["content"] ?? .null)
        XCTAssertTrue(texts.contains { $0.contains("Open now: (none)") })
    }

    func testResolvedByMapsToResolution() async throws {
        let pairs: [(String, Resolution)] = [
            ("wearer", .caughtHimself),
            ("other_adult", .resolvedByPartner),
            ("unclear", .unknown),
        ]
        let transport = ScriptedTransport(steps: pairs.map { by, _ in
            .response(httpJSON(200, completionBody(
                finishReason: "tool_calls",
                toolName: "report_need_resolved",
                arguments: toolArguments(["need_id": "take-baby", "resolved_by": by])
            )))
        })
        let client = liveClient(transport: transport)
        for (_, expected) in pairs {
            let verdict = try await client.complete(sampleRequest())
            XCTAssertEqual(verdict.tool, .reportNeedResolved)
            XCTAssertEqual(verdict.assessment.needID, "take-baby")
            XCTAssertEqual(verdict.assessment.resolution, expected)
        }
    }

    private func imageURLs(in value: JSONValue) -> [String] {
        switch value {
        case .object(let object):
            if case .string(let url)? = object["url"], url.hasPrefix("data:image/jpeg;base64,") {
                return [url]
            }
            return object.values.flatMap(imageURLs(in:))
        case .array(let values):
            return values.flatMap(imageURLs(in:))
        default:
            return []
        }
    }

    private func textParts(in value: JSONValue) -> [String] {
        switch value {
        case .array(let values):
            return values.flatMap(textParts(in:))
        case .object(let object):
            if object["type"] == .some(.string("text")), case .string(let text)? = object["text"] {
                return [text]
            }
            return object.values.flatMap(textParts(in:))
        default:
            return []
        }
    }
}
