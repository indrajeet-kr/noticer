import Foundation

/// Knobs the PRD leaves open. Shared limits (90 s, 120 s, 45 s, 3 frames)
/// stay in `SessionLimits`. These are the ones this track had to choose.
///
/// Visitor numbers are starting points for the clip set, not measurements.
/// Rects are caller-supplied (replay or a test). A baby close to the lens can
/// look large in 2D; the persistence count in `SessionLimits` is the other
/// half of the check. The live signal gate does not invent these rects.
public enum EngineTuning {
    /// Minimum height of an adult-sized person, as a fraction of the frame.
    /// A standing adult a few feet away clears 0.40. A baby in arms usually
    /// does not. Raise this if mom-plus-baby false-pauses on real clips.
    public static let visitorMinHeight: Double = 0.40

    /// Minimum box area (`width * height`) in normalized units. Drops a
    /// distant figure or a face on a screen without dropping a second adult
    /// who is actually in the room.
    public static let visitorMinArea: Double = 0.08

    /// Lower bound on width / height. Adults in view are taller than they
    /// are wide. A very narrow sliver is not a person worth pausing for.
    public static let visitorMinAspect: Double = 0.25

    /// Upper bound on width / height. Landscape screens and round close-up
    /// faces sit above this. A second adult's body does not.
    public static let visitorMaxAspect: Double = 0.90

    /// How long a same-chore mark keeps a need open after mom leaves the
    /// frame. The dishwasher story is a back turned for about 90 s, and the
    /// head-start cap is 120 s, so one mark at latch time covers the whole
    /// window. Call `noteSameChore` again to refresh it. Past this age the
    /// 45 s no-person close applies.
    public static let sameChoreWindowSeconds: TimeInterval = 120

    /// `request_head_start_extension` grants this many seconds per call.
    /// The PRD says fixed steps and does not name the step. 15 s moves a
    /// 90 s head start to the 120 s cap in two grants.
    public static let headStartExtensionStepSeconds: TimeInterval = 15

    /// A model call still in flight after this long is retired. A late
    /// reply is dropped. Long enough for the latency the head start hides,
    /// short enough that a lost reply cannot wedge the session.
    public static let inFlightStaleSeconds: TimeInterval = 20
}
