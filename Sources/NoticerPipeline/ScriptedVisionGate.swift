import Foundation
import NoticerCore

/// Stand-in for the on-device Vision gate.
///
/// Linux replay has no Vision. A fixture says who is in the frame, and this
/// builds the same `FrameGateSnapshot` the phone gate would. The iOS app uses
/// `PersonHandGate` instead and passes that snapshot into the pipeline.
public enum ScriptedVisionGate {
    public static let mom = "mom"
    public static let none = "none"
    public static let momAndBaby = "mom-and-baby"
    public static let knownPresets = [mom, none, momAndBaby]

    public static func snapshot(at time: Date, people preset: String, handsRising: Bool) -> FrameGateSnapshot {
        FrameGateSnapshot(
            capturedAt: time,
            people: people(for: preset),
            wearerHandsVisible: handsRising,
            handGateRisingEdge: handsRising
        )
    }

    /// Mom's box matches the engine tests: tall enough to be a person, and
    /// only one of her, so the visitor rule does not pause upload.
    private static func people(for preset: String) -> [ObservedPerson] {
        switch preset {
        case mom:
            return [adult(width: 0.30, height: 0.70, x: 0.10)]
        case momAndBaby:
            return [
                adult(width: 0.30, height: 0.70, x: 0.10),
                adult(width: 0.18, height: 0.22, x: 0.40),
            ]
        default:
            return []
        }
    }

    private static func adult(width: Double, height: Double, x: Double) -> ObservedPerson {
        ObservedPerson(
            boundingBox: NormalizedRect(x: x, y: 0.10, width: width, height: height),
            aspectRatio: width / height
        )
    }
}
