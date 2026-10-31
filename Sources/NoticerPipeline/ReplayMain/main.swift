import Foundation
import NoticerCore
import NoticerPipeline

@main
struct NoticerReplayMain {
    static func main() async {
        let code = await ReplayCommand.run(arguments: CommandLine.arguments)
        exit(code)
    }
}

enum ReplayCommand {
    static let help = """
    Noticer replay. No API key and no glasses.

    Plays fixtures/scenarios through the session pipeline:
    replay frames, a scripted signal gate, the need engine, recorded model
    responses, then the cue speaker. The clock jumps. A whisper is a pass
    only after the head start. A self-catch raises mastery and stays quiet.

      swift run noticer-replay
      swift run noticer-replay --scenario take-baby-whisper
      swift run noticer-replay --timing quick
      swift run noticer-replay --list

    Exit 0 when every scenario matches its expect block. Exit 1 otherwise.
    """

    static func run(arguments: [String]) async -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(help)
            return 0
        }
        guard let directory = ScenarioLibrary.sourceTreeDirectory() else {
            print(ScenarioError.missingDirectory.description)
            return 1
        }
        let scenarios: [ReplayScenario]
        do {
            scenarios = try ScenarioLibrary.load(directory: directory)
        } catch {
            print(String(describing: error))
            return 1
        }
        if arguments.contains("--list") {
            for scenario in scenarios {
                print("\(scenario.scenarioID)\t\(scenario.summary)")
            }
            return 0
        }
        let selected: [ReplayScenario]
        if let name = value(of: "--scenario", in: arguments) {
            guard let match = scenarios.first(where: { $0.scenarioID == name }) else {
                print("No scenario named \(name).")
                print(scenarios.map(\.scenarioID).joined(separator: "\n"))
                return 1
            }
            selected = [match]
        } else {
            selected = scenarios
        }
        let timingName = value(of: "--timing", in: arguments) ?? "standard"
        let timing: TimingProfile = timingName == "quick" ? .quick : .standard
        var failed = false
        for var scenario in selected {
            if timing == .quick {
                scenario.sampleEvery = 2
                if scenario.expect.headStartSeconds != nil {
                    scenario.expect.headStartSeconds = timing.defaultHeadStartSeconds
                }
            }
            let speaker = RecordingCueSpeaker()
            let report: ScenarioReport
            do {
                let playback = try ScenarioPlayback(scenario: scenario, speaker: speaker, timing: timing)
                report = try await playback.run()
            } catch {
                print("scenario: \(scenario.scenarioID)")
                print(String(describing: error))
                print("result: fail")
                failed = true
                continue
            }
            let failures = ScenarioCheck.failures(report, expect: scenario.expect)
            print(render(scenario: scenario, report: report, spoken: speaker.spokenCues().count))
            if failures.isEmpty {
                print("result: pass")
            } else {
                for failure in failures {
                    print("failure: \(failure)")
                }
                print("result: fail")
                failed = true
            }
            print("")
        }
        return failed ? 1 : 0
    }

    private static func render(scenario: ReplayScenario, report: ScenarioReport, spoken: Int) -> String {
        var lines = [
            "scenario: \(scenario.scenarioID)",
            "summary: \(scenario.summary)",
        ]
        if report.latchTimes.isEmpty {
            lines.append("latched: none")
        } else {
            for (id, latch) in report.latchTimes.sorted(by: { $0.key < $1.key }) {
                let t = latch.timeIntervalSince(report.origin)
                lines.append(String(format: "latched: %@ at +%.1fs", id, t))
            }
        }
        if report.cues.isEmpty {
            lines.append("cue: none")
        } else {
            for cue in report.cues {
                let t = cue.createdAt.timeIntervalSince(report.origin)
                let latch = report.latchTimes[cue.needID]
                let after = latch.map { cue.createdAt.timeIntervalSince($0) }
                let delay = after.map { String(format: " (%.1fs after latch)", $0) } ?? ""
                lines.append(String(format: "cue: %@ %@ at +%.1fs%@", cue.kind.rawValue, cue.needID, t, delay))
                if !cue.text.isEmpty {
                    lines.append("text: \(cue.text)")
                }
            }
        }
        lines.append("spoken: \(spoken)")
        lines.append("mastery: \(SessionView(now: report.endedAt, needs: report.needs, openNeeds: [], cues: report.cues, log: report.log, modelCalls: 0).masterySummary)")
        for timingLine in report.timingLines {
            lines.append("[TIMING] \(timingLine)")
        }
        return lines.joined(separator: "\n")
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
