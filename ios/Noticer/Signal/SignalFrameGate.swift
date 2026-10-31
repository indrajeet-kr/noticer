import Foundation
import NoticerCore

struct GateDecision: Sendable, Equatable {
    var snapshot: FrameGateSnapshot
    /// True when the signal gate admitted the frame or asked for an early check.
    var passes: Bool
}

/// On-phone gate. Motion is the mean absolute luma difference. Sharpness is
/// Laplacian variance. Both run on a reused downsampled buffer. Partner in view
/// and wearer hands are not decided here; Muse Spark reports them.
actor SignalFrameGate {
    private var state = SignalGateState()
    private var analysis = [UInt8]()

    func reset() {
        state.reset()
        analysis.removeAll(keepingCapacity: true)
    }

    func evaluate(
        _ frame: CameraFrame,
        needOpen: Bool,
        timing: TimingProfile = .standard,
        latency: LatencyTuning = .default
    ) -> GateDecision {
        let plane = LumaExtractor.plane(
            jpeg: frame.jpegData,
            maxEdge: SignalGateTuning.analysisMaxEdge,
            samples: &analysis
        )
        let decision = SignalGate.evaluate(
            plane: plane,
            at: frame.capturedAt,
            needOpen: needOpen,
            state: &state,
            timing: timing,
            latency: latency
        )
        let snapshot = FrameGateSnapshot(
            capturedAt: frame.capturedAt,
            people: [],
            wearerHandsVisible: false,
            handGateRisingEdge: false,
            motionScore: decision.motionScore,
            sharpness: decision.sharpness,
            sceneActive: decision.sceneActive,
            activityEdge: decision.activityEdge
        )
        return GateDecision(snapshot: snapshot, passes: decision.passes)
    }
}
