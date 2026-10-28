import Foundation

/// On-device visitor check. Upload pauses only after a second adult-sized
/// person has been in frame for `SessionLimits.visitorPersistenceFrames`
/// consecutive frames. Mom plus a baby fails the size check, so it does not pause.
struct VisitorMonitor {
    private(set) var consecutiveQualifyingFrames = 0
    private(set) var uploadPaused = false
    /// True when this frame itself has two adult-sized people, even before the run hits 3.
    private(set) var currentFrameQualifies = false

    mutating func observe(_ people: [ObservedPerson]) {
        let qualifies = Self.hasTwoAdultSizedPeople(people)
        currentFrameQualifies = qualifies
        if qualifies {
            consecutiveQualifyingFrames += 1
            if consecutiveQualifyingFrames >= SessionLimits.visitorPersistenceFrames {
                uploadPaused = true
            }
        } else {
            consecutiveQualifyingFrames = 0
            uploadPaused = false
        }
    }

    /// The largest box is not special. A near baby can be the large rect and
    /// mom the smaller one, so "second person" means two boxes that each pass
    /// the adult size and aspect bounds.
    static func hasTwoAdultSizedPeople(_ people: [ObservedPerson]) -> Bool {
        people.reduce(0) { count, person in
            count + (isAdultSized(person) ? 1 : 0)
        } >= 2
    }

    static func isAdultSized(_ person: ObservedPerson) -> Bool {
        let box = person.boundingBox
        let area = box.width * box.height
        return box.height >= EngineTuning.visitorMinHeight
            && area >= EngineTuning.visitorMinArea
            && person.aspectRatio >= EngineTuning.visitorMinAspect
            && person.aspectRatio <= EngineTuning.visitorMaxAspect
    }
}
