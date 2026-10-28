import Foundation
import NoticerCore

enum StubEngineNote: Equatable, Sendable {
    case asked(ToolName)
    case liveClientNotImplemented
    case missingAPIKey
    case recordingExhausted
    case standingBy
    case failed(String)
}

struct StubTurn: Sendable {
    var note: StubEngineNote
    var cue: Cue?
}

/// Stand-in until the core need engine lands.
///
/// A frame the gate passed becomes one keyframe. The model client answers.
/// A `latch_need_hypothesis` for a need on mom's list becomes one whisper.
/// Head start, mastery, caps, visitor pause, and staleness are not applied.
@MainActor
final class StubSessionEngine {
    private let model: any ModelClient
    private var asking = true
    private var episode = 0

    init(model: any ModelClient) {
        self.model = model
    }

    func takeTurn(frame: CameraFrame, needs: [Need]) async -> StubTurn {
        guard asking else {
            return StubTurn(note: .standingBy, cue: nil)
        }
        episode += 1
        let keyframe = Keyframe(
            id: UUID().uuidString,
            frame: frame,
            ageSeconds: 0,
            episodeID: "ios-stub-\(episode)"
        )
        let verdict: ModelVerdict
        do {
            verdict = try await model.complete(ModelRequest(keyframes: [keyframe], needs: needs))
        } catch let error as ModelClientError {
            asking = false
            switch error {
            case .notImplemented:
                return StubTurn(note: .liveClientNotImplemented, cue: nil)
            case .missingAPIKey:
                return StubTurn(note: .missingAPIKey, cue: nil)
            case .recordingExhausted:
                return StubTurn(note: .recordingExhausted, cue: nil)
            case .backendOutOfScope:
                return StubTurn(note: .failed("Baseten is out of scope."), cue: nil)
            }
        } catch {
            asking = false
            return StubTurn(note: .failed(error.localizedDescription), cue: nil)
        }
        let cue = Self.cue(for: verdict, needs: needs, now: frame.capturedAt)
        return StubTurn(note: .asked(verdict.tool), cue: cue)
    }

    /// Latch is the only tool that speaks in this stand-in. The cue text is mom's wording.
    static func cue(for verdict: ModelVerdict, needs: [Need], now: Date) -> Cue? {
        guard verdict.tool == .latchNeedHypothesis else {
            return nil
        }
        guard let needID = verdict.assessment.needID,
              let need = needs.first(where: { $0.id == needID })
        else {
            return nil
        }
        let text = need.cueWording.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        return Cue(
            id: UUID().uuidString,
            needID: need.id,
            text: text,
            kind: .whisper,
            createdAt: now
        )
    }
}
