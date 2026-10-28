import Foundation
import NoticerCore
import Synchronization
@testable import NoticerAgent

final class ScriptedTransport: HTTPTransport, Sendable {
    struct State: Sendable {
        var steps: [ScriptedStep]
        var requests: [HTTPRequest]
    }

    private let state: Mutex<State>

    init(steps: [ScriptedStep]) {
        state = Mutex(State(steps: steps, requests: []))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try state.withLock { state in
            state.requests.append(request)
            guard !state.steps.isEmpty else {
                throw URLError(.badServerResponse)
            }
            let step = state.steps.removeFirst()
            switch step {
            case .response(let response):
                return response
            case .urlError(let code):
                throw URLError(code)
            }
        }
    }

    func requests() -> [HTTPRequest] {
        state.withLock { $0.requests }
    }
}

enum ScriptedStep: Sendable {
    case response(HTTPResponse)
    case urlError(URLError.Code)
}

final class RecordingSleeper: RetrySleeper, Sendable {
    private let sleeps = Mutex<[TimeInterval]>([])

    func sleep(seconds: TimeInterval) async throws {
        sleeps.withLock { $0.append(seconds) }
    }

    func delays() -> [TimeInterval] {
        sleeps.withLock { $0 }
    }
}

final class LineBuffer: Sendable {
    private let lines = Mutex<[String]>([])

    func add(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    func text() -> [String] {
        lines.withLock { $0 }
    }
}

final class FixedModelClient: ModelClient, Sendable {
    private let state: Mutex<State>

    struct State: Sendable {
        var verdict: ModelVerdict?
        var error: FixedFailure?
        var calls: Int
    }

    init(verdict: ModelVerdict) {
        state = Mutex(State(verdict: verdict, error: nil, calls: 0))
    }

    init(error: FixedFailure) {
        state = Mutex(State(verdict: nil, error: error, calls: 0))
    }

    func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        try state.withLock { state in
            state.calls += 1
            if let error = state.error {
                throw error.modelError
            }
            return state.verdict!
        }
    }

    func calls() -> Int {
        state.withLock { $0.calls }
    }
}

enum FixedFailure: Sendable {
    case modelNotFound
    case truncated
    case rejected

    var modelError: ModelClientError {
        switch self {
        case .modelNotFound:
            return .modelNotFound(message: "The model was not found.")
        case .truncated:
            return .responseTruncated(message: "finish_reason was length.", usage: nil)
        case .rejected:
            return .requestRejected(status: 400, code: nil, message: "bad request")
        }
    }
}

final class FixedDetailedClient: DetailedModelClient, Sendable {
    private let state: Mutex<[DetailedModelCompletion]>

    init(completions: [DetailedModelCompletion]) {
        state = Mutex(completions)
    }

    func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        try await completeDetailed(request).verdict
    }

    func completeDetailed(_ request: ModelRequest) async throws -> DetailedModelCompletion {
        try state.withLock { completions in
            guard !completions.isEmpty else {
                throw ModelClientError.recordingExhausted
            }
            return completions.removeFirst()
        }
    }
}

func liveClient(
    key: String = "test-key-not-real",
    configuration: MuseSparkConfiguration = MuseSparkConfiguration(),
    transport: ScriptedTransport,
    sleeper: any RetrySleeper = RecordingSleeper(),
    budget: SessionCallBudget? = nil
) -> MuseSparkModelClient {
    MuseSparkModelClient(
        apiKey: key,
        configuration: configuration,
        transport: transport,
        sleeper: sleeper,
        jitter: ZeroJitter(),
        callBudget: budget
    )
}

func httpJSON(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> HTTPResponse {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return HTTPResponse(statusCode: status, headers: headers, body: data)
}

func toolArguments(_ fields: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return String(data: data, encoding: .utf8)!
}

func completionBody(
    finishReason: String,
    content: Any = NSNull(),
    toolName: String? = nil,
    arguments: String? = nil,
    extraToolName: String? = nil,
    usage: [String: Any]? = nil
) -> [String: Any] {
    var message: [String: Any] = [
        "role": "assistant",
        "content": content,
    ]
    if let toolName, let arguments {
        var calls: [[String: Any]] = [[
            "id": "call_1",
            "type": "function",
            "function": [
                "name": toolName,
                "arguments": arguments,
            ],
        ]]
        if let extraToolName {
            calls.append([
                "id": "call_2",
                "type": "function",
                "function": [
                    "name": extraToolName,
                    "arguments": arguments,
                ],
            ])
        }
        message["tool_calls"] = calls
    }
    var body: [String: Any] = [
        "id": "chatcmpl-test",
        "choices": [[
            "index": 0,
            "message": message,
            "finish_reason": finishReason,
        ]],
    ]
    if let usage {
        body["usage"] = usage
    }
    return body
}

func sampleUsage() -> [String: Any] {
    [
        "prompt_tokens": 1000,
        "completion_tokens": 100,
        "total_tokens": 1100,
        "completion_tokens_details": ["reasoning_tokens": 40],
        "prompt_tokens_details": ["cached_tokens": 200],
    ]
}

func sampleRequest(
    jpeg: Data = Data([0xFF, 0xD8, 0x01, 0x02]),
    needID: String = "eating-one-handed"
) -> ModelRequest {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return ModelRequest(
        keyframes: [
            Keyframe(id: "older", capturedAt: now, ageSeconds: 28, episodeID: "g", jpegData: jpeg),
            Keyframe(id: "newer", capturedAt: now, ageSeconds: 0, episodeID: "g", jpegData: jpeg),
        ],
        needs: [
            Need(
                id: needID,
                authorText: "eating one-handed",
                cueWording: "Take the baby?",
                priority: 0
            ),
        ]
    )
}

func latchVerdict(
    needID: String = "eating-one-handed",
    sustained: Bool? = true,
    resolution: Resolution? = nil,
    actionCode: String? = nil,
    confidence: Double? = 0.2
) -> ModelVerdict {
    ModelVerdict(
        finishReason: .toolCalls,
        tool: .latchNeedHypothesis,
        assessment: SceneAssessment(
            needID: needID,
            sustainedAcrossStrip: sustained,
            partnerStateEvidence: ["eating_one_handed"],
            wearerHandsOccupied: false,
            resolution: resolution,
            actionCode: actionCode,
            confidence: confidence
        )
    )
}

func spacedKeyframes() -> [Keyframe] {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return [
        Keyframe(id: "a", capturedAt: now, ageSeconds: 8, episodeID: "e", jpegData: Data([1])),
        Keyframe(id: "b", capturedAt: now, ageSeconds: 0, episodeID: "e", jpegData: Data([2])),
    ]
}

func authoredSession(
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    open: [String] = [],
    calls: Int = 0,
    lastLatchAt: Date? = nil,
    relatchNotBefore: [String: Date] = [:],
    headStarts: [String: HeadStartWindow] = [:],
    lastCueAt: Date? = nil
) -> CapSession {
    CapSession(
        now: now,
        authoredNeedIDs: ["eating-one-handed", "water"],
        openNeedIDs: open,
        callsCompletedBeforeThis: calls,
        lastLatchAt: lastLatchAt,
        relatchNotBefore: relatchNotBefore,
        headStarts: headStarts,
        lastCueAt: lastCueAt
    )
}

func decodeJSON(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}
