import Foundation

/// One camera frame held in memory. Callers discard it after the gate or the model call.
/// This type is not written to disk by the package.
public struct CameraFrame: Equatable, Sendable {
    public var capturedAt: Date
    public var jpegData: Data
    public var width: Int
    public var height: Int

    public init(capturedAt: Date, jpegData: Data, width: Int, height: Int) {
        self.capturedAt = capturedAt
        self.jpegData = jpegData
        self.width = width
        self.height = height
    }
}
