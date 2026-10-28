import Foundation

public enum FrameSourceError: Error, Equatable, Sendable {
    /// Live capture is not linked. The DAT SDK stays out of this package until the iOS track adds it.
    case datSDKNotLinked
}

/// Live glasses (later) or a replay tape of frames.
///
/// `nil` means the tape ended. Transport and session failures throw.
public protocol FrameSource: Sendable {
    func nextFrame() async throws -> CameraFrame?
}
