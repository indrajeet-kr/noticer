import Foundation
import NoticerAgent
import NoticerCore
import Synchronization
import XCTest

/// The 7 Mom's-list intent cases from the UX spec, plus slug/priority unit
/// checks and a live smoke test. The intent API is compiled into this target.
final class NeedsIntentTests: XCTestCase {
    private static let exampleMessage =
        "When I'm eating with the baby in one arm, take her so I can eat. Keep my water bottle full, I forget at night."

    // MARK: 1. The example sentence produces exactly take-baby + refill-water.

    func testExampleSentenceProducesTwoNeeds() async throws {
        let transport = ScriptedIntentTransport(steps: [.response(httpJSON(200, completionBody(
            toolName: "set_needs",
            arguments: toolArguments([
                "needs": [
                    [
                        "id": "take-baby",
                        "authorText": "Take the baby when you're eating one-handed",
                        "whisper": "She could use a hand.",
                        "priority": "normal",
                        "allowsCheckIn": false,
                        "visualCue": "adult eating while holding an infant in one arm",
                    ],
                    [
                        "id": "refill-water",
                        "authorText": "Keep your water bottle full, especially at night",
                        "whisper": "Her water's low.",
                        "priority": "normal",
                        "allowsCheckIn": false,
                        "visualCue": "adult in bed at night with no water bottle in reach",
                    ],
                ],
                "readBack": "Two things to watch for tonight.",
            ])
        )))])
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: .fast)
        let result = try await client.interpret(currentList: [], message: Self.exampleMessage)

        guard case .needs(let drafts, _) = result else {
            return XCTFail("expected set_needs, got \(result)")
        }
        XCTAssertEqual(Set(drafts.map(\.id)), ["take-baby", "refill-water"])

        // Request contract: model, minimal reasoning, auto tools, non-null content.
        let requests = transport.requests()
        XCTAssertEqual(requests.count, 1)
        let body = try JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "muse-spark-1.3")
        XCTAssertEqual(body?["reasoning_effort"] as? String, "minimal")
        XCTAssertEqual(body?["tool_choice"] as? String, "auto")
        XCTAssertNil(body?["max_tokens"], "max_tokens must be omitted: a 1024 cap truncated turns with finish_reason length")
        let messages = body?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        for message in messages ?? [] {
            XCTAssertTrue(message["content"] is String, "every content must be a non-null string")
        }
        XCTAssertTrue((messages?[1]["content"] as? String ?? "").contains("CURRENT_LIST: []"))
        let tools = body?["tools"] as? [[String: Any]]
        let names = tools?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names ?? []), ["set_needs", "ask_clarifying_question"])
    }

    // MARK: 2. "make water higher priority" keeps ids, raises refill-water.

    func testReprioritizeKeepsIDs() async throws {
        let current = try await twoNeeds()
        let transport = ScriptedIntentTransport(steps: [.response(httpJSON(200, completionBody(
            toolName: "set_needs",
            arguments: toolArguments([
                "needs": [
                    [
                        "id": "take-baby",
                        "authorText": "Take the baby when you're eating one-handed",
                        "whisper": "She could use a hand.",
                        "priority": "normal",
                        "allowsCheckIn": false,
                        "visualCue": "adult eating while holding an infant in one arm",
                    ],
                    [
                        "id": "refill-water",
                        "authorText": "Keep your water bottle full, especially at night",
                        "whisper": "Her water's low.",
                        "priority": "important",
                        "allowsCheckIn": false,
                        "visualCue": "adult in bed at night with no water bottle in reach",
                    ],
                ],
                "readBack": "Water first now.",
            ])
        )))])
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: .fast)
        let result = try await client.interpret(currentList: current, message: "make water higher priority")

        guard case .needs(let drafts, _) = result else {
            return XCTFail("expected set_needs, got \(result)")
        }
        XCTAssertEqual(Set(drafts.map(\.id)), ["take-baby", "refill-water"])
        XCTAssertEqual(drafts.first { $0.id == "refill-water" }?.priority, .important)

        let updated = NeedsIntentConversion.toNeeds(drafts, current: current)
        let water = try XCTUnwrap(updated.first { $0.id == "refill-water" })
        let baby = try XCTUnwrap(updated.first { $0.id == "take-baby" })
        XCTAssertEqual(water.priority, NeedsIntentPriority.important.needPriority)
        // take-baby is untouched, and both rows keep their UI identity.
        XCTAssertEqual(baby, current.first { $0.id == "take-baby" })
        XCTAssertEqual(
            Set(updated.map(\.uiID)),
            Set(current.map(\.uiID)),
            "edits keep row identity and mastery"
        )
    }

    // MARK: 3. "remove the water one" leaves exactly take-baby.

    func testRemoveWaterLeavesTakeBaby() async throws {
        let current = try await twoNeeds()
        let transport = ScriptedIntentTransport(steps: [.response(httpJSON(200, completionBody(
            toolName: "set_needs",
            arguments: toolArguments([
                "needs": [
                    [
                        "id": "take-baby",
                        "authorText": "Take the baby when you're eating one-handed",
                        "whisper": "She could use a hand.",
                        "priority": "normal",
                        "allowsCheckIn": false,
                        "visualCue": "adult eating while holding an infant in one arm",
                    ],
                ],
                "readBack": "Just the baby one now.",
            ])
        )))])
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: .fast)
        let result = try await client.interpret(currentList: current, message: "remove the water one")

        guard case .needs(let drafts, _) = result else {
            return XCTFail("expected set_needs, got \(result)")
        }
        let updated = NeedsIntentConversion.toNeeds(drafts, current: current)
        XCTAssertEqual(updated.map(\.id), ["take-baby"])
    }

    // MARK: 4. Eight needs asks which matter most and saves nothing.

    func testEightNeedsAsksQuestion() async throws {
        let transport = ScriptedIntentTransport(steps: [.response(httpJSON(200, completionBody(
            toolName: "ask_clarifying_question",
            arguments: toolArguments([
                "question": "That's a lot to watch for at once. Which ones matter most tonight? I can hold up to 6.",
                "suggestions": ["Water", "Baby", "Dinner"],
            ])
        )))])
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: .fast)
        let message = [
            "water", "baby", "dinner", "dishes", "laundry", "trash", "bath", "bedtime",
        ].joined(separator: ", ")
        let result = try await client.interpret(currentList: [], message: message)

        guard case .question(let question, let suggestions) = result else {
            return XCTFail("expected a clarifying question, got \(result)")
        }
        XCTAssertTrue(question.contains("6"))
        XCTAssertEqual(suggestions, ["Water", "Baby", "Dinner"])
    }

    // MARK: 5. "help with the baby" asks one gentle question.

    func testVagueMessageAsksOneQuestion() async throws {
        // Content-only reply: no tool call means the content is the question bubble.
        let transport = ScriptedIntentTransport(steps: [.response(httpJSON(200, completionBody(
            content: "When would help with the baby feel best — while you're eating, or at bedtime?"
        )))])
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: .fast)
        let result = try await client.interpret(currentList: [], message: "help with the baby")

        guard case .question(let question, let suggestions) = result else {
            return XCTFail("expected a clarifying question, got \(result)")
        }
        XCTAssertTrue(question.contains("eating"))
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: 6. No whisper mentions glasses, cameras, or seeing.

    func testWhisperNeverMentionsGlasses() async throws {
        let current = try await twoNeeds()
        for need in current {
            XCTAssertNil(
                NeedsIntentWhisper.forbiddenWord(in: need.cueWording),
                "whisper mentions sensing: \(need.cueWording)"
            )
        }
        // Word boundaries: "seed" is fine, "saw" and "glasses" are not.
        XCTAssertNil(NeedsIntentWhisper.forbiddenWord(in: "She dropped a seed."))
        XCTAssertEqual(NeedsIntentWhisper.forbiddenWord(in: "I saw her plate."), "saw")
        XCTAssertEqual(
            NeedsIntentWhisper.forbiddenWord(in: "The glasses say she's thirsty."),
            "glasses"
        )

        let transport = ScriptedIntentTransport(steps: [.response(httpJSON(200, completionBody(
            toolName: "set_needs",
            arguments: toolArguments([
                "needs": [
                    [
                        "id": "take-baby",
                        "authorText": "Take the baby",
                        "whisper": "The camera saw she's struggling.",
                        "priority": "normal",
                        "allowsCheckIn": false,
                        "visualCue": "adult eating while holding an infant in one arm",
                    ],
                ],
                "readBack": "One thing.",
            ])
        )))])
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: .fast)
        do {
            _ = try await client.interpret(currentList: [], message: "take the baby")
            XCTFail("a sensing whisper must fail the turn")
        } catch let error as NeedsIntentError {
            guard case .forbiddenWhisper(let id, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(id, "take-baby")
        }
    }

    // MARK: 7. Network and HTTP failures keep the saved list.

    func testNetworkFailureThrowsTypedError() async throws {
        let saved = try await twoNeeds()

        let offline = ScriptedIntentTransport(steps: [.urlError(.notConnectedToInternet)])
        let offlineClient = NeedsIntentClient(
            apiKey: "test-key", transport: offline, configuration: .fast
        )
        await XCTAssertIntentThrows(
            try await offlineClient.interpret(currentList: saved, message: "add dishes")
        ) { error in
            guard case .transport = error else { return false }
            return true
        }

        let failing = ScriptedIntentTransport(steps: [.response(HTTPResponse(
            statusCode: 500,
            body: Data("{\"error\":{\"message\":\"bad gateway\"}}".utf8)
        ))])
        let failingClient = NeedsIntentClient(
            apiKey: "test-key", transport: failing, configuration: .fast
        )
        await XCTAssertIntentThrows(
            try await failingClient.interpret(currentList: saved, message: "add dishes")
        ) { error in
            guard case .rejected(let status, _) = error else { return false }
            return status == 500
        }
        XCTAssertEqual(saved.map(\.id), ["take-baby", "refill-water"], "failures never mutate the saved list")
    }

    func testRejectedRequestDoesNotRetry() async throws {
        let transport = ScriptedIntentTransport(steps: [.response(HTTPResponse(
            statusCode: 400,
            body: Data("{\"error\":{\"message\":\"bad request\"}}".utf8)
        ))])
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: .fast)
        await XCTAssertIntentThrows(
            try await client.interpret(currentList: [], message: "hi")
        ) { error in
            guard case .rejected(let status, _) = error else { return false }
            return status == 400
        }
        XCTAssertEqual(transport.requests().count, 1, "a 400 is final")
    }

    func testTransientFailureRetriesOnce() async throws {
        let transport = ScriptedIntentTransport(steps: [
            .response(HTTPResponse(statusCode: 500, body: Data())),
            .response(httpJSON(200, completionBody(content: "Which one matters most?"))),
        ])
        var configuration = NeedsIntentConfiguration.fast
        configuration.maxAttempts = 2
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: configuration)
        let result = try await client.interpret(currentList: [], message: "hi")
        guard case .question = result else {
            return XCTFail("expected the retry to succeed, got \(result)")
        }
        XCTAssertEqual(transport.requests().count, 2)
    }

    func testAPIKeyNeverAppearsInErrors() async throws {
        let key = "sk-live-secret-key"
        let transport = ThrowingIntentTransport(error: NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "boom \(key) boom"]
        ))
        let client = NeedsIntentClient(apiKey: key, transport: transport, configuration: .fast)
        await XCTAssertIntentThrows(
            try await client.interpret(currentList: [], message: "hi")
        ) { error in
            XCTAssertFalse(error.description.contains(key), "the key must be redacted")
            return true
        }
    }

    // MARK: Slugs, priorities, conversion.

    func testSlugNormalization() {
        XCTAssertEqual(NeedsIntentSlug.normalize("  Take_The Baby! "), "take-baby")
        XCTAssertEqual(NeedsIntentSlug.normalize("refill-my-water"), "refill-water")
        XCTAssertEqual(NeedsIntentSlug.normalize("Water Bottle (Night)"), "water-bottle-night")
        XCTAssertTrue(NeedsIntentSlug.isValid("take-baby"))
        XCTAssertFalse(NeedsIntentSlug.isValid("Take Baby"))
    }

    func testPriorityMapping() {
        XCTAssertEqual(NeedsIntentPriority.important.needPriority, 0)
        XCTAssertEqual(NeedsIntentPriority.normal.needPriority, 1)
        XCTAssertEqual(NeedsIntentPriority.gentle.needPriority, 2)
        XCTAssertEqual(NeedsIntentPriority.word(forNeedPriority: 0), .important)
        XCTAssertEqual(NeedsIntentPriority.lenient("IMPORTANT"), .important)
        XCTAssertEqual(NeedsIntentPriority.lenient("urgent"), .normal)
    }

    func testTooManyNeedsFailsTheTurn() async throws {
        var needs: [[String: Any]] = []
        for index in 0..<8 {
            needs.append([
                "id": "need-\(index)",
                "authorText": "need \(index)",
                "whisper": "Need \(index).",
                "priority": "normal",
                "allowsCheckIn": false,
                "visualCue": "something observable \(index)",
            ])
        }
        let transport = ScriptedIntentTransport(steps: [.response(httpJSON(200, completionBody(
            toolName: "set_needs",
            arguments: toolArguments(["needs": needs, "readBack": "Too many."])
        )))])
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: .fast)
        await XCTAssertIntentThrows(
            try await client.interpret(currentList: [], message: "everything")
        ) { error in
            guard case .invalidNeeds = error else { return false }
            return true
        }
    }

    // MARK: Typo repair ("takeq-baby" snaps to "take-baby").

    func testRepairSnapsSingleTypos() {
        let pair = ["take-baby", "refill-water"]
        XCTAssertEqual(NeedsIntentSlug.repair("takeq-baby", against: pair), "take-baby")
        XCTAssertEqual(NeedsIntentSlug.repair("tkae-baby", against: pair), "take-baby")
        XCTAssertEqual(NeedsIntentSlug.repair("take-bab", against: pair), "take-baby")
        XCTAssertEqual(NeedsIntentSlug.repair("take-baby", against: pair), "take-baby")
        XCTAssertEqual(NeedsIntentSlug.repair("water", against: pair), "water")
        XCTAssertEqual(NeedsIntentSlug.repair("take-band", against: pair), "take-band")
    }

    func testRepairNeverGuessesAmbiguousSlugs() {
        XCTAssertEqual(NeedsIntentSlug.repair("cat", against: ["bat", "cut"]), "cat")
        XCTAssertEqual(NeedsIntentSlug.repair("xyz", against: ["take-baby", "refill-water"]), "xyz")
    }

    func testTypoDraftEditsExistingNeed() async throws {
        let current = try await twoNeeds()
        let baby = try XCTUnwrap(current.first { $0.id == "take-baby" })
        let drafts = [
            NeedsIntentDraft(
                id: "takeq-baby",
                authorText: baby.authorText,
                whisper: baby.cueWording,
                priority: .normal,
                allowsCheckIn: false,
                visualCue: baby.visualCondition ?? "adult eating while holding an infant in one arm"
            ),
        ]
        let updated = NeedsIntentConversion.toNeeds(drafts, current: current)
        XCTAssertEqual(updated.map(\.id), ["take-baby"])
        XCTAssertEqual(updated.first?.uiID, baby.uiID, "the typo edits the need; identity and mastery survive")
    }

    func testDoubleDraftNeverMerges() async throws {
        let current = try await twoNeeds()
        let drafts = [
            NeedsIntentDraft(
                id: "take-baby",
                authorText: "Take the baby",
                whisper: "She could use a hand.",
                priority: .normal,
                allowsCheckIn: false,
                visualCue: "adult eating while holding an infant in one arm"
            ),
            NeedsIntentDraft(
                id: "takeq-baby",
                authorText: "Take the baby",
                whisper: "She could use a hand.",
                priority: .normal,
                allowsCheckIn: false,
                visualCue: "adult eating while holding an infant in one arm"
            ),
        ]
        let updated = NeedsIntentConversion.toNeeds(drafts, current: current)
        XCTAssertEqual(Set(updated.map(\.id)), ["take-baby", "takeq-baby"], "no need is lost to a merge")
    }

    func testSavedTypoRepairsOnLoad() {
        let typo = Need(id: "takeq-baby", authorText: "Take the baby", cueWording: "She could use a hand.", priority: 0)
        let custom = Need(id: "water", authorText: "Water", cueWording: "Water.", priority: 1)
        let repaired = NeedListStore.repairIDs([typo, custom, typo])
        XCTAssertEqual(repaired.map(\.id), ["take-baby", "water"], "typo snaps, custom ids pass, dupes merge")
    }

    func testLengthFinishKeepsSavedList() async throws {
        let saved = try await twoNeeds()
        let transport = ScriptedIntentTransport(steps: [.response(httpJSON(200, completionBody(
            content: "When would help",
            finishReason: "length"
        )))])
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: .fast)
        await XCTAssertIntentThrows(
            try await client.interpret(currentList: saved, message: "add dishes")
        ) { error in
            guard case .malformedResponse(let message) = error else { return false }
            return message.contains("length")
        }
        XCTAssertEqual(saved.map(\.id), ["take-baby", "refill-water"], "a truncated turn never mutates the saved list")
    }

    // MARK: Seeding: saved needs back into drafts.

    func testFromNeedsMapsAuthoredFields() {
        let needs = [
            Need(id: "take-baby", authorText: "Take the baby", cueWording: "She could use a hand.", visualCondition: "eating one-handed", priority: 0, allowsCheckIn: true),
            Need(id: "water", authorText: "Water", cueWording: "Water.", priority: 1),
            Need(id: "dishes", authorText: "Dishes", cueWording: "Sink's full.", priority: 5),
        ]
        let drafts = NeedsIntentConversion.fromNeeds(needs)
        XCTAssertEqual(drafts.map(\.id), ["take-baby", "water", "dishes"])
        XCTAssertEqual(drafts.map(\.authorText), ["Take the baby", "Water", "Dishes"])
        XCTAssertEqual(drafts.map(\.whisper), ["She could use a hand.", "Water.", "Sink's full."])
        XCTAssertEqual(drafts.map(\.priority), [.important, .normal, .gentle])
        XCTAssertEqual(drafts.map(\.allowsCheckIn), [true, false, false])
        XCTAssertEqual(drafts.map(\.visualCue), ["eating one-handed", "", ""])
        XCTAssertEqual(NeedsIntentPriority.word(forNeedPriority: -1), .important)
    }

    func testFromNeedsRoundTripsThroughToNeeds() {
        let needs = [
            Need(id: "take-baby", authorText: "Take the baby", cueWording: "She could use a hand.", priority: 0),
            Need(id: "water", authorText: "Water", cueWording: "Water.", visualCondition: "glass on table", priority: 2, allowsCheckIn: true),
        ]
        let roundTripped = NeedsIntentConversion.toNeeds(NeedsIntentConversion.fromNeeds(needs), current: needs)
        XCTAssertEqual(roundTripped, needs)
    }

    // MARK: Live smoke (opt-in).

    /// Recorded tests above run on every build. This one hits the real API
    /// and only runs with NOTICER_LIVE_SMOKE=1 and META_API_KEY set.
    func testLiveSmoke() async throws {
        guard ProcessInfo.processInfo.environment["NOTICER_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Set NOTICER_LIVE_SMOKE=1 to hit the live API.")
        }
        guard let key = ProcessInfo.processInfo.environment["META_API_KEY"], !key.isEmpty else {
            throw XCTSkip("META_API_KEY is not set.")
        }
        let client = NeedsIntentClient(apiKey: key)
        let result = try await client.interpret(currentList: [], message: Self.exampleMessage)
        guard case .needs(let drafts, _) = result else {
            return XCTFail("expected set_needs from the live model, got \(result)")
        }
        XCTAssertEqual(Set(drafts.map(\.id)), ["take-baby", "refill-water"])
        for draft in drafts {
            XCTAssertNil(NeedsIntentWhisper.forbiddenWord(in: draft.whisper))
        }
    }

    // MARK: Helpers.

    private func twoNeeds() async throws -> [Need] {
        let transport = ScriptedIntentTransport(steps: [.response(httpJSON(200, completionBody(
            toolName: "set_needs",
            arguments: toolArguments([
                "needs": [
                    [
                        "id": "take-baby",
                        "authorText": "Take the baby when you're eating one-handed",
                        "whisper": "She could use a hand.",
                        "priority": "normal",
                        "allowsCheckIn": false,
                        "visualCue": "adult eating while holding an infant in one arm",
                    ],
                    [
                        "id": "refill-water",
                        "authorText": "Keep your water bottle full, especially at night",
                        "whisper": "Her water's low.",
                        "priority": "normal",
                        "allowsCheckIn": false,
                        "visualCue": "adult in bed at night with no water bottle in reach",
                    ],
                ],
                "readBack": "Two things to watch for tonight.",
            ])
        )))])
        let client = NeedsIntentClient(apiKey: "test-key", transport: transport, configuration: .fast)
        let result = try await client.interpret(currentList: [], message: Self.exampleMessage)
        guard case .needs(let drafts, _) = result else {
            throw NeedsIntentError.malformedResponse("fixture must return needs")
        }
        return NeedsIntentConversion.toNeeds(drafts, current: [])
    }
}

// MARK: - Test doubles

private enum ScriptedIntentStep: Sendable {
    case response(HTTPResponse)
    case urlError(URLError.Code)
}

private final class ScriptedIntentTransport: HTTPTransport, Sendable {
    struct State: Sendable {
        var steps: [ScriptedIntentStep]
        var requests: [HTTPRequest]
    }

    private let state: Mutex<State>

    init(steps: [ScriptedIntentStep]) {
        state = Mutex(State(steps: steps, requests: []))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let step: ScriptedIntentStep? = state.withLock { state in
            state.requests.append(request)
            guard !state.steps.isEmpty else {
                return nil
            }
            return state.steps.removeFirst()
        }
        switch step {
        case .response(let response):
            return response
        case .urlError(let code):
            throw URLError(code)
        case nil:
            throw URLError(.badServerResponse)
        }
    }

    func requests() -> [HTTPRequest] {
        state.withLock { $0.requests }
    }
}

private struct ThrowingIntentTransport: HTTPTransport, @unchecked Sendable {
    var error: Error
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw error }
}

private extension NeedsIntentConfiguration {
    /// No waiting between attempts in tests.
    static var fast: NeedsIntentConfiguration {
        NeedsIntentConfiguration(
            requestTimeout: 5,
            maxAttempts: 1,
            retryInitialDelay: 0,
            retryMaximumDelay: 0
        )
    }
}

private func httpJSON(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
    // swiftlint:disable:next force_try
    let data = try! JSONSerialization.data(withJSONObject: object)
    return HTTPResponse(statusCode: status, body: data)
}

private func toolArguments(_ fields: [String: Any]) -> String {
    // swiftlint:disable:next force_try
    let data = try! JSONSerialization.data(withJSONObject: fields)
    // swiftlint:disable:next force_unwrapping
    return String(data: data, encoding: .utf8)!
}

private func completionBody(
    content: String = "",
    toolName: String? = nil,
    arguments: String? = nil,
    finishReason: String? = nil
) -> [String: Any] {
    var message: [String: Any] = ["role": "assistant", "content": content]
    if let toolName, let arguments {
        message["tool_calls"] = [[
            "id": "call_1",
            "type": "function",
            "function": ["name": toolName, "arguments": arguments],
        ]]
    }
    return [
        "id": "chatcmpl-test",
        "choices": [[
            "index": 0,
            "message": message,
            "finish_reason": finishReason ?? (toolName == nil ? "stop" : "tool_calls"),
        ]],
    ]
}

private func XCTAssertIntentThrows(
    _ expression: @autoclosure () async throws -> NeedsIntentResult,
    _ check: (NeedsIntentError) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let result = try await expression()
        XCTFail("expected a throw, got \(result)", file: file, line: line)
    } catch let error as NeedsIntentError {
        XCTAssertTrue(check(error), "unexpected intent error: \(error)", file: file, line: line)
    } catch {
        XCTFail("wrong error type: \(error)", file: file, line: line)
    }
}
