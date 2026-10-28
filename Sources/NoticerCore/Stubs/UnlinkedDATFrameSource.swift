import Foundation

/// DAT SEAM. This package does not link the Meta Wearables DAT SDK.
///
/// The iOS track replaces this with a `FrameSource` over the glasses camera
/// (or Mock Device Kit's camera feed for replay clips). Do not import DAT here.
public struct UnlinkedDATFrameSource: FrameSource, Sendable {
    public init() {}

    public func nextFrame() async throws -> CameraFrame? {
        throw FrameSourceError.datSDKNotLinked
    }
}
