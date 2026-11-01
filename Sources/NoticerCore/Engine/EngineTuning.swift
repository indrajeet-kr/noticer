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

    /// A recheck-clear is a "not sure", not a "gone". Relatch waits only
    /// this long instead of the full relatch cooldown, so one flaky
    /// no-transition cannot silence a need the next verdicts still see.
    public static let recheckRelatchGraceSeconds: TimeInterval = 10

    /// A need stays open this long after its cue so a resolution verdict can
    /// still credit it. Past this the need closes as unknown with the normal
    /// cooldown. Long enough for "he did it right after the whisper".
    public static let postCueResolveSeconds: TimeInterval = 120

    /// Head start has ended, a check that includes this need is still in
    /// flight, and the latest assessment saw the partner. Wait this long for
    /// that reply before whispering. A hung call still cues once the cap
    /// passes. No extra model call is issued.
    public static let partnerInFlightCueHoldSeconds: TimeInterval = 3

    /// A not-sustained hypothesis at or above this confidence earns one
    /// confirm call instead of being dropped.
    public static let confirmMinConfidence: Double = 0.6

    /// The confirm call goes out this soon after the brief sighting.
    public static let confirmDelaySeconds: TimeInterval = 1.5

    /// Two hypotheses for one need inside this window count as sustained,
    /// even when each was individually sustained=false.
    public static let hypothesisRepeatWindowSeconds: TimeInterval = 10

    /// An unlatched wearer action credits only at or above this confidence.
    public static let unpromptedMinConfidence: Double = 0.7

    /// One unprompted credit per need per window. The need stays unlatched,
    /// so without this every heartbeat would credit again.
    public static let unpromptedDebounceSeconds: TimeInterval = 600

    /// A started unprompted action must show its handled state inside this
    /// window, or the start expires with no credit.
    public static let unpromptedCompleteWindowSeconds: TimeInterval = 60

    /// Below this sharpness a frame reads as dark (lens covered or lights
    /// out). Three in a row logs once and holds model calls.
    public static let darkSharpness: Double = 0.005

    /// Consecutive dark frames before the engine calls it dark.
    public static let darkStreakFrames = 3
}

/// How a cue sounds. One place so the speaker, the repeat, and the tests
/// share the same numbers. `speechRateScale` is a fraction of the system
/// speech default (`AVSpeechUtteranceDefaultSpeechRate` on device).
public enum CueSpeechTuning {
    /// 17% slower than the system default. Inside the 15–20% target.
    public static let speechRateScale: Float = 0.83
    /// The one repeat, slower than the first cue (0.70 / 0.83 ≈ another 16%).
    public static let repeatRateScale: Float = 0.70
    /// Synthesizer default is 1. A little under that is a calmer voice.
    public static let pitchMultiplier: Float = 0.92
    /// Whisper loudness. Quiet on purpose; the glasses are in his ear.
    public static let whisperVolume: Float = 0.35
    /// Quiet-phase "mm". Unchanged from the previous chime.
    public static let chimeVolume: Float = 0.20
    /// Silence before the words so a Bluetooth route can open without eating the first syllable.
    public static let preUtteranceSilence: TimeInterval = 0.30
    /// Soft one-note lead-in. On unless he turns it off.
    public static let leadInChimeDefault = true
    public static let leadInChimeDefaultsKey = "noticer.cue.leadInChime"
    /// Length of the synthesized note. Short enough to be a cue, not a tune.
    public static let leadInDuration: TimeInterval = 0.18
    /// C5. Low and plain.
    public static let leadInFrequencyHz: Double = 523
    /// Fraction of full scale. The note should be felt more than noticed.
    public static let leadInAmplitude: Float = 0.12
    /// Say it once more this long after the cue, if nothing has happened.
    public static let repeatDelaySeconds: TimeInterval = 8
    /// A tick may still speak the repeat until this long after the delay.
    /// The live loop ticks several times a second, so this only drops a
    /// repeat that would land long after the moment (a jumped clock).
    public static let repeatWindowSeconds: TimeInterval = 4
    public static let repeatPrefix = "Again,"
    /// `cueFired` detail for the repeat. The first cue keeps the kind name.
    public static let repeatEventDetail = "repeat"
    /// Spoken line cap. Already-short actions are kept even under three words.
    public static let spokenWordLimit = 5
    /// Repeat while he is still new to the need. One self-notice from zero
    /// lands at 0.25; two land at 0.4375; the whisper itself becomes a chime
    /// at `CueFadeSpec.quietThreshold` (0.5). 0.40 sits between the first and
    /// the second self-notice, so a need he has caught once still gets the
    /// repeat, and the repeat drops off while the cue is still words.
    public static let repeatMasteryCutoff: Double = 0.40
}
