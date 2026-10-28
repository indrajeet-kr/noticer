import Foundation
import Synchronization

/// Plays a list of frames, then returns nil. It does not open video files or the DAT SDK.
public final class ReplayFrameSource: FrameSource, Sendable {
    private struct State: Sendable {
        var frames: [CameraFrame]
        var index: Int
    }

    private let state: Mutex<State>

    public init(frames: [CameraFrame]) {
        state = Mutex(State(frames: frames, index: 0))
    }

    public func nextFrame() async throws -> CameraFrame? {
        state.withLock { state in
            guard state.index < state.frames.count else {
                return nil
            }
            let frame = state.frames[state.index]
            state.index += 1
            return frame
        }
    }
}
