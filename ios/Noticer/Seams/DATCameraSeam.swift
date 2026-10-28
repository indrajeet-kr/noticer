import NoticerCore

/// DAT SEAM. Step 0 does not link the Meta Wearables DAT SDK.
///
/// The iOS track replaces `UnlinkedDATFrameSource` with a `FrameSource` that
/// reads the glasses camera. Replay clips can later go through Mock Device Kit
/// `setCameraFeed(fileURL:)` behind the same protocol. Do not import `MWDAT`
/// or the mock device kit in this step.
///
/// Also still owned here, and not built yet: the Apple Vision person and hand
/// gate, foreground-only session handling, and `CAPABILITY_DENIED` / thermal /
/// battery notices. Accept a Gen 3 device type instead of gating on `.rayBanMeta`.
enum DATCameraSeam {
    static let sdkLinked = false

    static func makeLiveSource() -> any FrameSource {
        UnlinkedDATFrameSource()
    }
}
