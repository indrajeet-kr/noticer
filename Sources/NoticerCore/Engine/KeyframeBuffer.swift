import Foundation

/// Glance keyframes. One sharp frame per glance, and one every 4 s while she
/// stays in view. History older than 60 s is dropped.
///
/// A glance starts when a person is present after at least 2 s absent.
/// Inside a glance, a sharper frame (higher Laplacian variance) replaces the
/// current slot until the next 4 s boundary. Callers pass `sharpness`; this
/// type does not decode JPEG.
struct KeyframeBuffer {
    private struct Slot {
        var id: String
        var episodeID: String
        var slotStartedAt: Date
        var capturedAt: Date
        var sharpness: Double?
        var jpegData: Data
    }

    private var committed: [Slot] = []
    private var openSlot: Slot?
    private var lastPersonAt: Date?
    private var episodeSerial = 0
    private var keyframeSerial = 0
    /// Bumps when a new slot opens. A sharper replacement does not.
    private(set) var revision = 0
    private(set) var lastPersonSeenAt: Date?

    mutating func ingest(
        frame: CameraFrame,
        personPresent: Bool,
        sharpness: Double?,
        now: Date,
        recordKeyframe: Bool
    ) {
        let time = frame.capturedAt
        if personPresent {
            let newEpisode: Bool
            if let lastPersonAt {
                newEpisode = time.timeIntervalSince(lastPersonAt) >= SessionLimits.glanceAbsentSeconds
            } else {
                newEpisode = true
            }
            if recordKeyframe {
                if newEpisode {
                    freezeOpenSlot()
                    beginSlot(episodeID: nextEpisodeID(), at: time, frame: frame, sharpness: sharpness)
                } else if let slot = openSlot,
                          time.timeIntervalSince(slot.slotStartedAt) >= SessionLimits.continuousPresenceKeyframeSeconds {
                    let episodeID = slot.episodeID
                    freezeOpenSlot()
                    beginSlot(episodeID: episodeID, at: time, frame: frame, sharpness: sharpness)
                } else if openSlot == nil {
                    beginSlot(episodeID: nextEpisodeID(), at: time, frame: frame, sharpness: sharpness)
                } else {
                    keepSharper(frame: frame, sharpness: sharpness, time: time)
                }
            }
            lastPersonAt = time
            lastPersonSeenAt = time
        } else if let lastPersonAt,
                  time.timeIntervalSince(lastPersonAt) >= SessionLimits.glanceAbsentSeconds {
            freezeOpenSlot()
        }
        expire(now: max(now, time))
    }

    mutating func expire(now: Date) {
        committed.removeAll { now.timeIntervalSince($0.capturedAt) > SessionLimits.keyframeBufferSeconds }
        if let open = openSlot, now.timeIntervalSince(open.capturedAt) > SessionLimits.keyframeBufferSeconds {
            openSlot = nil
        }
    }

    func keyframes(now: Date) -> [Keyframe] {
        var slots = committed.filter {
            now.timeIntervalSince($0.capturedAt) <= SessionLimits.keyframeBufferSeconds
        }
        if let openSlot, now.timeIntervalSince(openSlot.capturedAt) <= SessionLimits.keyframeBufferSeconds {
            slots.append(openSlot)
        }
        slots.sort { $0.capturedAt < $1.capturedAt }
        guard let newest = slots.map(\.capturedAt).max() else { return [] }
        return slots.map { slot in
            Keyframe(
                id: slot.id,
                capturedAt: slot.capturedAt,
                ageSeconds: newest.timeIntervalSince(slot.capturedAt),
                episodeID: slot.episodeID,
                sharpness: slot.sharpness,
                jpegData: slot.jpegData
            )
        }
    }

    /// Up to three keyframes, newest biased, each at least 4 s from the last pick.
    func modelStrip(now: Date) -> [Keyframe] {
        let frames = keyframes(now: now)
        var newestFirst: [Keyframe] = []
        for frame in frames.reversed() {
            if let newer = newestFirst.last {
                let gap = newer.capturedAt.timeIntervalSince(frame.capturedAt)
                if gap >= SessionLimits.latchMinKeyframeSpacingSeconds {
                    newestFirst.append(frame)
                }
            } else {
                newestFirst.append(frame)
            }
            if newestFirst.count == 3 { break }
        }
        return Array(newestFirst.reversed())
    }

    private mutating func beginSlot(episodeID: String, at time: Date, frame: CameraFrame, sharpness: Double?) {
        keyframeSerial += 1
        revision += 1
        openSlot = Slot(
            id: "kf-\(keyframeSerial)",
            episodeID: episodeID,
            slotStartedAt: time,
            capturedAt: time,
            sharpness: sharpness,
            jpegData: frame.jpegData
        )
    }

    private mutating func freezeOpenSlot() {
        guard let openSlot else { return }
        committed.append(openSlot)
        self.openSlot = nil
    }

    private mutating func keepSharper(frame: CameraFrame, sharpness: Double?, time: Date) {
        guard var slot = openSlot else { return }
        guard replaces(current: slot.sharpness, with: sharpness) else { return }
        slot.sharpness = sharpness
        slot.capturedAt = time
        slot.jpegData = frame.jpegData
        openSlot = slot
    }

    private func replaces(current: Double?, with new: Double?) -> Bool {
        switch (current, new) {
        case let (current?, new?):
            return new > current
        case (nil, .some):
            return true
        default:
            return false
        }
    }

    private mutating func nextEpisodeID() -> String {
        episodeSerial += 1
        return "episode-\(episodeSerial)"
    }
}
