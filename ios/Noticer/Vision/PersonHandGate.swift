import CoreGraphics
import Foundation
import ImageIO
import NoticerCore
import Vision

struct GateDecision: Sendable, Equatable {
    var snapshot: FrameGateSnapshot
    /// A frame passes when Vision sees a person or a wearer hand.
    var passes: Bool
}

/// On-device person and hand gate. Counting visitors and choosing keyframes
/// belong to the core track. This type only fills `FrameGateSnapshot` and
/// decides whether the frame is worth handing on.
actor PersonHandGate {
    /// TODO(verify): Vision joint confidence is 0...1. 0.5 is a local cutoff, not a PRD number.
    private static let minimumConfidence: Float = 0.5
    /// TODO(verify): wearer-hand heuristic. Vision's origin is the lower left, so a
    /// wrist below this line is treated as the wearer's hand in an egocentric frame.
    /// Adult versus baby size is intentionally not decided here.
    private static let wearerWristMaxY: CGFloat = 0.55

    private var wearerHandsWereVisible = false

    func reset() {
        wearerHandsWereVisible = false
    }

    func evaluate(_ frame: CameraFrame) -> GateDecision {
        guard let image = Self.cgImage(from: frame.jpegData) else {
            return decision(at: frame.capturedAt, people: [], wearerHands: false)
        }
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let hands = VNDetectHumanHandPoseRequest()
        let bodies = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([humans, hands, bodies])
        } catch {
            return decision(at: frame.capturedAt, people: [], wearerHands: false)
        }

        var people = Self.people(from: humans.results ?? [])
        if people.isEmpty {
            people = Self.people(fromBodies: bodies.results ?? [])
        }
        let wearerHands = Self.wearerHandsVisible(in: hands.results ?? [])
        return decision(at: frame.capturedAt, people: people, wearerHands: wearerHands)
    }

    private func decision(
        at capturedAt: Date,
        people: [ObservedPerson],
        wearerHands: Bool
    ) -> GateDecision {
        let rising = wearerHands && !wearerHandsWereVisible
        wearerHandsWereVisible = wearerHands
        let snapshot = FrameGateSnapshot(
            capturedAt: capturedAt,
            people: people,
            wearerHandsVisible: wearerHands,
            handGateRisingEdge: rising
        )
        return GateDecision(snapshot: snapshot, passes: !people.isEmpty || wearerHands)
    }

    private static func cgImage(from jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func people(from observations: [VNHumanObservation]) -> [ObservedPerson] {
        observations.map { observation in
            person(from: observation.boundingBox)
        }
    }

    /// TODO(verify): when human rectangles miss, a rect built from body-pose joints
    /// is still in Vision's normalized space. It is not a measured human rectangle.
    private static func people(fromBodies observations: [VNHumanBodyPoseObservation]) -> [ObservedPerson] {
        observations.compactMap { observation in
            guard let points = try? observation.recognizedPoints(.all) else {
                return nil
            }
            let trusted = points.values.filter { $0.confidence >= minimumConfidence }
            guard let box = boundingBox(of: trusted.map(\.location)) else {
                return nil
            }
            return person(from: box)
        }
    }

    private static func wearerHandsVisible(in observations: [VNHumanHandPoseObservation]) -> Bool {
        observations.contains { observation in
            guard let wrist = try? observation.recognizedPoint(.wrist) else {
                return false
            }
            return wrist.confidence >= minimumConfidence && wrist.location.y < wearerWristMaxY
        }
    }

    private static func person(from box: CGRect) -> ObservedPerson {
        let aspect = box.height > 0 ? Double(box.width / box.height) : 0
        return ObservedPerson(
            boundingBox: NormalizedRect(
                x: Double(box.origin.x),
                y: Double(box.origin.y),
                width: Double(box.width),
                height: Double(box.height)
            ),
            aspectRatio: aspect
        )
    }

    private static func boundingBox(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else {
            return nil
        }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else {
            return nil
        }
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
}
