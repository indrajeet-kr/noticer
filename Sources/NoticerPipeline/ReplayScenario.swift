import Foundation
import NoticerAgent
import NoticerCore

public enum ScenarioError: Error, Equatable, CustomStringConvertible {
    case badPeople(String)
    case badTiming(String)
    case badRepeat
    case unreadable(String)
    case missingDirectory

    public var description: String {
        switch self {
        case .badPeople(let name):
            return "Scenario people preset \"\(name)\" is not one of \(ScriptedVisionGate.knownPresets.joined(separator: ", "))."
        case .badTiming(let message):
            return message
        case .badRepeat:
            return "Only the last recorded response may set repeat."
        case .unreadable(let name):
            return "Could not read scenario \(name)."
        case .missingDirectory:
            return "Could not find fixtures/scenarios."
        }
    }
}

/// One recorded model turn inside a scenario. `repeat` keeps answering heartbeats.
public struct ScenarioResponse: Codable, Sendable, Equatable {
    public var fixtureID: String
    public var normalized: RecordedModelFixture.NormalizedModelTurn
    public var repeats: Bool

    public init(
        fixtureID: String,
        normalized: RecordedModelFixture.NormalizedModelTurn,
        repeats: Bool = false
    ) {
        self.fixtureID = fixtureID
        self.normalized = normalized
        self.repeats = repeats
    }

    public func makeVerdict() throws -> ModelVerdict {
        try RecordedModelFixture(fixtureID: fixtureID, normalized: normalized).makeVerdict()
    }

    private enum CodingKeys: String, CodingKey {
        case fixtureID = "fixture_id"
        case normalized
        case repeats = "repeat"
    }
}

/// What a finished scenario should have done. The checker reads this.
public struct ScenarioExpectation: Codable, Sendable, Equatable {
    public var cueNeedID: String?
    public var cueKind: CueKind?
    public var headStartSeconds: TimeInterval?
    public var silentThroughHeadStart: Bool?
    public var masteryScores: [String: Double]

    public init(
        cueNeedID: String? = nil,
        cueKind: CueKind? = nil,
        headStartSeconds: TimeInterval? = nil,
        silentThroughHeadStart: Bool? = nil,
        masteryScores: [String: Double] = [:]
    ) {
        self.cueNeedID = cueNeedID
        self.cueKind = cueKind
        self.headStartSeconds = headStartSeconds
        self.silentThroughHeadStart = silentThroughHeadStart
        self.masteryScores = masteryScores
    }

    private enum CodingKeys: String, CodingKey {
        case cueNeedID = "cue_need_id"
        case cueKind = "cue_kind"
        case headStartSeconds = "head_start_seconds"
        case silentThroughHeadStart = "silent_through_head_start"
        case masteryScores = "mastery_scores"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cueNeedID = try container.decodeIfPresent(String.self, forKey: .cueNeedID)
        cueKind = try container.decodeIfPresent(CueKind.self, forKey: .cueKind)
        headStartSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .headStartSeconds)
        silentThroughHeadStart = try container.decodeIfPresent(Bool.self, forKey: .silentThroughHeadStart)
        masteryScores = try container.decodeIfPresent([String: Double].self, forKey: .masteryScores) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(cueNeedID, forKey: .cueNeedID)
        try container.encodeIfPresent(cueKind, forKey: .cueKind)
        try container.encodeIfPresent(headStartSeconds, forKey: .headStartSeconds)
        try container.encodeIfPresent(silentThroughHeadStart, forKey: .silentThroughHeadStart)
        try container.encode(masteryScores, forKey: .masteryScores)
    }
}

/// A synthetic session: a keyframe clock, a scripted vision preset, and recorded responses.
public struct ReplayScenario: Codable, Sendable, Equatable, Identifiable {
    public var scenarioID: String
    public var summary: String
    public var needs: [Need]
    public var sampleEvery: TimeInterval
    public var until: TimeInterval
    public var people: String
    public var responses: [ScenarioResponse]
    public var expect: ScenarioExpectation

    public var id: String { scenarioID }

    public init(
        scenarioID: String,
        summary: String,
        needs: [Need],
        sampleEvery: TimeInterval,
        until: TimeInterval,
        people: String,
        responses: [ScenarioResponse],
        expect: ScenarioExpectation
    ) {
        self.scenarioID = scenarioID
        self.summary = summary
        self.needs = needs
        self.sampleEvery = sampleEvery
        self.until = until
        self.people = people
        self.responses = responses
        self.expect = expect
    }

    public func validate() throws {
        guard sampleEvery > 0, until >= sampleEvery, until <= SessionLimits.maxSessionSeconds else {
            throw ScenarioError.badTiming(
                "\(scenarioID) needs sample_every > 0 and until between that step and the session cap."
            )
        }
        guard ScriptedVisionGate.knownPresets.contains(people) else {
            throw ScenarioError.badPeople(people)
        }
        guard !needs.isEmpty, !responses.isEmpty else {
            throw ScenarioError.badTiming("\(scenarioID) needs a need list and at least one response.")
        }
        if responses.dropLast().contains(where: \.repeats) {
            throw ScenarioError.badRepeat
        }
    }

    /// Inclusive grid from t = 0 through `until`.
    public func frames(origin: Date) -> [ScenarioFrame] {
        var frames: [ScenarioFrame] = []
        var t = 0.0
        while t <= until + 0.000_000_1 {
            frames.append(
                ScenarioFrame(
                    t: t,
                    capturedAt: origin.addingTimeInterval(t),
                    people: people
                )
            )
            t += sampleEvery
        }
        return frames
    }

    private enum CodingKeys: String, CodingKey {
        case scenarioID = "scenario_id"
        case summary
        case needs
        case sampleEvery = "sample_every"
        case until
        case people
        case responses
        case expect
    }
}

public struct ScenarioFrame: Sendable, Equatable {
    public var t: TimeInterval
    public var capturedAt: Date
    public var people: String

    public init(t: TimeInterval, capturedAt: Date, people: String) {
        self.t = t
        self.capturedAt = capturedAt
        self.people = people
    }

    public func cameraFrame() -> CameraFrame {
        let marker = UInt8(truncatingIfNeeded: Int(t.rounded()) & 0xFF)
        return CameraFrame(
            capturedAt: capturedAt,
            jpegData: Data([0xFF, 0xD8, marker]),
            width: 8,
            height: 8
        )
    }
}

public struct ScenarioReport: Sendable, Equatable {
    public var scenarioID: String
    public var origin: Date
    public var endedAt: Date
    public var cues: [Cue]
    public var needs: [Need]
    public var log: [EngineEvent]
    public var decisions: [ToolHandlerResult]
    public var modelErrors: [String]

    public init(
        scenarioID: String,
        origin: Date,
        endedAt: Date,
        cues: [Cue],
        needs: [Need],
        log: [EngineEvent],
        decisions: [ToolHandlerResult],
        modelErrors: [String]
    ) {
        self.scenarioID = scenarioID
        self.origin = origin
        self.endedAt = endedAt
        self.cues = cues
        self.needs = needs
        self.log = log
        self.decisions = decisions
        self.modelErrors = modelErrors
    }

    /// First latch time for each need.
    public var latchTimes: [String: Date] {
        var times: [String: Date] = [:]
        for event in log where event.kind == .needLatched {
            if let id = event.needID, times[id] == nil {
                times[id] = event.at
            }
        }
        return times
    }
}

public enum ScenarioCheck {
    public static func failures(_ report: ScenarioReport, expect: ScenarioExpectation) -> [String] {
        var failures: [String] = []
        if !report.modelErrors.isEmpty {
            failures.append("model errors: \(report.modelErrors.joined(separator: "; "))")
        }
        for (id, expected) in expect.masteryScores.sorted(by: { $0.key < $1.key }) {
            guard let actual = report.needs.first(where: { $0.id == id })?.mastery.score else {
                failures.append("missing need \(id)")
                continue
            }
            if abs(actual - expected) > 0.000_001 {
                failures.append("mastery \(id) is \(actual), expected \(expected)")
            }
        }
        if expect.silentThroughHeadStart == true {
            if !report.cues.isEmpty {
                failures.append("expected silence, heard \(report.cues.map(\.needID).joined(separator: ", "))")
            }
            if let seconds = expect.headStartSeconds {
                if report.latchTimes.isEmpty {
                    failures.append("nothing latched")
                }
                for (id, latch) in report.latchTimes {
                    if report.endedAt + 0.001 < latch.addingTimeInterval(seconds) {
                        failures.append("\(id) ended before the \(seconds)s head start")
                    }
                }
            }
        }
        if let cueNeed = expect.cueNeedID {
            let cues = report.cues.filter { $0.needID == cueNeed }
            if cues.count != 1 {
                failures.append("expected one cue for \(cueNeed), got \(cues.count)")
            }
            if let kind = expect.cueKind, let cue = cues.first, cue.kind != kind {
                failures.append("cue kind was \(cue.kind.rawValue), expected \(kind.rawValue)")
            }
            if let seconds = expect.headStartSeconds {
                guard let latch = report.latchTimes[cueNeed], let cue = cues.first else {
                    failures.append("need \(cueNeed) never latched")
                    return failures
                }
                let delta = cue.createdAt.timeIntervalSince(latch)
                if abs(delta - seconds) > 0.001 {
                    failures.append("cue for \(cueNeed) was \(delta)s after latch, expected \(seconds)s")
                }
                let early = report.log.contains { event in
                    event.kind == .cueFired && event.at + 0.001 < latch.addingTimeInterval(seconds)
                }
                if early {
                    failures.append("a cue fired before the head start")
                }
            }
        }
        return failures
    }
}
