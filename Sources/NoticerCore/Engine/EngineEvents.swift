import Foundation

public enum ModelCallPurpose: String, Equatable, Sendable, Codable {
    /// Strip just became latch-eligible (two keyframes at least 4 s apart).
    case latch
    /// An open need is due for its 8 s check, or the hand gate rose.
    case heartbeat
    /// Head start ended on evidence older than 30 s. One call before any cue.
    case recheck
    /// A brief sighting gets one focused second look within 1.5 s.
    case confirm
}

public struct PendingModelCall: Equatable, Sendable {
    public var id: String
    public var purpose: ModelCallPurpose
    public var request: ModelRequest
    public var issuedAt: Date

    public init(id: String, purpose: ModelCallPurpose, request: ModelRequest, issuedAt: Date) {
        self.id = id
        self.purpose = purpose
        self.request = request
        self.issuedAt = issuedAt
    }
}

/// What the app can show for an open need. The engine still owns the timers.
public struct OpenNeedState: Equatable, Sendable {
    public var needID: String
    public var latchedAt: Date
    public var cueDeadline: Date
    public var hardCapAt: Date
    public var evidenceAt: Date
    public var handsBusy: Bool
    public var awaitingRecheck: Bool
    public var choreID: String?
    /// Set after one call sees a wearer action. Credit waits for the next call.
    public var pendingWearerAction: String?
    /// Capture time of the oldest keyframe in the strip that latched this need.
    public var visibleAt: Date
    /// Last `log_wearer_intervention` whose action matched this need's signal.
    /// Unlike `pendingWearerAction`, later replies never clear it.
    public var lastMatchingInterventionAt: Date?
    /// Last reply naming this need that saw the partner engaged. Never cleared
    /// while the need is open.
    public var partnerEngagedAt: Date?

    public init(
        needID: String,
        latchedAt: Date,
        cueDeadline: Date,
        hardCapAt: Date,
        evidenceAt: Date,
        handsBusy: Bool,
        awaitingRecheck: Bool,
        choreID: String?,
        pendingWearerAction: String?,
        visibleAt: Date? = nil,
        lastMatchingInterventionAt: Date? = nil,
        partnerEngagedAt: Date? = nil
    ) {
        self.needID = needID
        self.latchedAt = latchedAt
        self.cueDeadline = cueDeadline
        self.hardCapAt = hardCapAt
        self.evidenceAt = evidenceAt
        self.handsBusy = handsBusy
        self.awaitingRecheck = awaitingRecheck
        self.choreID = choreID
        self.pendingWearerAction = pendingWearerAction
        self.visibleAt = visibleAt ?? latchedAt
        self.lastMatchingInterventionAt = lastMatchingInterventionAt
        self.partnerEngagedAt = partnerEngagedAt
    }
}

public struct CueTimingSnapshot: Equatable, Sendable {
    public var cueID: String
    public var needID: String
    public var visibleAt: Date
    public var latchedAt: Date
    public var cueFiredAt: Date

    public init(cueID: String, needID: String, visibleAt: Date, latchedAt: Date, cueFiredAt: Date) {
        self.cueID = cueID
        self.needID = needID
        self.visibleAt = visibleAt
        self.latchedAt = latchedAt
        self.cueFiredAt = cueFiredAt
    }
}

public enum EngineEventKind: String, Equatable, Sendable, Codable {
    case needLatched
    /// An urgent need latched on one fresh cited frame. `needLatched`
    /// still follows; this line carries the evidence id and confidence.
    case latchAccepted
    case latchRejected
    case cueFired
    case cueDeferredHandsBusy
    case cueDeferredRateLimit
    /// Head start ended while a check for this need was in flight and the
    /// partner was in view. The whisper waits for that reply, briefly.
    case cueDeferredPartnerCheck
    case caughtHimself
    case resolvedByOther
    case closedUnknown
    case falseCueDismissed
    case masteryRetired
    case masteryUnretired
    case needReset
    case visitorPaused
    case visitorResumed
    case headStartExtended
    case headStartExtensionDenied
    case recheckRequested
    case actionRejected
    case assessmentDropped
    case staleReplyDropped
    case callBudgetExhausted
    case sessionEnded
    case retiredMiss
    case callIssued
    case stillOpen
    /// A `partner_state_evidence` token naming no part id and matching no
    /// condition part. Detail is `token=<t>`; the token is the model's own
    /// text, so it is safe to log.
    case partTokenUnknown = "partToken-unknown"
    case skip
    /// A brief high-confidence sighting earned one focused second look.
    case confirmScheduled
    /// A confirm reply cited only the old source frames. Inconclusive.
    case confirmSelfOnly
    /// The confirm's new frame shows the anchor handled. Sighting over.
    case confirmCleared
    /// An inconclusive confirm gets another attempt with a new frame.
    case confirmRetry
    /// A sighting ended: latched, cleared, exhausted, expired, stopped,
    /// or removed. The only confirm-state clearing, always logged.
    case confirmEnded
    /// Two hypotheses inside 10 s latched without either being sustained.
    case sustainedByRepeat
    /// He did a listed need's action with nothing open. Credit, no cue.
    case selfNoticedUnprompted
    /// A check-in need held its whisper because she is asleep.
    case quietPartnerAsleep
    /// Three dark frames in a row. The phone renders this as [FRAME] dark.
    case frameDark
    /// A wearer action started outside any episode. No credit yet.
    case unpromptedStarted
    /// An open episode at verdict start closed during it; the closing
    /// path already credited, so the unprompted path skips.
    case unpromptedSkipped
    /// A started action never showed its handled state in time. No credit.
    case unpromptedExpired
}

public struct EngineEvent: Equatable, Sendable {
    public var kind: EngineEventKind
    public var needID: String?
    public var at: Date
    public var detail: String?
    /// The open episode this event belongs to, for the five latch-scoped
    /// kinds (`cueFired`, `caughtHimself`, `resolvedByOther`,
    /// `closedUnknown`, `stillOpen`). Nil for everything else, including
    /// unprompted completions, which by definition have no episode.
    public var episodeID: String?

    public init(kind: EngineEventKind, needID: String?, at: Date, detail: String? = nil, episodeID: String? = nil) {
        self.kind = kind
        self.needID = needID
        self.at = at
        self.detail = detail
        self.episodeID = episodeID
    }

    /// A shared finish: she started it, he wrapped it up.
    public var isSharedFinish: Bool {
        kind == .caughtHimself && detail == "shared-finish"
    }
}

/// How the latest close read, for the phone's shared-finish log line. No new
/// `EngineEventKind`, so persistence stays backward-compatible.
public struct ResolutionOutcome: Equatable, Sendable {
    public var needID: String
    public var sharedWithPartner: Bool
    public var partnerSeenSecondsAgo: TimeInterval?
    public var wearerActedSecondsAgo: TimeInterval?
    public var at: Date

    public init(
        needID: String,
        sharedWithPartner: Bool,
        partnerSeenSecondsAgo: TimeInterval? = nil,
        wearerActedSecondsAgo: TimeInterval? = nil,
        at: Date
    ) {
        self.needID = needID
        self.sharedWithPartner = sharedWithPartner
        self.partnerSeenSecondsAgo = partnerSeenSecondsAgo
        self.wearerActedSecondsAgo = wearerActedSecondsAgo
        self.at = at
    }
}

public enum NeedListError: Error, Equatable, Sendable {
    case exceedsAuthoredLimit(Int)
    case duplicateIdentifier(String)
    case unknownNeed(String)
}
