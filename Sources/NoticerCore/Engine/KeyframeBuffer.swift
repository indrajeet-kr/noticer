import Foundation

/// Glance keyframes. One sharp frame per glance, and one every
/// `continuousPresenceKeyframeSeconds` while the scene stays active.
/// History older than the profile's buffer window is dropped.
///
/// A glance starts after `glanceAbsentSeconds` without an admitted frame.
/// A person rect from replay or a test counts, and so does `sceneActive`
/// from the signal gate. Only a person rect updates `lastPersonSeenAt`.
/// Spark's `partner_in_view` does that later, through `notePersonSeen`.
/// Inside a glance, a sharper frame (higher Laplacian variance) replaces
/// the current slot until the next presence boundary. Callers pass
/// `sharpness`; this type does not decode JPEG.
struct KeyframeBuffer {
    var timing: TimingProfile

    init(timing: TimingProfile = .standard) {
        self.timing = timing
    }
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
    private var lastActiveAt: Date?
    private var episodeSerial = 0
    private var keyframeSerial = 0
    /// Bumps when a new slot opens. A sharper replacement does not.
    private(set) var revision = 0
    private(set) var lastPersonSeenAt: Date?

    mutating func ingest(
        frame: CameraFrame,
        personPresent: Bool,
        sceneActive: Bool = false,
        sharpness: Double?,
        now: Date,
        recordKeyframe: Bool
    ) {
        let time = frame.capturedAt
        let active = personPresent || sceneActive
        if active {
            let newEpisode: Bool
            if let lastActiveAt {
                newEpisode = time.timeIntervalSince(lastActiveAt) >= timing.glanceAbsentSeconds
            } else {
                newEpisode = true
            }
            if recordKeyframe {
                if newEpisode {
                    freezeOpenSlot()
                    beginSlot(episodeID: nextEpisodeID(), at: time, frame: frame, sharpness: sharpness)
                } else if let slot = openSlot,
                          time.timeIntervalSince(slot.slotStartedAt) >= timing.continuousPresenceKeyframeSeconds {
                    let episodeID = slot.episodeID
                    freezeOpenSlot()
                    beginSlot(episodeID: episodeID, at: time, frame: frame, sharpness: sharpness)
                } else if openSlot == nil {
                    beginSlot(episodeID: nextEpisodeID(), at: time, frame: frame, sharpness: sharpness)
                } else {
                    keepSharper(frame: frame, sharpness: sharpness, time: time)
                }
            }
            lastActiveAt = time
            if personPresent {
                lastPersonSeenAt = time
            }
        } else if let lastActiveAt,
                  time.timeIntervalSince(lastActiveAt) >= timing.glanceAbsentSeconds {
            freezeOpenSlot()
        }
        expire(now: max(now, time))
    }

    /// Spark reported the partner in view, or a sustained latch said she was there.
    /// Scene motion alone does not call this. The 45 s close keeps using this clock.
    mutating func notePersonSeen(at time: Date) {
        if let lastPersonSeenAt, time < lastPersonSeenAt {
            return
        }
        lastPersonSeenAt = time
    }

    mutating func expire(now: Date) {
        committed.removeAll { now.timeIntervalSince($0.capturedAt) > timing.keyframeBufferSeconds }
        if let open = openSlot, now.timeIntervalSince(open.capturedAt) > timing.keyframeBufferSeconds {
            openSlot = nil
        }
    }

    func keyframes(now: Date) -> [Keyframe] {
        var slots = committed.filter {
            now.timeIntervalSince($0.capturedAt) <= timing.keyframeBufferSeconds
        }
        if let openSlot, now.timeIntervalSince(openSlot.capturedAt) <= timing.keyframeBufferSeconds {
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

    /// Up to three keyframes, newest biased, each at least one spacing interval from the last pick.
    func modelStrip(now: Date) -> [Keyframe] {
        let frames = keyframes(now: now)
        var newestFirst: [Keyframe] = []
        for frame in frames.reversed() {
            if let newer = newestFirst.last {
                let gap = newer.capturedAt.timeIntervalSince(frame.capturedAt)
                if gap >= timing.latchMinKeyframeSpacingSeconds {
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
