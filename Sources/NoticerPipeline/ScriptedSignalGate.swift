import Foundation
import NoticerCore

/// Stand-in for the on-phone signal gate during replay.
///
/// A fixture says who is in the frame. This builds the same `FrameGateSnapshot`
/// the phone would hand the engine: person rects for the visitor rule, and
/// `sceneActive` when the preset is not empty so a keyframe can be admitted
/// without a live luma plane. The iOS app uses `SignalFrameGate` on real pixels
/// and leaves `people` empty. Partner in view and hands come back from Muse Spark.
public enum ScriptedSignalGate {
    public static let mom = "mom"
    public static let none = "none"
    public static let momAndBaby = "mom-and-baby"
    public static let knownPresets = [mom, none, momAndBaby]

    public static func snapshot(at time: Date, people preset: String, handsRising: Bool) -> FrameGateSnapshot {
        let people = people(for: preset)
        let active = !people.isEmpty
        return FrameGateSnapshot(
            capturedAt: time,
            people: people,
            wearerHandsVisible: handsRising,
            handGateRisingEdge: handsRising,
            motionScore: active ? 0.2 : 0,
            sharpness: active ? 0.01 : 0,
            sceneActive: active,
            activityEdge: false
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
