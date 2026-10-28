import Foundation
import Synchronization

/// Records cues and does not speak. Tests and the engine can use it before audio exists.
public final class RecordingCueSpeaker: CueSpeaker, Sendable {
    private let spoken: Mutex<[Cue]>

    public init() {
        spoken = Mutex([])
    }

    public func speak(_ cue: Cue) async throws {
        spoken.withLock { cues in
            cues.append(cue)
        }
    }

    public func stop() async {}

    public func spokenCues() -> [Cue] {
        spoken.withLock { $0 }
    }
}
