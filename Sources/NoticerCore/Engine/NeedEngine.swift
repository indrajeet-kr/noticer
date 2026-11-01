import Foundation

/// Deterministic need engine. The model may request a latch, a deferral, an
/// extension, or a wearer action. This type decides whether that request is
/// allowed, when a cue plays, and how mastery moves.
///
/// Pass a `Clock`. Tests use `ManualClock` and then call `tick()`. Frame
/// `capturedAt` should match `clock.now()` at ingest; spacing uses the frame
/// time and every deadline uses the clock.
///
/// The caller serializes access. The engine does not talk to the network
/// or the speaker. It records cues; something else plays them. Person rects
/// on a gate snapshot are caller input. Live frames admit keyframes with
/// `sceneActive`. Partner in view comes back on the model assessment.
public struct NeedEngine<TimeSource: Clock> {
    public static var unspecifiedResolutionSignal: String {
        "unspecified — use report_need_resolved only when the problem state is clearly gone"
    }

    private struct ChoreMark: Equatable {
        var id: String
        var at: Date
    }

    private struct PendingConfirm: Equatable {
        var dueAt: Date
        /// The actual source frames: what the model cited, or the strip's
        /// newest frame when it cited nothing. Capture times ride along.
        var sourceFrames: [Keyframe]
        /// When the hypothesis call returned. New confirm frames must be
        /// captured after this, and the 8 s cap runs from here.
        var hypothesisAt: Date
        var attemptsIssued: Int
        /// New-frame ids already sent for this sighting. Never resent.
        var usedNewFrameIDs: Set<String>
    }

    private enum ConfirmOutcome: String {
        case latched
        case cleared
        case exhausted
        case expired
        case stopped
        case removed
    }

    private struct TrackedNeed {
        var needID: String
        /// One latch, one episode. Every engine event about the latch
        /// carries it, so the phone can match a cue to its resolution.
        var episodeID: String
        var visibleAt: Date
        var latchedAt: Date
        var cueDeadline: Date
        var hardCapAt: Date
        var evidenceAt: Date
        var handsBusy: Bool
        var awaitingRecheck: Bool
        var recheckUsed: Bool
        var inconclusiveHold: Bool
        var pendingCueKind: CueKind?
        var choreID: String?
        var pendingWearerAction: String?
        var didLogBusyDefer: Bool
        var didLogRateLimit: Bool
        var cueDelivered: Bool
        /// True when the latch verdict said the partner was verifiably absent.
        /// Such a need holds without her by definition and never no-person-closes.
        var latchedWhileAbsent: Bool
        /// Consecutive recheck verdicts that said the need is gone. One is a
        /// flaky frame; two closes. Any sustained verdict resets it.
        var recheckStrikes: Int
        /// When the cue fired, if it did. The need stays open after that so
        /// a resolution verdict can still credit it.
        var cueFiredAt: Date?
        var cueID: String?
        /// One slower "Again" after the cue, if he is still new to the need.
        var repeatDueAt: Date? = nil
        var repeatDelivered: Bool = false
        var repeatAllowed: Bool = false
        /// Last matching intervention. Later replies never clear it.
        var lastMatchingInterventionAt: Date? = nil
        /// Last reply naming this need that saw the partner engaged.
        var partnerEngagedAt: Date? = nil
        /// Logged once per open need when the whisper waits on an in-flight check.
        var didLogPartnerHold: Bool = false
    }

    private struct CueEffect {
        var needID: String
        var masteryBefore: MasteryState
        var dismissed: Bool
    }

    private struct Catalog {
        private(set) var needs: [Need]

        init(_ needs: [Need]) throws {
            if needs.count > SessionLimits.maxAuthoredNeeds {
                throw NeedListError.exceedsAuthoredLimit(SessionLimits.maxAuthoredNeeds)
            }
            var seen = Set<String>()
            for need in needs {
                if !seen.insert(need.id).inserted {
                    throw NeedListError.duplicateIdentifier(need.id)
                }
            }
            self.needs = needs
        }

        func need(id: String) -> Need? {
            needs.first { $0.id == id }
        }

        mutating func update(_ need: Need) {
            guard let index = needs.firstIndex(where: { $0.id == need.id }) else { return }
            needs[index] = need
        }

        func priority(of id: String) -> Int {
            need(id: id)?.priority ?? Int.max
        }
    }

    private let clock: TimeSource
    private let timing: TimingProfile
    public let latency: LatencyTuning
    private var catalog: Catalog
    private var buffer: KeyframeBuffer
    private var visitor = VisitorMonitor()
    private var tracked: [TrackedNeed] = []
    private var choreMark: ChoreMark?
    private var events: [EngineEvent] = []
    private var playedCues: [Cue] = []
    private var recordedCueTimings: [CueTimingSnapshot] = []
    private var cueEffects: [String: CueEffect] = [:]
    private var closedAt: [String: Date] = [:]
    private var sessionStartedAt: Date
    private var didLogSessionEnd = false
    private var sessionStopped = false
    private var didLogBudget = false
    private var callSerial = 0
    private var cueSerial = 0
    private var lastModelCallAt: Date?
    private var lastHeartbeatAt: Date?
    private var lastLatchCallAt: Date?
    /// Idle-latch token bucket: capacity 2, refill 1 per 10 s. Every idle
    /// latch spends a token. A rising scene change may spend one early;
    /// sustained motion does not.
    private var idleBucketTokens = 2.0
    private var idleBucketUpdatedAt: Date?
    /// A rising motion edge, hand-gate edge, or activity edge since the last
    /// latch call. Cleared when that call is issued. Sustained high motion
    /// does not set this again.
    private var sceneChangedSinceLatchCall = false
    /// Motion on the previous ingested frame, for the rising-edge check.
    private var previousMotionScore: Double = 0
    /// Whether the previous frame already carried a hand or activity edge.
    private var previousGateEdge = false
    /// Latest `partner_in_view` from a completed assessment. Nil until the
    /// model says. A cue hold reads this; it is not sticky across "she left".
    private var latestPartnerInView: Bool?
    private var lastSuccessfulLatchAt: Date?
    private var revisionAtLastLatchCall = 0
    private var lastCueAt: Date?
    /// Live and Demo mode leave this on. Plain replay turns it off so a
    /// review of a take does not invent a second utterance.
    private var repeatsEnabled = true
    private var handEdgePending = false
    private var staleCallIDs: Set<String> = []
    private var callsIssued = 0
    private var callIssuedTimestamps: [Date] = []
    private var stripSignatureAtLastCall: String?
    private var newestSlotAtLastIssuedCall: Date?
    private var newestAppliedIssuedAt: Date?
    private var recheckSameStripBypassAvailable = true
    private var latchConfirmPending = false
    private var lastLoggedSkip: String?
    /// One sighting per need: source frames plus up to three attempts with
    /// new frames inside 8 s. Cleared only through `finishConfirm`.
    private var pendingConfirms: [String: PendingConfirm] = [:]
    /// Last latch hypothesis per need, for the sustained-by-repeat rule.
    private var recentHypothesisAt: [String: Date] = [:]
    /// Last unprompted credit per need. Debounced to one per 10 minutes.
    private var unpromptedCreditedAt: [String: Date] = [:]
    /// Latest `partner_asleep` from a completed assessment. Nil until the
    /// model says. Check-in needs hold their whisper while this is true.
    private var latestPartnerAsleep: Bool?
    /// Needs already logged quiet for the current sleep episode. Cleared
    /// when a verdict stops saying asleep.
    private var quietAsleepLoggedNeedIDs: Set<String> = []
    /// Consecutive ingested frames reading dark. Calls hold at three until
    /// a readable frame clears the streak.
    private var darkStreak = 0
    private var darkStreakLogged = false
    /// Episode counter. `e1`, `e2`, … in latch order.
    private var nextEpisodeNumber = 1
    /// Last closed episode per need, so the closing event still carries it.
    private var lastClosedEpisodeID: [String: String] = [:]
    /// Wearer actions started outside any episode, awaiting their handled
    /// state. Arming is not credit; only completion credits.
    private var unpromptedPending: [String: UnpromptedStart] = [:]
    /// Self-notice steps this verdict. At most one; the assert at the end
    /// of `handle` proves the credit paths never double-count.
    private var debugMasteryMutations = 0

    private struct UnpromptedStart: Equatable {
        var actionCode: String
        var at: Date
    }

    public private(set) var pendingModelCalls: [PendingModelCall] = []
    public var pendingModelCall: PendingModelCall? { pendingModelCalls.first }
    public private(set) var visitorUploadPaused = false

    public init(
        clock: TimeSource,
        needs: [Need] = [],
        timing: TimingProfile = .standard,
        latency: LatencyTuning = .default
    ) throws {
        self.clock = clock
        self.timing = timing
        self.latency = latency
        buffer = KeyframeBuffer(timing: timing)
        catalog = try Catalog(needs)
        sessionStartedAt = clock.now()
    }

    public var needs: [Need] { catalog.needs }

    public var modelCallsIssued: Int { callsIssued }

    public var log: [EngineEvent] { events }

    public var cues: [Cue] { playedCues }

    public var cueTimings: [CueTimingSnapshot] { recordedCueTimings }

    public var bufferRevision: Int { buffer.revision }

    public var openNeedIDs: [String] { tracked.map(\.needID) }

    /// How the latest `resolve()` close read. The phone logs shared finishes from this.
    public private(set) var lastResolution: ResolutionOutcome?

    public func callsInLastMinute(now: Date? = nil) -> Int {
        let cutoff = (now ?? clock.now()).addingTimeInterval(-60)
        return callIssuedTimestamps.filter { $0 > cutoff }.count
    }

    public func keyframes(now: Date? = nil) -> [Keyframe] {
        buffer.keyframes(now: now ?? clock.now())
    }

    public var openNeeds: [OpenNeedState] {
        tracked.map { item in
            OpenNeedState(
                needID: item.needID,
                latchedAt: item.latchedAt,
                cueDeadline: item.cueDeadline,
                hardCapAt: item.hardCapAt,
                evidenceAt: item.evidenceAt,
                handsBusy: item.handsBusy,
                awaitingRecheck: item.awaitingRecheck,
                choreID: item.choreID,
                pendingWearerAction: item.pendingWearerAction,
                visibleAt: item.visibleAt,
                lastMatchingInterventionAt: item.lastMatchingInterventionAt,
                partnerEngagedAt: item.partnerEngagedAt
            )
        }
    }

    public mutating func setNeeds(_ needs: [Need]) throws {
        let replacement = try Catalog(needs)
        catalog = replacement
        tracked.removeAll { catalog.need(id: $0.needID) == nil }
        // A removed or paused need ends its sighting too: the phone never
        // sends paused needs here, so absence covers both.
        for needID in Array(pendingConfirms.keys) where catalog.need(id: needID) == nil {
            finishConfirm(needID: needID, outcome: .removed)
        }
    }

    /// Mom resets a need back to coaching. An open copy closes and the
    /// re-latch cooldown is cleared so her reset takes effect now.
    public mutating func resetNeed(_ id: String) throws {
        guard var need = catalog.need(id: id) else {
            throw NeedListError.unknownNeed(id)
        }
        need.mastery = .initial
        catalog.update(need)
        if let index = indexOfOpen(id) {
            tracked.remove(at: index)
        }
        closedAt[id] = nil
        record(.needReset, needID: id, detail: nil)
    }

    /// He is still at `choreID`. While the mark is inside
    /// `EngineTuning.sameChoreWindowSeconds`, a need bound to that chore
    /// stays open with no person in frame.
    public mutating func noteSameChore(_ choreID: String) {
        let trimmed = choreID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = clock.now()
        choreMark = ChoreMark(id: trimmed, at: now)
        for index in tracked.indices {
            if tracked[index].choreID == nil || tracked[index].choreID == trimmed {
                tracked[index].choreID = trimmed
            }
        }
    }

    public mutating func clearSameChore() {
        choreMark = nil
    }

    /// Plain replay turns repeats off. Live and Demo mode leave them on.
    /// Stopping the session is separate: `stopSession()` drops a pending repeat.
    public mutating func setRepeatsEnabled(_ enabled: Bool) {
        repeatsEnabled = enabled
    }

    /// The phone calls this when the session stops (live, demo, or replay)
    /// so a later tick cannot speak the repeat.
    public mutating func stopSession() {
        sessionStopped = true
        if !didLogSessionEnd {
            didLogSessionEnd = true
            record(.sessionEnded, needID: nil, detail: "stopped")
        }
        for needID in Array(pendingConfirms.keys) {
            finishConfirm(needID: needID, outcome: .stopped)
        }
        pendingModelCalls.removeAll()
    }

    /// A phone tap that this whisper was wrong. Mastery returns to the
    /// pre-cue value. The cue still counts toward the rate limit.
    public mutating func dismissFalseCue(_ cueID: String) {
        guard var effect = cueEffects[cueID], !effect.dismissed else { return }
        guard var need = catalog.need(id: effect.needID) else { return }
        need.mastery = effect.masteryBefore
        catalog.update(need)
        effect.dismissed = true
        cueEffects[cueID] = effect
        if let index = indexOfOpen(effect.needID) {
            tracked[index].repeatAllowed = false
            tracked[index].repeatDelivered = true
        }
        record(.falseCueDismissed, needID: effect.needID, detail: cueID)
    }

    public mutating func ingest(frame: CameraFrame, gate: FrameGateSnapshot, sharpness: Double? = nil) {
        let wasPaused = visitor.uploadPaused
        visitor.observe(gate.people)
        visitorUploadPaused = visitor.uploadPaused
        if visitor.uploadPaused && !wasPaused {
            record(.visitorPaused, needID: nil, detail: nil)
        } else if !visitor.uploadPaused && wasPaused {
            record(.visitorResumed, needID: nil, detail: nil)
        }

        let personPresent = !gate.people.isEmpty
        // A qualifying visitor frame is not a keyframe. It would leave the phone.
        let prevRevision = buffer.revision
        buffer.ingest(
            frame: frame,
            personPresent: personPresent,
            sceneActive: gate.sceneActive,
            sharpness: sharpness ?? gate.sharpness,
            now: clock.now(),
            recordKeyframe: !visitor.currentFrameQualifies
        )
        if buffer.revision != prevRevision {
            lastLoggedSkip = nil
        }
        trackDarkness(sharpness: sharpness ?? gate.sharpness)
        let edgeNow = gate.handGateRisingEdge || gate.activityEdge
        if edgeNow {
            handEdgePending = true
        }
        // A level of high motion is not a new scene. Only a rise through the
        // activity threshold, or a fresh hand/activity edge, may buy one
        // early idle check.
        let motionRose: Bool
        if let motion = gate.motionScore {
            motionRose = motion >= SignalGateTuning.activityEdgeMotion
                && previousMotionScore < SignalGateTuning.activityEdgeMotion
            previousMotionScore = motion
        } else {
            motionRose = false
        }
        let edgeRose = edgeNow && !previousGateEdge
        previousGateEdge = edgeNow
        if motionRose || edgeRose {
            sceneChangedSinceLatchCall = true
        }
        // Evidence age follows a person rect or, later, Spark's partner_in_view.
        // A motion keyframe alone does not refresh it.
        if personPresent {
            refreshEvidenceFromKeyframes()
        }
        evaluate()
    }

    public mutating func tick() {
        evaluate()
    }

    public mutating func handle(callID: String, verdict: ModelVerdict) {
        let now = clock.now()
        guard let callIndex = pendingModelCalls.firstIndex(where: { $0.id == callID }) else {
            record(.staleReplyDropped, needID: verdict.assessment.needID, detail: callID)
            return
        }
        let completedCall = pendingModelCalls.remove(at: callIndex)
        debugMasteryMutations = 0
        // Unprompted means outside any episode. Snapshot the open episodes
        // before this verdict closes one of them.
        let openAtVerdictStart = Set(tracked.map(\.needID))
        if latency.concurrentInFlight,
           let newestAppliedIssuedAt,
           completedCall.issuedAt < newestAppliedIssuedAt {
            record(.staleReplyDropped, needID: verdict.assessment.needID, detail: callID)
            return
        }
        if let currentNewest = newestAppliedIssuedAt {
            if completedCall.issuedAt > currentNewest {
                newestAppliedIssuedAt = completedCall.issuedAt
            }
        } else {
            newestAppliedIssuedAt = completedCall.issuedAt
        }

        let namedNeedID = verdict.assessment.needID
        var verdict = verdict
        verdict.assessment = sanitize(verdict.assessment)
        let assessment = verdict.assessment
        if let partner = assessment.partnerInView {
            latestPartnerInView = partner
        }
        if let asleep = assessment.partnerAsleep {
            latestPartnerAsleep = asleep
            if !asleep {
                quietAsleepLoggedNeedIDs.removeAll()
            }
        }
        notePartner(assessment, tool: verdict.tool, now: now)

        // An omitted need id can apply to the only open need. An unknown id
        // was dropped in sanitize and must not spill onto that need.
        let needOmitted: Bool = {
            guard let named = namedNeedID else { return true }
            return assessment.needID == nil && omittedNeedID(named)
        }()
        let subjectID: String?
        if namedNeedID != nil {
            subjectID = assessment.needID
        } else {
            subjectID = tracked.count == 1 ? tracked[0].needID : nil
        }
        // A folded placeholder ("null") on a no-transition turn reads as
        // omitted too: it can still speak for the single open need.
        var effectiveSubjectID = subjectID
        if verdict.tool == .reportNoTransition, effectiveSubjectID == nil, needOmitted, tracked.count == 1 {
            effectiveSubjectID = tracked[0].needID
        }
        if let effectiveSubjectID, catalog.need(id: effectiveSubjectID) != nil {
            applyAssessment(effectiveSubjectID, verdict: verdict, needOmitted: needOmitted, now: now)
        }
        if verdict.tool == .reportNoTransition, needOmitted {
            noteStillOpen(assessment: assessment, now: now)
        }

        if completedCall.purpose == .confirm {
            handleConfirmReply(call: completedCall, verdict: verdict, now: now)
            // A confirm verdict naming a different need is still a
            // hypothesis about that need; the focus path above ignores it.
            if let named = assessment.needID,
               let focus = completedCall.request.focusNeedID,
               named != focus {
                tryLatch(assessment, callKeyframes: completedCall.request.keyframes, now: now)
            }
        } else if verdict.tool == .latchNeedHypothesis {
            tryLatch(assessment, callKeyframes: completedCall.request.keyframes, now: now)
        }

        maybeCreditUnprompted(verdict: verdict, openAtVerdictStart: openAtVerdictStart, now: now)

        if let needID = assessment.needID, indexOfOpen(needID) != nil {
            applyDeferAndExtension(needID, verdict: verdict)
        }

        if let effectiveSubjectID, let index = indexOfOpen(effectiveSubjectID), tracked[index].awaitingRecheck {
            finishRecheck(at: index, assessment: assessment, needOmitted: needOmitted, now: now)
        }

        assert(
            debugMasteryMutations <= 1,
            "one verdict credited mastery \(debugMasteryMutations) times"
        )
        evaluate()
    }

    /// Credit for help he gives on his own, in two steps. An intervention
    /// with no open episode only arms the start; the credit lands when a
    /// verdict inside the window shows the need's full handled state.
    /// A need that had an open episode at verdict start never reaches
    /// here: the in-episode paths already credited or skipped it.
    private mutating func maybeCreditUnprompted(
        verdict: ModelVerdict,
        openAtVerdictStart: Set<String>,
        now: Date
    ) {
        guard verdict.tool == .logWearerIntervention || verdict.tool == .reportNeedResolved else {
            return
        }
        let assessment = verdict.assessment
        guard let needID = assessment.needID,
              let need = catalog.need(id: needID)
        else {
            return
        }
        if openAtVerdictStart.contains(needID) {
            // The episode was open when this verdict arrived. If it closed
            // during the verdict, the closing path already did the credit.
            if indexOfOpen(needID) == nil {
                record(.unpromptedSkipped, needID: needID, detail: "reason=same-verdict-close")
            }
            return
        }
        if verdict.tool == .logWearerIntervention {
            armUnprompted(needID: needID, actionCode: assessment.actionCode, now: now)
            return
        }
        completeUnprompted(need: need, assessment: assessment, now: now)
    }

    /// A started action is a marker, not a credit. Any named action arms;
    /// the completion verdict still has to show the handled state.
    private mutating func armUnprompted(needID: String, actionCode: String?, now: Date) {
        guard let actionCode, !actionCode.isEmpty else { return }
        unpromptedPending[needID] = UnpromptedStart(actionCode: actionCode, at: now)
        record(.unpromptedStarted, needID: needID, detail: nil)
    }

    /// The handled state, within the window of the start, completes the
    /// action: one mastery step, one Tonight entry, no cue. Anything else
    /// leaves the start armed (or clears it, for her close).
    private mutating func completeUnprompted(need: Need, assessment: SceneAssessment, now: Date) {
        let needID = need.id
        guard let start = unpromptedPending[needID] else { return }
        if assessment.resolution == .resolvedByPartner {
            unpromptedPending.removeValue(forKey: needID)
            record(.resolvedByOther, needID: needID, detail: "no-episode")
            return
        }
        guard now.timeIntervalSince(start.at) <= EngineTuning.unpromptedCompleteWindowSeconds else { return }
        guard let confidence = assessment.confidence,
              confidence >= EngineTuning.unpromptedMinConfidence
        else {
            return
        }
        let wearerCompletion = assessment.resolution == .caughtHimself
        let unclearCompletion = assessment.resolution != .resolvedByPartner
            && MasteryMath.matchesSelfNoticeSignal(start.actionCode, selfNoticeSignal: need.selfNoticeSignal)
            && assessment.partnerInView != true
        guard wearerCompletion || unclearCompletion else { return }
        // Completion counts only with every part handled. The start stays
        // armed; a later verdict can still complete it.
        if CompoundParts.isCompound(need),
           !CompoundParts.allHandled(need: need, tokens: assessment.partnerStateEvidence) {
            record(.stillOpen, needID: needID, detail: "partial")
            return
        }
        if let last = unpromptedCreditedAt[needID],
           now.timeIntervalSince(last) < EngineTuning.unpromptedDebounceSeconds {
            return
        }
        unpromptedPending.removeValue(forKey: needID)
        unpromptedCreditedAt[needID] = now
        debugMasteryMutations += 1
        var credited = need
        let before = credited.mastery
        credited.mastery = MasteryMath.applySelfNotice(credited.mastery)
        catalog.update(credited)
        record(.selfNoticedUnprompted, needID: needID, detail: nil)
        if before.phase != .retired && credited.mastery.phase == .retired {
            record(.masteryRetired, needID: needID, detail: nil)
        }
    }

    /// Starts whose window ran out without a completion. No credit, one line.
    private mutating func expireUnpromptedStarts(now: Date) {
        for (needID, start) in unpromptedPending {
            guard now.timeIntervalSince(start.at) > EngineTuning.unpromptedCompleteWindowSeconds else { continue }
            unpromptedPending.removeValue(forKey: needID)
            record(.unpromptedExpired, needID: needID, detail: "reason=not-completed")
        }
    }

    // MARK: - Time

    private mutating func evaluate() {
        let now = clock.now()
        buffer.expire(now: now)
        if sessionStopped || sessionIsOver(now) {
            if !didLogSessionEnd {
                didLogSessionEnd = true
                record(.sessionEnded, needID: nil, detail: nil)
            }
            retireStaleInFlight(now: now)
            for needID in Array(pendingConfirms.keys) {
                finishConfirm(needID: needID, outcome: .stopped)
            }
            pendingModelCalls.removeAll()
            return
        }
        closeNeedsWithNoPerson(now: now)
        closePostCueTimeouts(now: now)
        expireUnpromptedStarts(now: now)
        resolveDueNeeds(now: now)
        considerRepeats(now: now)
        scheduleModelCall(now: now)
    }

    private func sessionIsOver(_ now: Date) -> Bool {
        now.timeIntervalSince(sessionStartedAt) >= timing.maxSessionSeconds
    }

    private mutating func closeNeedsWithNoPerson(now: Date) {
        for need in tracked {
            if need.latchedWhileAbsent { continue }
            if sameChoreHolds(need, now: now) { continue }
            if latency.postCueNoPersonGrace,
               need.cueDelivered,
               let firedAt = need.cueFiredAt,
               timing.postCueNoPersonGraceSeconds > 0,
               now.timeIntervalSince(firedAt) < timing.postCueNoPersonGraceSeconds {
                continue
            }
            // Absence is measured per need from the later of the latch and the
            // last sighting, so a fresh latch never dies on a stale clock.
            let lastSeen = max(buffer.lastPersonSeenAt ?? .distantPast, need.latchedAt)
            guard now.timeIntervalSince(lastSeen) >= timing.noPersonKeyframeCloseSeconds else {
                continue
            }
            close(need.needID, now: now, cooldown: true)
            record(.closedUnknown, needID: need.needID, detail: "no-person")
        }
    }

    private mutating func closePostCueTimeouts(now: Date) {
        for need in tracked where need.cueDelivered {
            guard let firedAt = need.cueFiredAt else { continue }
            guard now.timeIntervalSince(firedAt) >= EngineTuning.postCueResolveSeconds else {
                continue
            }
            close(need.needID, now: now, cooldown: true)
            record(.closedUnknown, needID: need.needID, detail: "post-cue-timeout")
        }
    }

    private func sameChoreHolds(_ need: TrackedNeed, now: Date) -> Bool {
        guard let choreID = need.choreID, let choreMark, choreMark.id == choreID else {
            return false
        }
        return now.timeIntervalSince(choreMark.at) <= EngineTuning.sameChoreWindowSeconds
    }

    private mutating func resolveDueNeeds(now: Date) {
        let ordered = tracked.sorted { lhs, rhs in
            let left = catalog.priority(of: lhs.needID)
            let right = catalog.priority(of: rhs.needID)
            if left != right { return left < right }
            return lhs.latchedAt < rhs.latchedAt
        }
        for item in ordered {
            guard let index = indexOfOpen(item.needID) else { continue }
            considerCue(at: index, now: now)
        }
    }

    private mutating func considerCue(at index: Int, now: Date) {
        guard tracked[index].cueDelivered == false else { return }
        guard now >= tracked[index].cueDeadline else { return }
        let needID = tracked[index].needID
        guard let need = catalog.need(id: needID) else { return }

        if need.mastery.phase == .retired {
            recordRetiredMiss(needID, now: now)
            return
        }
        if tracked[index].inconclusiveHold { return }
        if tracked[index].awaitingRecheck { return }
        // One call saw his hands move. The next call has to say the need is
        // gone before we whisper over him.
        if tracked[index].pendingWearerAction != nil { return }
        // She is asleep: "ask her" needs stay quiet, chores still cue.
        // Logged once per need per sleep episode.
        if need.allowsCheckIn, latestPartnerAsleep == true {
            if !quietAsleepLoggedNeedIDs.contains(needID) {
                quietAsleepLoggedNeedIDs.insert(needID)
                record(.quietPartnerAsleep, needID: needID, detail: nil)
            }
            return
        }

        let skipRecheckForUrgent = latency.urgentNeedsEnabled && need.isUrgent
        if tracked[index].pendingCueKind == nil {
            let evidenceAge = now.timeIntervalSince(tracked[index].evidenceAt)
            if !skipRecheckForUrgent && evidenceAge > timing.staleEvidenceSeconds && !tracked[index].recheckUsed {
                beginRecheck(at: index, now: now)
                return
            }
            tracked[index].pendingCueKind = cueKind(for: need.mastery)
        }

        if tracked[index].handsBusy && now < tracked[index].hardCapAt {
            if !tracked[index].didLogBusyDefer {
                tracked[index].didLogBusyDefer = true
                record(.cueDeferredHandsBusy, needID: needID, detail: nil)
            }
            return
        }
        guard rateLimitAllows(now) else {
            if !tracked[index].didLogRateLimit {
                tracked[index].didLogRateLimit = true
                record(.cueDeferredRateLimit, needID: needID, detail: nil)
            }
            return
        }
        // She was in view on the last reply, and a check that includes this
        // need has not come back. Wait for it, briefly, so a whisper does
        // not land on something she is already handling. No new call.
        if holdCueForInFlightPartnerCheck(at: index, now: now) {
            if !tracked[index].didLogPartnerHold {
                tracked[index].didLogPartnerHold = true
                record(.cueDeferredPartnerCheck, needID: needID, detail: nil)
            }
            return
        }

        let kind = tracked[index].pendingCueKind ?? cueKind(for: need.mastery)
        deliverCue(kind, for: need, now: now)
    }

    /// True while the whisper should wait. The cap is measured from the cue
    /// deadline, so a hung call still speaks.
    private func holdCueForInFlightPartnerCheck(at index: Int, now: Date) -> Bool {
        guard latestPartnerInView == true else { return false }
        guard now.timeIntervalSince(tracked[index].cueDeadline) < EngineTuning.partnerInFlightCueHoldSeconds else {
            return false
        }
        let needID = tracked[index].needID
        return pendingModelCalls.contains { call in
            call.request.openNeeds.contains { $0.needID == needID }
        }
    }

    private func cueKind(for mastery: MasteryState) -> CueKind {
        mastery.phase == .quiet ? .chime : .whisper
    }

    private func rateLimitAllows(_ now: Date) -> Bool {
        guard let lastCueAt else { return true }
        return now.timeIntervalSince(lastCueAt) >= timing.cueRateLimitSeconds
    }

    private mutating func beginRecheck(at index: Int, now: Date) {
        retireStaleInFlight(now: now)
        let needID = tracked[index].needID
        recheckSameStripBypassAvailable = true
        if !pendingModelCalls.isEmpty {
            tracked[index].recheckUsed = true
            tracked[index].awaitingRecheck = true
            record(.recheckRequested, needID: needID, detail: "in-flight")
            return
        }
        // A paused upload or a spent call budget is not an answer. Try again
        // on a later tick instead of whispering blind.
        if !canIssueCall(now: now) { return }
        guard shouldIssue(purpose: .recheck, now: now) else {
            tracked[index].recheckUsed = true
            tracked[index].awaitingRecheck = true
            record(.recheckRequested, needID: needID, detail: "deferred")
            return
        }
        tracked[index].recheckUsed = true
        tracked[index].awaitingRecheck = true
        record(.recheckRequested, needID: needID, detail: nil)
        issue(.recheck, now: now)
    }

    private mutating func finishRecheck(
        at index: Int,
        assessment: SceneAssessment,
        needOmitted: Bool,
        now: Date
    ) {
        tracked[index].awaitingRecheck = false
        let needID = tracked[index].needID
        guard catalog.need(id: needID) != nil else { return }
        if assessment.sustainedAcrossStrip == true {
            tracked[index].evidenceAt = now
            tracked[index].recheckStrikes = 0
            return
        }
        if assessment.sustainedAcrossStrip == false, (!latency.strictCredit || !needOmitted) {
            if tracked[index].pendingWearerAction != nil {
                return
            }
            tracked[index].recheckStrikes += 1
            guard tracked[index].recheckStrikes >= 2 else {
                // One no-transition is a flaky frame, not an answer. Stay
                // awaiting: the scheduler re-issues the recheck call.
                tracked[index].awaitingRecheck = true
                record(.recheckRequested, needID: needID, detail: "confirming")
                return
            }
            // A recheck-clear is a "not sure", not a "gone". The full
            // relatch cooldown would silence a need the next verdicts
            // still see, so this close carries only a short grace.
            close(needID, now: now, cooldown: false)
            let grace = min(EngineTuning.recheckRelatchGraceSeconds, timing.relatchCooldownSeconds)
            closedAt[needID] = now.addingTimeInterval(grace - timing.relatchCooldownSeconds)
            record(.closedUnknown, needID: needID, detail: "recheck-cleared")
            return
        }
        if catalog.need(id: needID)?.allowsCheckIn == true {
            tracked[index].pendingCueKind = .checkIn
        } else {
            tracked[index].inconclusiveHold = true
        }
    }

    private mutating func deliverCue(_ kind: CueKind, for need: Need, now: Date) {
        cueSerial += 1
        let text: String
        switch kind {
        case .whisper, .checkIn:
            // The longer reason stays on the need. His ear gets the short action.
            text = SpokenCueForm.line(cueWording: need.cueWording, authorText: need.authorText)
        case .chime:
            text = ""
        }
        let cue = Cue(
            id: "cue-\(cueSerial)",
            needID: need.id,
            text: text,
            kind: kind,
            createdAt: now
        )
        let before = need.mastery
        var updated = need
        updated.mastery = MasteryMath.applyCueFired(need.mastery)
        catalog.update(updated)
        cueEffects[cue.id] = CueEffect(needID: need.id, masteryBefore: before, dismissed: false)
        playedCues.append(cue)
        lastCueAt = now
        // The need stays open: "he did it after the whisper" is still a
        // resolution worth recording. It closes on resolution, on the
        // no-person path, or when the post-cue window runs out.
        if let index = indexOfOpen(need.id) {
            tracked[index].cueDelivered = true
            tracked[index].cueFiredAt = now
            tracked[index].cueID = cue.id
            // Score from before applyCueFired. A cue multiplies mastery, and
            // the streak resets, so the post-cue numbers cannot say "still new".
            let allowRepeat = repeatsEnabled
                && (kind == .whisper || kind == .checkIn)
                && !text.isEmpty
                && need.mastery.score < CueSpeechTuning.repeatMasteryCutoff
            tracked[index].repeatAllowed = allowRepeat
            tracked[index].repeatDelivered = false
            tracked[index].repeatDueAt = allowRepeat
                ? now.addingTimeInterval(CueSpeechTuning.repeatDelaySeconds)
                : nil
            recordedCueTimings.append(
                CueTimingSnapshot(
                    cueID: cue.id,
                    needID: need.id,
                    visibleAt: tracked[index].visibleAt,
                    latchedAt: tracked[index].latchedAt,
                    cueFiredAt: now
                )
            )
        }
        record(.cueFired, needID: need.id, detail: kind.rawValue)
    }

    /// One slower "Again," if the delay has passed and the same gates that
    /// would hold a whisper still say it is his to hear. A jumped clock that
    /// lands past the window does not speak late.
    private mutating func considerRepeats(now: Date) {
        guard repeatsEnabled else { return }
        for index in tracked.indices {
            guard tracked[index].repeatAllowed, !tracked[index].repeatDelivered else { continue }
            guard let due = tracked[index].repeatDueAt else { continue }
            guard now >= due else { continue }
            if now >= due.addingTimeInterval(CueSpeechTuning.repeatWindowSeconds) {
                tracked[index].repeatDelivered = true
                continue
            }
            let needID = tracked[index].needID
            guard catalog.need(id: needID) != nil else {
                tracked[index].repeatDelivered = true
                continue
            }
            if wearerIntervenedSinceCue(at: index) {
                tracked[index].repeatDelivered = true
                continue
            }
            // Same hands-busy hold as the original whisper: wait inside the
            // window, and do not speak once the window has passed.
            if tracked[index].handsBusy && now < tracked[index].hardCapAt {
                continue
            }
            if holdRepeatForPartner(at: index) {
                continue
            }
            guard let need = catalog.need(id: needID) else { continue }
            deliverRepeat(for: need, at: index, now: now)
        }
    }

    private func wearerIntervenedSinceCue(at index: Int) -> Bool {
        if tracked[index].pendingWearerAction != nil {
            return true
        }
        guard let acted = tracked[index].lastMatchingInterventionAt,
              let fired = tracked[index].cueFiredAt
        else { return false }
        return acted >= fired
    }

    /// Partner in view and a check for this need still in flight. Unlike the
    /// pre-cue hold, this is not capped from the cue deadline: the repeat
    /// window is already short, and a hung call simply misses the window.
    private func holdRepeatForPartner(at index: Int) -> Bool {
        guard latestPartnerInView == true else { return false }
        let needID = tracked[index].needID
        return pendingModelCalls.contains { call in
            call.request.openNeeds.contains { $0.needID == needID }
        }
    }

    private mutating func deliverRepeat(for need: Need, at index: Int, now: Date) {
        tracked[index].repeatDelivered = true
        cueSerial += 1
        let base = playedCues.last { $0.needID == need.id && !$0.isRepeat }?.text
            ?? SpokenCueForm.line(cueWording: need.cueWording, authorText: need.authorText)
        let cue = Cue(
            id: "cue-\(cueSerial)",
            needID: need.id,
            text: SpokenCueForm.repeatLine(base),
            kind: tracked[index].pendingCueKind == .checkIn ? .checkIn : .whisper,
            createdAt: now,
            isRepeat: true
        )
        playedCues.append(cue)
        record(.cueFired, needID: need.id, detail: CueSpeechTuning.repeatEventDetail)
    }

    private mutating func recordRetiredMiss(_ needID: String, now: Date) {
        guard var need = catalog.need(id: needID) else { return }
        need.mastery.consecutiveMisses += 1
        var unretired = false
        if need.mastery.consecutiveMisses >= CueFadeSpec.unretireMissStreak {
            // Phase ignores the miss counter. Clearing the score and the
            // self-notice streak is what puts the need back in coaching.
            need.mastery = .initial
            unretired = true
        }
        catalog.update(need)
        close(needID, now: now, cooldown: true)
        record(.retiredMiss, needID: needID, detail: nil)
        if unretired {
            record(.masteryUnretired, needID: needID, detail: nil)
        }
    }

    // MARK: - Model calls

    /// Three dark frames in a row log once and hold calls until a
    /// readable frame clears the streak. Unknown sharpness fails open.
    private mutating func trackDarkness(sharpness: Double?) {
        guard let sharpness else {
            darkStreak = 0
            darkStreakLogged = false
            return
        }
        if sharpness < EngineTuning.darkSharpness {
            darkStreak += 1
            if darkStreak >= EngineTuning.darkStreakFrames, !darkStreakLogged {
                darkStreakLogged = true
                record(.frameDark, needID: nil, detail: nil)
            }
        } else {
            darkStreak = 0
            darkStreakLogged = false
        }
    }

    private var darkActive: Bool {
        darkStreak >= EngineTuning.darkStreakFrames
    }

    private mutating func scheduleModelCall(now: Date) {
        retireStaleInFlight(now: now)
        // Sightings expire on their own clock: darkness, a full flight
        // deck, or a spent budget never holds one open past 8 s.
        for needID in Array(pendingConfirms.keys) {
            if let pending = pendingConfirms[needID],
               now >= pending.hypothesisAt.addingTimeInterval(EngineTuning.confirmMaxElapsedSeconds) {
                finishConfirm(needID: needID, outcome: .expired)
            }
        }
        // Dark: the lens is covered or the lights are out. No call could
        // see anything, so none goes out until it clears. No skip is
        // logged; the single dark line already says why.
        guard !darkActive else { return }
        let maxInFlight = latency.concurrentInFlight ? latency.maxInFlight : 1
        guard pendingModelCalls.count < maxInFlight else { return }
        if !pendingModelCalls.isEmpty {
            guard let newestSlot = buffer.newestSlotStartedAt(now: now),
                  let lastIssuedSlot = newestSlotAtLastIssuedCall,
                  newestSlot > lastIssuedSlot
            else {
                return
            }
        }
        guard canIssueCall(now: now) else {
            if !visitorUploadPaused && !sessionIsOver(now) && callsIssued >= SessionLimits.maxModelCallsPerSession && !didLogBudget {
                didLogBudget = true
                record(.callBudgetExhausted, needID: nil, detail: nil)
            }
            return
        }

        // A due confirm jumps the queue: it bypasses the idle-bucket and
        // min-gap skips (but still spends budget) so the second look lands
        // while the sighting is fresh.
        if let due = pendingConfirms.min(by: { $0.value.dueAt < $1.value.dueAt }),
           now >= due.value.dueAt {
            issueConfirm(needID: due.key, now: now)
            return
        }

        if tracked.contains(where: \.awaitingRecheck) {
            if shouldIssue(purpose: .recheck, now: now) {
                issue(.recheck, now: now)
            }
            return
        }

        if !tracked.isEmpty {
            let heartbeatDue = (lastHeartbeatAt ?? lastModelCallAt).map {
                now.timeIntervalSince($0) >= timing.heartbeatSeconds
            } ?? true
            let edgeTrigger = handEdgePending && pendingModelCalls.isEmpty
            if heartbeatDue || edgeTrigger {
                if shouldIssue(purpose: .heartbeat, now: now) {
                    issue(.heartbeat, now: now)
                }
                return
            }
        }

        guard tracked.count < SessionLimits.maxOpenNeeds else { return }
        guard catalog.needs.contains(where: { indexOfOpen($0.id) == nil }) else { return }
        guard buffer.revision > revisionAtLastLatchCall else { return }
        let recentPerson = buffer.lastPersonSeenAt.map {
            now.timeIntervalSince($0) < timing.noPersonKeyframeCloseSeconds
        } ?? false
        if !tracked.isEmpty, latency.dedupeAllPurposes, !recentPerson {
            return
        }
        var spendIdleToken = false
        if latency.sceneChangeLatchBypass {
            let admission = admitIdleLatch(now: now)
            guard admission != .denied else { return }
            spendIdleToken = admission == .admittedSpendingToken
        } else {
            let idleMinInterval: TimeInterval = {
                if latency.dedupeAllPurposes,
                   tracked.isEmpty,
                   lastLatchCallAt != nil,
                   !recentPerson,
                   !handEdgePending,
                   now.timeIntervalSince(sessionStartedAt) >= latency.sessionWarmupSeconds {
                    return max(timing.latchMinIntervalSeconds, SessionLimits.latchMinIntervalSeconds)
                }
                return timing.latchMinIntervalSeconds
            }()
            if let lastLatchCallAt,
               now.timeIntervalSince(lastLatchCallAt) < idleMinInterval {
                return
            }
        }
        if let lastSuccessfulLatchAt,
           now.timeIntervalSince(lastSuccessfulLatchAt) < timing.latchMinIntervalSeconds {
            return
        }
        if !tracked.isEmpty,
           let lastModelCallAt,
           now.timeIntervalSince(lastModelCallAt) < timing.latchMinIntervalSeconds {
            return
        }
        let strip = buffer.modelStrip(now: now, purpose: .latch, confirm: latchConfirmPending, latency: latency)
        let hasUrgentCandidate = latency.urgentNeedsEnabled && catalog.needs.contains {
            $0.isUrgent && indexOfOpen($0.id) == nil
        }
        let minKeyframes = hasUrgentCandidate ? 1 : timing.latchMinKeyframes
        guard strip.count >= minKeyframes else { return }
        guard shouldIssue(purpose: .latch, now: now) else { return }
        if spendIdleToken {
            idleBucketTokens = max(0, idleBucketTokens - 1)
        }
        issue(.latch, now: now)
    }

    /// Idle-gate decision. The token is spent at issue time, not here: the
    /// strip and dedupe checks below can still refuse after admission.
    private enum IdleLatchAdmission {
        case denied
        case admitted
        case admittedSpendingToken
    }

    /// Unified call gate across latch, heartbeat, and recheck.
    private mutating func shouldIssue(purpose: ModelCallPurpose, now: Date) -> Bool {
        let currentIdentity = buffer.stripIdentity(now: now, latency: latency)
        if !latency.dedupeAllPurposes {
            if purpose == .heartbeat {
                return currentIdentity != stripSignatureAtLastCall
            }
            return true
        }

        if let lastSignature = stripSignatureAtLastCall, currentIdentity == lastSignature {
            if purpose == .recheck && recheckSameStripBypassAvailable {
                recheckSameStripBypassAvailable = false
            } else {
                recordSkip("duplicate-strip purpose=\(purpose.rawValue)")
                return false
            }
        }

        let minGap = timing.minCallGapSeconds
        if minGap > 0,
           let lastModelCallAt,
           now.timeIntervalSince(lastModelCallAt) < minGap {
            recordSkip("min-gap purpose=\(purpose.rawValue)")
            return false
        }

        lastLoggedSkip = nil
        return true
    }

    private mutating func recordSkip(_ detail: String) {
        guard lastLoggedSkip != detail else { return }
        lastLoggedSkip = detail
        record(.skip, needID: nil, detail: detail)
    }

    /// Idle-latch admission. With nothing open, every call spends a token
    /// from the same bucket, including after a person sighting or a hand
    /// edge. Those used to skip the bucket and latch every quick interval.
    /// A rising scene change may spend a token early (quick interval, under
    /// the 10 s cadence). Sustained motion does not re-arm that edge.
    /// Suppression logs `idle-bucket`.
    private mutating func admitIdleLatch(now: Date) -> IdleLatchAdmission {
        let quick = timing.latchMinIntervalSeconds
        let idle = tracked.isEmpty
        let warmedUp = now.timeIntervalSince(sessionStartedAt) >= latency.sessionWarmupSeconds
        if latency.dedupeAllPurposes, idle, warmedUp {
            refillIdleBucket(now: now)
            guard idleBucketTokens >= 1 else {
                recordSkip("idle-bucket")
                return .denied
            }
            guard let last = lastLatchCallAt else {
                return .admittedSpendingToken
            }
            let elapsed = now.timeIntervalSince(last)
            let quiet = max(quick, SessionLimits.latchMinIntervalSeconds)
            if sceneChangedSinceLatchCall, elapsed >= quick, elapsed < quiet {
                return .admittedSpendingToken
            }
            if elapsed < quiet {
                recordSkip("idle-bucket")
                return .denied
            }
            return .admittedSpendingToken
        }
        if let last = lastLatchCallAt, now.timeIntervalSince(last) < quick {
            return .denied
        }
        return .admitted
    }

    /// Refill 1 token per 10 s up to the capacity of 2.
    private mutating func refillIdleBucket(now: Date) {
        if let updatedAt = idleBucketUpdatedAt {
            idleBucketTokens = min(2, idleBucketTokens + now.timeIntervalSince(updatedAt) / 10)
        }
        idleBucketUpdatedAt = now
    }

    private func canIssueCall(now: Date) -> Bool {
        if visitorUploadPaused || sessionIsOver(now) { return false }
        return callsIssued < SessionLimits.maxModelCallsPerSession
    }

    /// The confirm strip is the stored source frames plus one new frame:
    /// admitted, captured after the hypothesis call returned, never sent
    /// for this sighting. Sharpness orders the candidates; a soft frame
    /// still goes when it is the only new one. Every age is recomputed
    /// against the strip's own newest frame. With no new frame the
    /// sighting stays pending: a later tick sends it, or the 8 s cap ends
    /// it. One attempt in flight at a time.
    private mutating func issueConfirm(needID: String, now: Date) {
        guard var pending = pendingConfirms[needID] else { return }
        let inFlight = pendingModelCalls.contains {
            $0.purpose == .confirm && $0.request.focusNeedID == needID
        }
        guard !inFlight else { return }
        guard pending.attemptsIssued < EngineTuning.confirmMaxAttempts else {
            finishConfirm(needID: needID, outcome: .exhausted)
            return
        }
        let sourceIDs = Set(pending.sourceFrames.map(\.id))
        let candidates = buffer.keyframes(now: now)
            .filter { $0.capturedAt > pending.hypothesisAt }
            .filter { !sourceIDs.contains($0.id) && !pending.usedNewFrameIDs.contains($0.id) }
            .sorted {
                let left = $0.sharpness ?? -1
                let right = $1.sharpness ?? -1
                if left != right { return left > right }
                return $0.capturedAt > $1.capturedAt
            }
        guard let fresh = candidates.first else { return }
        pending.usedNewFrameIDs.insert(fresh.id)
        pending.attemptsIssued += 1
        pendingConfirms[needID] = pending
        var strip = pending.sourceFrames
        strip.append(fresh)
        if let newestAt = strip.map(\.capturedAt).max() {
            for index in strip.indices {
                strip[index].ageSeconds = max(0, newestAt.timeIntervalSince(strip[index].capturedAt))
            }
        }
        issue(.confirm, now: now, focusNeedID: needID, keyframes: strip)
    }

    private mutating func issue(
        _ purpose: ModelCallPurpose,
        now: Date,
        focusNeedID: String? = nil,
        keyframes: [Keyframe]? = nil
    ) {
        callSerial += 1
        callsIssued += 1
        callIssuedTimestamps.append(now)
        callIssuedTimestamps.removeAll { now.timeIntervalSince($0) >= 60 }
        let id = "call-\(callSerial)"
        lastModelCallAt = now
        if purpose == .latch {
            lastLatchCallAt = now
            revisionAtLastLatchCall = buffer.revision
            if !tracked.isEmpty {
                lastHeartbeatAt = now
            }
            handEdgePending = false
            sceneChangedSinceLatchCall = false
        }
        if purpose == .heartbeat || purpose == .recheck {
            lastHeartbeatAt = now
            handEdgePending = false
        }
        let confirm = purpose == .latch && latchConfirmPending
        let strip = keyframes ?? buffer.modelStrip(now: now, purpose: purpose, confirm: confirm, latency: latency)
        stripSignatureAtLastCall = buffer.stripIdentity(now: now, latency: latency)
        newestSlotAtLastIssuedCall = buffer.newestSlotStartedAt(now: now)
        lastLoggedSkip = nil
        let open = tracked.map { item -> OpenNeedContext in
            let need = catalog.need(id: item.needID)
            let problem = need?.visualCondition ?? need?.authorText ?? ""
            return OpenNeedContext(
                needID: item.needID,
                latchedSecondsAgo: now.timeIntervalSince(item.latchedAt),
                cueSpoken: item.cueDelivered,
                problemCondition: problem,
                resolutionSignal: Self.resolutionSignal(for: need, latency: latency),
                wearerActedSecondsAgo: latency.creditRecentIntervention
                    ? item.lastMatchingInterventionAt.map { now.timeIntervalSince($0) } : nil
            )
        }
        pendingModelCalls.append(
            PendingModelCall(
                id: id,
                purpose: purpose,
                request: ModelRequest(
                    keyframes: strip,
                    needs: catalog.needs,
                    openNeeds: open,
                    purpose: purpose,
                    focusNeedID: focusNeedID,
                    unpromptedStartedIDs: unpromptedPending.keys.sorted()
                ),
                issuedAt: now
            )
        )
        record(.callIssued, needID: nil, detail: "\(purpose.rawValue) kf=\(strip.count)")
    }

    /// What counts as handled, from `handledCondition` and `selfNoticeSignal` only
    /// (never `visualCondition`). Emits the fallback instruction when both are missing.
    public static func resolutionSignal(for need: Need?, latency: LatencyTuning = .default) -> String {
        if !latency.polarityResolution {
            let legacy = [need?.selfNoticeSignal, need?.visualCondition]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return legacy.joined(separator: "; ")
        }
        let parts = [need?.handledCondition, need?.selfNoticeSignal]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty {
            return unspecifiedResolutionSignal
        }
        return parts.joined(separator: "; ")
    }

    /// The transport gave up on an in-flight call. The next tick may start another.
    /// A reply that arrives later for this id is dropped.
    public mutating func abandonInFlightCall(id: String? = nil) {
        if let id {
            if let index = pendingModelCalls.firstIndex(where: { $0.id == id }) {
                let removed = pendingModelCalls.remove(at: index)
                staleCallIDs.insert(removed.id)
            }
            return
        }
        guard !pendingModelCalls.isEmpty else { return }
        let removed = pendingModelCalls.removeFirst()
        staleCallIDs.insert(removed.id)
    }

    private mutating func retireStaleInFlight(now: Date) {
        var remaining: [PendingModelCall] = []
        for call in pendingModelCalls {
            if now.timeIntervalSince(call.issuedAt) >= EngineTuning.inFlightStaleSeconds {
                staleCallIDs.insert(call.id)
            } else {
                remaining.append(call)
            }
        }
        pendingModelCalls = remaining
    }

    // MARK: - Verdicts

    /// Placeholder need ids the model writes instead of omitting the field.
    /// Strict schemas force need_id present on every call, so no-transition
    /// turns arrive as "none", "no_need", or the literal "null"/"nil".
    private func omittedNeedID(_ raw: String) -> Bool {
        let folded = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded.isEmpty
            || folded == "none"
            || folded == "no_need"
            || folded == "null"
            || folded == "nil"
    }

    private mutating func sanitize(_ assessment: SceneAssessment) -> SceneAssessment {
        var assessment = assessment
        if let needID = assessment.needID, catalog.need(id: needID) == nil {
            // Placeholders read as omitted; truly unknown ids still drop below.
            assessment.needID = nil
            if !omittedNeedID(needID) {
                record(.assessmentDropped, needID: needID, detail: "unknown-need")
            }
        }
        if let resolution = assessment.resolution {
            if omittedNeedID(resolution.rawValue) {
                assessment.resolution = nil
            } else if !Resolution.recognized.contains(resolution) {
                assessment.resolution = nil
                record(.assessmentDropped, needID: assessment.needID, detail: "unknown-resolution")
            }
        }
        if let actionCode = assessment.actionCode, omittedNeedID(actionCode) {
            assessment.actionCode = nil
        }
        if let anchor = assessment.newestAnchorState, !AnchorState.recognized.contains(anchor) {
            assessment.newestAnchorState = nil
            record(.assessmentDropped, needID: assessment.needID, detail: "unknown-anchor-state")
        }
        if let cited = assessment.evidenceKeyframeIDs {
            // Decoding already dropped ids outside the request strip. Blanks
            // can still arrive on direct-built verdicts; they cite nothing.
            assessment.evidenceKeyframeIDs = cited
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return assessment
    }

    /// A no-transition turn with no need id holds the open need. An out-of-view
    /// turn (`sustained == nil`) refreshes evidence and logs `out-of-view`.
    private mutating func noteStillOpen(assessment: SceneAssessment, now: Date) {
        guard tracked.count == 1, let needID = tracked.first?.needID else {
            if tracked.count >= 2 {
                record(.stillOpen, needID: nil, detail: "ambiguous")
            }
            return
        }
        guard let index = indexOfOpen(needID),
              let need = catalog.need(id: needID) else {
            return
        }
        if latency.strictCredit && assessment.sustainedAcrossStrip == nil {
            tracked[index].evidenceAt = now
            record(.stillOpen, needID: needID, detail: "out-of-view")
            return
        }
        if assessment.sustainedAcrossStrip != false
            || passiveActionMatches(assessment.actionCode, need: need) {
            tracked[index].evidenceAt = now
        }
        record(.stillOpen, needID: needID, detail: "no-change")
    }

    /// A passive scene detail ("water_bottle_present") counts when it shares
    /// a word with what the need watches for. Short tokens don't count, so a
    /// stray "on" can't match. Wearer actions belong to the pending path.
    private func passiveActionMatches(_ actionCode: String?, need: Need) -> Bool {
        guard let code = actionCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !code.isEmpty else {
            return false
        }
        if MasteryMath.isWearerAction(actionCode, selfNoticeSignal: need.selfNoticeSignal) {
            return false
        }
        let codeTokens = Set(wordTokens(code))
        guard !codeTokens.isEmpty else { return false }
        for field in [need.visualCondition, need.handledCondition, need.selfNoticeSignal] {
            guard let field else { continue }
            if !codeTokens.isDisjoint(with: Set(wordTokens(field.lowercased()))) {
                return true
            }
        }
        return false
    }

    private func wordTokens(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
    }

    /// The one place a wearer credit lands. Help after a cue earns zero
    /// self-notice increment (the cue already penalized); only help
    /// before any cue steps mastery up. Either way the episode closes
    /// with a `caughtHimself`, so the phone can match it to its cue.
    private mutating func creditWearer(at index: Int, detail: String?, now: Date) {
        let needID = tracked[index].needID
        guard var need = catalog.need(id: needID) else { return }
        if tracked[index].cueDelivered {
            noteResolution(needID: needID, index: index, shared: detail == "shared-finish", now: now)
            close(needID, now: now, cooldown: true)
            let afterCueDetail = (detail == "shared-finish" || detail == "recent-intervention") ? detail : "after-cue"
            record(.caughtHimself, needID: needID, detail: afterCueDetail)
            return
        }
        debugMasteryMutations += 1
        let before = need.mastery
        need.mastery = MasteryMath.applySelfNotice(need.mastery)
        catalog.update(need)
        noteResolution(needID: needID, index: index, shared: detail == "shared-finish", now: now)
        close(needID, now: now, cooldown: true)
        record(.caughtHimself, needID: needID, detail: detail)
        if before.phase != .retired && need.mastery.phase == .retired {
            record(.masteryRetired, needID: needID, detail: nil)
        }
    }

    /// One verdict settles the open need. `report_need_resolved` carries who
    /// handled it; anything else only confirms the need is still open.
    private mutating func resolve(_ needID: String, verdict: ModelVerdict, now: Date) {
        guard let need = catalog.need(id: needID) else { return }
        guard let index = indexOfOpen(needID) else { return }
        let assessment = verdict.assessment
        // A compound need resolves only with every part handled. One part
        // fixed is still open, not complete, whoever fixed it.
        if CompoundParts.isCompound(need),
           !CompoundParts.allHandled(need: need, tokens: assessment.partnerStateEvidence) {
            record(.stillOpen, needID: needID, detail: "partial")
            return
        }
        // A resolved verdict that still sees her keeps the handoff on record
        // even when she closes it.
        if assessment.resolution == .resolvedByPartner, assessment.partnerInView == true {
            tracked[index].partnerEngagedAt = now
        }
        let pendingAction = tracked[index].pendingWearerAction
        let cleared = assessment.sustainedAcrossStrip != true
        // One eligibility check for both the credit and the still-visible log.
        // Callers apply visibility: credit needs the problem gone, the log needs it still there.
        let eligibility = wearerCreditEligibility(
            at: index,
            assessment: assessment,
            tool: verdict.tool,
            pendingAction: pendingAction,
            need: need,
            now: now
        )
        let recentCreditDetail = (eligibility.recentIntervention && cleared)
            ? recentInterventionLabel(at: index)
            : nil
        if assessment.resolution == .resolvedByPartner, recentCreditDetail == nil {
            noteResolution(needID: needID, index: index, shared: false, now: now)
            close(needID, now: now, cooldown: true)
            record(.resolvedByOther, needID: needID, detail: verdict.tool.rawValue)
            return
        }
        let wearerResolved: Bool
        if latency.strictCredit {
            wearerResolved = assessment.resolution == .caughtHimself
                || (eligibility.strictPendingOrSignal && cleared)
        } else {
            wearerResolved = assessment.resolution == .caughtHimself
                || (pendingAction != nil && cleared)
                || (MasteryMath.matchesSelfNoticeSignal(assessment.actionCode, selfNoticeSignal: need.selfNoticeSignal) && cleared)
                || (assessment.sustainedAcrossStrip == false && assessment.wearerHandsVisible == true && assessment.partnerInView == false)
                || (tracked[index].cueDelivered && assessment.sustainedAcrossStrip == false)
        }
        if wearerResolved || recentCreditDetail != nil {
            let detail = recentCreditDetail ?? (assessment.resolution == .caughtHimself ? "before-cue" : (pendingAction ?? "before-cue"))
            creditWearer(at: index, detail: detail, now: now)
            return
        }
        if blockedByVisibleProblem(eligibility, assessment: assessment, tool: verdict.tool) {
            record(.stillOpen, needID: needID, detail: "resolved-but-still-visible")
        } else {
            record(.stillOpen, needID: needID, detail: "unclear")
        }
    }

    /// Wearer-credit paths shared by the credit decision and the
    /// "resolved-but-still-visible" log. Visibility is not part of this:
    /// `caughtHimself` is also separate and credits on its own.
    private struct WearerCreditEligibility {
        /// Recent-intervention memory matches, ignoring whether the problem is still visible.
        var recentIntervention: Bool
        /// Strict pending-action or self-notice signal, ignoring visibility.
        var strictPendingOrSignal: Bool
    }

    private func wearerCreditEligibility(
        at index: Int,
        assessment: SceneAssessment,
        tool: ToolName,
        pendingAction: String?,
        need: Need,
        now: Date
    ) -> WearerCreditEligibility {
        WearerCreditEligibility(
            recentIntervention: recentInterventionApplies(at: index, assessment: assessment, tool: tool, now: now),
            strictPendingOrSignal: latency.strictCredit
                && strictPendingOrSignalApplies(assessment: assessment, pendingAction: pendingAction, need: need)
        )
    }

    /// Recent-intervention memory: a matching intervention inside the window
    /// when no partner is in view. Shared vs solo is `recentInterventionLabel`.
    /// Only `report_need_resolved` qualifies; `report_no_transition` never does.
    /// Partner, unknown, and omitted resolutions all qualify; the caller drops
    /// a still-visible partner resolution so she can close it herself.
    private func recentInterventionApplies(at index: Int, assessment: SceneAssessment, tool: ToolName, now: Date) -> Bool {
        guard latency.creditRecentIntervention,
            tool == .reportNeedResolved,
            assessment.resolution == .resolvedByPartner || assessment.resolution == .unknown || assessment.resolution == nil,
            assessment.partnerInView != true,
            let actedAt = tracked[index].lastMatchingInterventionAt,
            now.timeIntervalSince(actedAt) <= latency.recentInterventionWindowSeconds
        else { return false }
        return true
    }

    /// Strict path: a pending wearer action, or a self-notice signal, and not her close.
    private func strictPendingOrSignalApplies(assessment: SceneAssessment, pendingAction: String?, need: Need) -> Bool {
        assessment.resolution != .resolvedByPartner
            && (pendingAction != nil
                || MasteryMath.matchesSelfNoticeSignal(assessment.actionCode, selfNoticeSignal: need.selfNoticeSignal))
    }

    /// Solo when she was never engaged, shared when she started and he finished.
    private func recentInterventionLabel(at index: Int) -> String {
        tracked[index].partnerEngagedAt == nil ? "recent-intervention" : "shared-finish"
    }

    /// Same eligibility as the credit paths, but the problem is still visible,
    /// so the need stays open. A partner resolution is her close, not this log.
    private func blockedByVisibleProblem(
        _ eligibility: WearerCreditEligibility,
        assessment: SceneAssessment,
        tool: ToolName
    ) -> Bool {
        guard tool == .reportNeedResolved,
            assessment.sustainedAcrossStrip == true,
            assessment.resolution != .resolvedByPartner
        else { return false }
        return eligibility.recentIntervention || eligibility.strictPendingOrSignal
    }

    private mutating func noteResolution(needID: String, index: Int, shared: Bool, now: Date) {
        let item = tracked[index]
        lastResolution = ResolutionOutcome(
            needID: needID,
            sharedWithPartner: shared,
            partnerSeenSecondsAgo: item.partnerEngagedAt.map { now.timeIntervalSince($0) },
            wearerActedSecondsAgo: item.lastMatchingInterventionAt.map { now.timeIntervalSince($0) },
            at: now
        )
    }

    private mutating func applyAssessment(
        _ needID: String,
        verdict: ModelVerdict,
        needOmitted: Bool,
        now: Date
    ) {
        let assessment = verdict.assessment
        guard let need = catalog.need(id: needID) else { return }

        if verdict.tool == .reportNeedResolved {
            resolve(needID, verdict: verdict, now: now)
            return
        }

        if !latency.strictCredit && assessment.resolution == .resolvedByPartner {
            guard indexOfOpen(needID) != nil else { return }
            if CompoundParts.isCompound(need),
               !CompoundParts.allHandled(need: need, tokens: assessment.partnerStateEvidence) {
                record(.stillOpen, needID: needID, detail: "partial")
                return
            }
            close(needID, now: now, cooldown: true)
            record(.resolvedByOther, needID: needID, detail: verdict.tool.rawValue)
            return
        }

        guard let index = indexOfOpen(needID) else { return }

        // Any reply naming an open need that still sees her engaged keeps the
        // handoff on record. Never cleared while the need is open.
        if assessment.partnerInView == true, assessment.sustainedAcrossStrip != false {
            tracked[index].partnerEngagedAt = now
        }
        if assessment.sustainedAcrossStrip == true {
            tracked[index].evidenceAt = now
            tracked[index].inconclusiveHold = false
        }
        if let occupied = assessment.wearerHandsOccupied {
            tracked[index].handsBusy = occupied
            if !occupied {
                tracked[index].didLogBusyDefer = false
            }
        }

        let hadPending = tracked[index].pendingWearerAction != nil
        let pendingAction = tracked[index].pendingWearerAction

        if latency.strictCredit {
            // Clearing a pending action via `sustained=false` counts only when
            // the verdict names the need explicitly and its tool is
            // `report_need_resolved` (handled above) or `log_wearer_intervention`.
            let clearedByIntervention = !needOmitted
                && verdict.tool == .logWearerIntervention
                && assessment.sustainedAcrossStrip == false

            if hadPending && clearedByIntervention {
                creditWearer(at: index, detail: pendingAction, now: now)
                return
            }

            if hadPending {
                tracked[index].pendingWearerAction = nil
            }

            if verdict.tool == .reportNoTransition && !needOmitted {
                if assessment.sustainedAcrossStrip == nil {
                    tracked[index].evidenceAt = now
                    record(.stillOpen, needID: needID, detail: "out-of-view")
                } else {
                    record(.stillOpen, needID: needID, detail: "no-change")
                }
            }

            // Only `log_wearer_intervention` may arm `pendingWearerAction`, and
            // only when `actionCode` equals `need.selfNoticeSignal`.
            if verdict.tool == .logWearerIntervention {
                if MasteryMath.matchesSelfNoticeSignal(assessment.actionCode, selfNoticeSignal: need.selfNoticeSignal) {
                    tracked[index].pendingWearerAction = assessment.actionCode
                    tracked[index].lastMatchingInterventionAt = now
                } else if MasteryMath.hasWearerPrefix(assessment.actionCode) {
                    record(.actionRejected, needID: needID, detail: "unrelated-wearer-action")
                } else {
                    record(.actionRejected, needID: needID, detail: assessment.actionCode ?? "missing")
                }
                return
            }

            if assessment.resolution == .caughtHimself {
                record(.actionRejected, needID: needID, detail: "unconfirmed")
            }
            return
        }

        // Legacy (`strictCredit == false`) path.
        let cleared = assessment.sustainedAcrossStrip == false
            || (assessment.resolution == .caughtHimself && assessment.sustainedAcrossStrip != true)
        let wearerAction = MasteryMath.isWearerAction(assessment.actionCode, selfNoticeSignal: need.selfNoticeSignal)

        if hadPending && cleared {
            creditWearer(at: index, detail: pendingAction, now: now)
            return
        }

        if hadPending {
            tracked[index].pendingWearerAction = nil
        }

        if verdict.tool == .logWearerIntervention && !wearerAction {
            record(.actionRejected, needID: needID, detail: assessment.actionCode ?? "missing")
            return
        }

        if wearerAction {
            tracked[index].pendingWearerAction = assessment.actionCode
            if MasteryMath.matchesSelfNoticeSignal(assessment.actionCode, selfNoticeSignal: need.selfNoticeSignal) {
                tracked[index].lastMatchingInterventionAt = now
            }
        } else if assessment.resolution == .caughtHimself {
            record(.actionRejected, needID: needID, detail: "unconfirmed")
        }
    }

    private mutating func tryLatch(
        _ assessment: SceneAssessment,
        callKeyframes: [Keyframe],
        now: Date
    ) {
        guard let needID = assessment.needID else { return }
        guard let need = catalog.need(id: needID) else { return }
        if visitorUploadPaused {
            record(.latchRejected, needID: needID, detail: "visitor-paused")
            return
        }
        if sessionIsOver(now) {
            record(.latchRejected, needID: needID, detail: "session-ended")
            return
        }
        let isUrgent = latency.urgentNeedsEnabled && need.isUrgent
        var urgentEvidence: (frame: Keyframe, confidence: Double)?
        if assessment.sustainedAcrossStrip != true {
            if isUrgent {
                // Urgent skips the wait, not the evidence: one fresh cited
                // frame or the confirm path. No repeat bypass.
                guard let fresh = UrgentEvidence.freshFrame(
                    assessment: assessment,
                    callKeyframes: callKeyframes,
                    now: now
                ) else {
                    recentHypothesisAt[needID] = now
                    latchConfirmPending = true
                    record(.latchRejected, needID: needID, detail: "urgent-no-fresh-evidence")
                    scheduleConfirm(
                        needID: needID,
                        confidence: assessment.confidence,
                        callKeyframes: callKeyframes,
                        assessment: assessment,
                        now: now
                    )
                    return
                }
                recentHypothesisAt[needID] = now
                urgentEvidence = fresh
            } else if let last = recentHypothesisAt[needID],
                      now.timeIntervalSince(last) < EngineTuning.hypothesisRepeatWindowSeconds {
                record(.sustainedByRepeat, needID: needID, detail: nil)
            } else {
                recentHypothesisAt[needID] = now
                latchConfirmPending = true
                record(.latchRejected, needID: needID, detail: "not-sustained")
                scheduleConfirm(
                    needID: needID,
                    confidence: assessment.confidence,
                    callKeyframes: callKeyframes,
                    assessment: assessment,
                    now: now
                )
                return
            }
        } else {
            recentHypothesisAt[needID] = now
        }
        let acceptDetail = urgentEvidence.map {
            "urgent-single-frame evidence=\($0.frame.id) conf=\($0.confidence)"
        }
        finishLatch(
            needID: needID,
            assessment: assessment,
            callKeyframes: callKeyframes,
            now: now,
            acceptDetail: acceptDetail,
            visibleAt: urgentEvidence?.frame.capturedAt
        )
    }

    /// The gates after the sustained check, shared by fresh hypotheses
    /// and confirmed sightings. True when the need opened. A coincident
    /// pending confirm ends `latched` with it.
    @discardableResult
    private mutating func finishLatch(
        needID: String,
        assessment: SceneAssessment,
        callKeyframes: [Keyframe],
        now: Date,
        acceptDetail: String? = nil,
        visibleAt: Date? = nil
    ) -> Bool {
        guard let need = catalog.need(id: needID) else { return false }
        if indexOfOpen(needID) != nil {
            record(.latchRejected, needID: needID, detail: "already-open")
            return false
        }
        if let closed = closedAt[needID],
           now.timeIntervalSince(closed) < timing.relatchCooldownSeconds {
            record(.latchRejected, needID: needID, detail: "cooldown")
            return false
        }
        if let lastSuccessfulLatchAt,
           now.timeIntervalSince(lastSuccessfulLatchAt) < timing.latchMinIntervalSeconds {
            record(.latchRejected, needID: needID, detail: "latch-interval")
            return false
        }
        let liveStrip = buffer.modelStrip(now: now, purpose: .latch, confirm: latchConfirmPending, latency: latency)
        let effectiveCount = max(callKeyframes.count, liveStrip.count)
        let minKeyframes = (latency.urgentNeedsEnabled && need.isUrgent) ? 1 : timing.latchMinKeyframes
        if effectiveCount < minKeyframes {
            record(.latchRejected, needID: needID, detail: "strip-too-thin")
            return false
        }
        if tracked.count >= SessionLimits.maxOpenNeeds {
            guard let worst = worstOpenIndex() else { return false }
            let candidatePriority = catalog.priority(of: needID)
            let worstPriority = catalog.priority(of: tracked[worst].needID)
            if candidatePriority < worstPriority {
                let displaced = tracked[worst].needID
                close(displaced, now: now, cooldown: false)
                record(.closedUnknown, needID: displaced, detail: "preempted")
            } else {
                record(.latchRejected, needID: needID, detail: "max-open")
                return false
            }
        }
        latchConfirmPending = false
        if let acceptDetail {
            record(.latchAccepted, needID: needID, detail: acceptDetail)
        }
        finishConfirm(needID: needID, outcome: .latched)
        open(
            needID,
            now: now,
            visibleAt: visibleAt ?? (callKeyframes.first ?? liveStrip.first)?.capturedAt ?? now,
            absent: assessment.partnerInView == false,
            handsBusy: assessment.wearerHandsOccupied == true
        )
        return true
    }

    /// One sighting for a high-confidence brief sighting. Skipped while
    /// one is already pending or in flight for the need, and when the
    /// verdict carried no usable confidence. The sources are the actual
    /// frames the model cited, or the strip's newest frame.
    private mutating func scheduleConfirm(
        needID: String,
        confidence: Double?,
        callKeyframes: [Keyframe],
        assessment: SceneAssessment,
        now: Date
    ) {
        guard let confidence, confidence >= EngineTuning.confirmMinConfidence else {
            return
        }
        guard pendingConfirms[needID] == nil else {
            return
        }
        let inFlight = pendingModelCalls.contains {
            $0.purpose == .confirm && $0.request.focusNeedID == needID
        }
        guard !inFlight else {
            return
        }
        let cited = Set(assessment.evidenceKeyframeIDs ?? [])
        var sources = callKeyframes.filter { cited.contains($0.id) }
        if sources.isEmpty, let newest = callKeyframes.max(by: { $0.capturedAt < $1.capturedAt }) {
            sources = [newest]
        }
        pendingConfirms[needID] = PendingConfirm(
            dueAt: now.addingTimeInterval(EngineTuning.confirmDelaySeconds),
            sourceFrames: sources,
            hypothesisAt: now,
            attemptsIssued: 0,
            usedNewFrameIDs: []
        )
        record(.confirmScheduled, needID: needID, detail: nil)
    }

    /// The one place confirm state clears. A late reply for an in-flight
    /// attempt drops once its sighting is gone.
    private mutating func finishConfirm(needID: String, outcome: ConfirmOutcome) {
        guard pendingConfirms.removeValue(forKey: needID) != nil else { return }
        for call in pendingModelCalls where call.purpose == .confirm && call.request.focusNeedID == needID {
            abandonInFlightCall(id: call.id)
        }
        record(.confirmEnded, needID: needID, detail: "outcome=\(outcome.rawValue)")
    }

    /// An inconclusive attempt schedules the next one inside the caps, or
    /// ends the sighting. Elapsed time beats attempt count.
    private mutating func retryConfirm(needID: String, pending: PendingConfirm, reason: String, now: Date) {
        if now >= pending.hypothesisAt.addingTimeInterval(EngineTuning.confirmMaxElapsedSeconds) {
            finishConfirm(needID: needID, outcome: .expired)
            return
        }
        let next = pending.attemptsIssued + 1
        guard next <= EngineTuning.confirmMaxAttempts else {
            finishConfirm(needID: needID, outcome: .exhausted)
            return
        }
        var pending = pending
        pending.dueAt = now.addingTimeInterval(EngineTuning.confirmDelaySeconds)
        pendingConfirms[needID] = pending
        record(.confirmRetry, needID: needID, detail: "attempt=\(next) reason=\(reason)")
    }

    /// Reads a confirm reply against its sighting. Only a cited new frame
    /// with an unmet anchor latches; handled in a new frame clears; the
    /// rest retries inside the caps.
    private mutating func handleConfirmReply(call: PendingModelCall, verdict: ModelVerdict, now: Date) {
        guard let needID = call.request.focusNeedID,
              let pending = pendingConfirms[needID] else { return }
        // Time beats content: a late reply ends the sighting, whatever it saw.
        if now >= pending.hypothesisAt.addingTimeInterval(EngineTuning.confirmMaxElapsedSeconds) {
            finishConfirm(needID: needID, outcome: .expired)
            return
        }
        let assessment = verdict.assessment
        let strip = call.request.keyframes
        let sourceIDs = Set(pending.sourceFrames.map(\.id))
        let newIDs = Set(strip.map(\.id)).subtracting(sourceIDs)
        let cited = Set(assessment.evidenceKeyframeIDs ?? [])
        let newestIsNew = strip.max(by: { $0.capturedAt < $1.capturedAt }).map { newIDs.contains($0.id) } ?? false

        // Handled in a new frame beats older unmet evidence.
        if assessment.newestAnchorState == .handled, newestIsNew {
            record(.confirmCleared, needID: needID, detail: "reason=handled")
            finishConfirm(needID: needID, outcome: .cleared)
            return
        }
        // A cited new frame plus an unmet newest anchor confirms.
        if !cited.intersection(newIDs).isEmpty, assessment.newestAnchorState == .unmet {
            if finishLatch(needID: needID, assessment: assessment, callKeyframes: strip, now: now) {
                return
            }
            finishConfirm(needID: needID, outcome: .exhausted)
            return
        }
        // Cites only the old sources with an unmet anchor: looks
        // confirming, proves nothing.
        if !cited.isEmpty, cited.isSubset(of: sourceIDs), assessment.newestAnchorState == .unmet {
            record(.confirmSelfOnly, needID: needID, detail: nil)
            retryConfirm(needID: needID, pending: pending, reason: "self-only", now: now)
            return
        }
        if assessment.newestAnchorState == .notVisible, newestIsNew {
            retryConfirm(needID: needID, pending: pending, reason: "not-visible", now: now)
            return
        }
        retryConfirm(needID: needID, pending: pending, reason: "unclear", now: now)
    }

    private mutating func open(
        _ needID: String,
        now: Date,
        visibleAt: Date,
        absent: Bool,
        handsBusy: Bool = false
    ) {
        guard let need = catalog.need(id: needID) else { return }
        if tracked.isEmpty {
            lastHeartbeatAt = now
        }
        let headStart = MasteryMath.headStartSeconds(for: need, timing: timing, latency: latency)
        let choreID = freshChoreID(now: now)
        let episodeID = "e\(nextEpisodeNumber)"
        nextEpisodeNumber += 1
        unpromptedPending.removeValue(forKey: needID)
        tracked.append(
            TrackedNeed(
                needID: needID,
                episodeID: episodeID,
                visibleAt: visibleAt,
                latchedAt: now,
                cueDeadline: now.addingTimeInterval(headStart),
                hardCapAt: now.addingTimeInterval(timing.headStartCapSeconds),
                evidenceAt: now,
                handsBusy: handsBusy,
                awaitingRecheck: false,
                recheckUsed: false,
                inconclusiveHold: false,
                pendingCueKind: nil,
                choreID: choreID,
                pendingWearerAction: nil,
                didLogBusyDefer: false,
                didLogRateLimit: false,
                cueDelivered: false,
                latchedWhileAbsent: absent,
                recheckStrikes: 0,
                cueFiredAt: nil,
                cueID: nil
            )
        )
        lastSuccessfulLatchAt = now
        record(.needLatched, needID: needID, detail: nil)
    }

    private func freshChoreID(now: Date) -> String? {
        guard let choreMark else { return nil }
        guard now.timeIntervalSince(choreMark.at) <= EngineTuning.sameChoreWindowSeconds else {
            return nil
        }
        return choreMark.id
    }

    private func worstOpenIndex() -> Int? {
        tracked.indices.max { lhs, rhs in
            let left = catalog.priority(of: tracked[lhs].needID)
            let right = catalog.priority(of: tracked[rhs].needID)
            if left != right { return left < right }
            return tracked[lhs].latchedAt < tracked[rhs].latchedAt
        }
    }

    private mutating func applyDeferAndExtension(_ needID: String, verdict: ModelVerdict) {
        guard let index = indexOfOpen(needID) else { return }
        if verdict.tool == .deferCueWearerBusy {
            tracked[index].handsBusy = true
        }
        guard verdict.tool == .requestHeadStartExtension else { return }
        let cap = tracked[index].hardCapAt
        if tracked[index].cueDeadline >= cap {
            record(.headStartExtensionDenied, needID: needID, detail: "at-cap")
            return
        }
        let proposed = tracked[index].cueDeadline.addingTimeInterval(EngineTuning.headStartExtensionStepSeconds)
        tracked[index].cueDeadline = min(proposed, cap)
        record(.headStartExtended, needID: needID, detail: nil)
    }

    // MARK: - Bookkeeping

    private mutating func notePartner(_ assessment: SceneAssessment, tool: ToolName, now: Date) {
        if assessment.partnerInView == true {
            buffer.notePersonSeen(at: now)
            refreshEvidence(at: now)
            return
        }
        // A sustained latch is itself a look at her, when the model did not say she was absent.
        if tool == .latchNeedHypothesis,
           assessment.sustainedAcrossStrip == true,
           assessment.partnerInView != false {
            buffer.notePersonSeen(at: now)
        }
    }

    private mutating func refreshEvidence(at now: Date) {
        for index in tracked.indices where now > tracked[index].evidenceAt {
            tracked[index].evidenceAt = now
        }
    }

    private mutating func refreshEvidenceFromKeyframes() {
        guard let newest = buffer.keyframes(now: clock.now()).map(\.capturedAt).max() else { return }
        refreshEvidence(at: newest)
    }

    private func indexOfOpen(_ id: String) -> Int? {
        tracked.firstIndex { $0.needID == id }
    }

    private mutating func close(_ id: String, now: Date, cooldown: Bool) {
        if let episodeID = tracked.first(where: { $0.needID == id })?.episodeID {
            lastClosedEpisodeID[id] = episodeID
        }
        tracked.removeAll { $0.needID == id }
        if cooldown {
            closedAt[id] = now
        }
    }

    private mutating func record(_ kind: EngineEventKind, needID: String?, detail: String?) {
        events.append(EngineEvent(
            kind: kind,
            needID: needID,
            at: clock.now(),
            detail: detail,
            episodeID: episodeID(for: kind, needID: needID)
        ))
    }

    /// The five latch-scoped kinds carry the open episode, or the
    /// just-closed one: every `close` stashes its id first, and these
    /// events only fire while open or at the close.
    private func episodeID(for kind: EngineEventKind, needID: String?) -> String? {
        switch kind {
        case .cueFired, .caughtHimself, .resolvedByOther, .closedUnknown, .stillOpen:
            guard let needID else { return nil }
            return tracked.first { $0.needID == needID }?.episodeID ?? lastClosedEpisodeID[needID]
        default:
            return nil
        }
    }
}
