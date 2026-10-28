import Foundation
import NoticerCore

/// Live glasses camera. Replay clips stay on `ClipLibrary` and `ReplayFrameSource`.
enum DATCameraSeam {
    static let sdkLinked = true
    static let packageURL = "https://github.com/facebook/meta-wearables-dat-ios"
    static let pinnedVersion = "1.0.1"

    static func makeLiveSource() -> DATFrameSource {
        DATFrameSource()
    }
}
