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
    private struct ChoreMark: Equatable {
        var id: String
        var at: Date
    }

    private struct TrackedNeed {
        var needID: String
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
    private var catalog: Catalog
    private var buffer = KeyframeBuffer()
    private var visitor = VisitorMonitor()
    private var tracked: [TrackedNeed] = []
    private var choreMark: ChoreMark?
    private var events: [EngineEvent] = []
    private var playedCues: [Cue] = []
    private var cueEffects: [String: CueEffect] = [:]
    private var closedAt: [String: Date] = [:]
    private var sessionStartedAt: Date
    private var didLogSessionEnd = false
    private var didLogBudget = false
    private var callSerial = 0
    private var cueSerial = 0
    private var lastModelCallAt: Date?
    private var lastLatchCallAt: Date?
    private var lastSuccessfulLatchAt: Date?
    private var revisionAtLastLatchCall = 0
    private var lastCueAt: Date?
    private var handEdgePending = false
    private var staleCallIDs: Set<String> = []
    private var callsIssued = 0

    public private(set) var pendingModelCall: PendingModelCall?
    public private(set) var visitorUploadPaused = false

    public init(clock: TimeSource, needs: [Need] = []) throws {
        self.clock = clock
        catalog = try Catalog(needs)
        sessionStartedAt = clock.now()
    }

    public var needs: [Need] { catalog.needs }

    public var modelCallsIssued: Int { callsIssued }

    public var log: [EngineEvent] { events }

    public var cues: [Cue] { playedCues }

    public var openNeedIDs: [String] { tracked.map(\.needID) }

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
                pendingWearerAction: item.pendingWearerAction
            )
        }
    }

    public mutating func setNeeds(_ needs: [Need]) throws {
        let replacement = try Catalog(needs)
        catalog = replacement
        tracked.removeAll { catalog.need(id: $0.needID) == nil }
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

    /// A phone tap that this whisper was wrong. Mastery returns to the
    /// pre-cue value. The cue still counts toward the rate limit.
    public mutating func dismissFalseCue(_ cueID: String) {
        guard var effect = cueEffects[cueID], !effect.dismissed else { return }
        guard var need = catalog.need(id: effect.needID) else { return }
        need.mastery = effect.masteryBefore
        catalog.update(need)
        effect.dismissed = true
        cueEffects[cueID] = effect
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
        buffer.ingest(
            frame: frame,
            personPresent: personPresent,
            sceneActive: gate.sceneActive,
            sharpness: sharpness ?? gate.sharpness,
            now: clock.now(),
            recordKeyframe: !visitor.currentFrameQualifies
        )
        if gate.handGateRisingEdge || gate.activityEdge {
            handEdgePending = true
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
        if pendingModelCall?.id != callID {
            record(.staleReplyDropped, needID: verdict.assessment.needID, detail: callID)
            return
        }
        pendingModelCall = nil

        let namedNeedID = verdict.assessment.needID
        var verdict = verdict
        verdict.assessment = sanitize(verdict.assessment)
        let assessment = verdict.assessment
        notePartner(assessment, tool: verdict.tool, now: now)

        // An omitted need id can apply to the only open need. An unknown id
        // was dropped in sanitize and must not spill onto that need.
        let subjectID: String?
        if namedNeedID != nil {
            subjectID = assessment.needID
        } else {
            subjectID = tracked.count == 1 ? tracked[0].needID : nil
        }
        if let subjectID, catalog.need(id: subjectID) != nil {
            applyAssessment(subjectID, verdict: verdict, now: now)
        }

        if verdict.tool == .latchNeedHypothesis {
            tryLatch(assessment, now: now)
        }

        if let needID = assessment.needID, indexOfOpen(needID) != nil {
            applyDeferAndExtension(needID, verdict: verdict)
        }

        if let subjectID, let index = indexOfOpen(subjectID), tracked[index].awaitingRecheck {
            finishRecheck(at: index, assessment: assessment, now: now)
        }

        evaluate()
    }

    // MARK: - Time

    private mutating func evaluate() {
        let now = clock.now()
        buffer.expire(now: now)
        if sessionIsOver(now) {
            if !didLogSessionEnd {
                didLogSessionEnd = true
                record(.sessionEnded, needID: nil, detail: nil)
            }
            retireStaleInFlight(now: now)
            pendingModelCall = nil
            return
        }
        closeNeedsWithNoPerson(now: now)
        resolveDueNeeds(now: now)
        scheduleModelCall(now: now)
    }

    private func sessionIsOver(_ now: Date) -> Bool {
        now.timeIntervalSince(sessionStartedAt) >= SessionLimits.maxSessionSeconds
    }

    private mutating func closeNeedsWithNoPerson(now: Date) {
        guard let lastPerson = buffer.lastPersonSeenAt else { return }
        guard now.timeIntervalSince(lastPerson) >= SessionLimits.noPersonKeyframeCloseSeconds else {
            return
        }
        let expiring = tracked.filter { !sameChoreHolds($0, now: now) }.map(\.needID)
        for id in expiring {
            close(id, now: now, cooldown: true)
            record(.closedUnknown, needID: id, detail: "no-person")
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

        if tracked[index].pendingCueKind == nil {
            let evidenceAge = now.timeIntervalSince(tracked[index].evidenceAt)
            if evidenceAge > SessionLimits.staleEvidenceSeconds && !tracked[index].recheckUsed {
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

        let kind = tracked[index].pendingCueKind ?? cueKind(for: need.mastery)
        deliverCue(kind, for: need, now: now)
    }

    private func cueKind(for mastery: MasteryState) -> CueKind {
        mastery.phase == .quiet ? .chime : .whisper
    }

    private func rateLimitAllows(_ now: Date) -> Bool {
        guard let lastCueAt else { return true }
        return now.timeIntervalSince(lastCueAt) >= SessionLimits.cueRateLimitSeconds
    }

    private mutating func beginRecheck(at index: Int, now: Date) {
        retireStaleInFlight(now: now)
        let needID = tracked[index].needID
        if pendingModelCall != nil {
            tracked[index].recheckUsed = true
            tracked[index].awaitingRecheck = true
            record(.recheckRequested, needID: needID, detail: "in-flight")
            return
        }
        // A paused upload or a spent call budget is not an answer. Try again
        // on a later tick instead of whispering blind.
        if !canIssueCall(now: now) { return }
        tracked[index].recheckUsed = true
        tracked[index].awaitingRecheck = true
        record(.recheckRequested, needID: needID, detail: nil)
        issue(.recheck, now: now)
    }

    private mutating func finishRecheck(at index: Int, assessment: SceneAssessment, now: Date) {
        tracked[index].awaitingRecheck = false
        let needID = tracked[index].needID
        guard catalog.need(id: needID) != nil else { return }
        if assessment.sustainedAcrossStrip == true {
            tracked[index].evidenceAt = now
            return
        }
        if assessment.sustainedAcrossStrip == false {
            if tracked[index].pendingWearerAction != nil {
                return
            }
            close(needID, now: now, cooldown: true)
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
            // Check-in has no separate phrase in the contract. The kind is the
            // signal; the words stay the ones mom already wrote.
            text = need.cueWording
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
        close(need.id, now: now, cooldown: true)
        record(.cueFired, needID: need.id, detail: kind.rawValue)
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

    private mutating func scheduleModelCall(now: Date) {
        retireStaleInFlight(now: now)
        guard pendingModelCall == nil else { return }
        guard canIssueCall(now: now) else {
            if !visitorUploadPaused && !sessionIsOver(now) && callsIssued >= SessionLimits.maxModelCallsPerSession && !didLogBudget {
                didLogBudget = true
                record(.callBudgetExhausted, needID: nil, detail: nil)
            }
            return
        }

        if tracked.contains(where: \.awaitingRecheck) {
            issue(.recheck, now: now)
            return
        }

        if !tracked.isEmpty {
            let heartbeatDue = lastModelCallAt.map {
                now.timeIntervalSince($0) >= SessionLimits.heartbeatSeconds
            } ?? true
            if heartbeatDue || handEdgePending {
                issue(.heartbeat, now: now)
                return
            }
        }

        guard tracked.count < SessionLimits.maxOpenNeeds else { return }
        guard buffer.revision > revisionAtLastLatchCall else { return }
        if let lastLatchCallAt,
           now.timeIntervalSince(lastLatchCallAt) < SessionLimits.latchMinIntervalSeconds {
            return
        }
        let strip = buffer.modelStrip(now: now)
        guard strip.count >= SessionLimits.latchMinKeyframes else { return }
        issue(.latch, now: now)
    }

    private func canIssueCall(now: Date) -> Bool {
        if visitorUploadPaused || sessionIsOver(now) { return false }
        return callsIssued < SessionLimits.maxModelCallsPerSession
    }

    private mutating func issue(_ purpose: ModelCallPurpose, now: Date) {
        callSerial += 1
        callsIssued += 1
        let id = "call-\(callSerial)"
        lastModelCallAt = now
        if purpose == .latch {
            lastLatchCallAt = now
            revisionAtLastLatchCall = buffer.revision
        }
        if purpose == .heartbeat || purpose == .recheck {
            handEdgePending = false
        }
        pendingModelCall = PendingModelCall(
            id: id,
            purpose: purpose,
            request: ModelRequest(keyframes: buffer.modelStrip(now: now), needs: catalog.needs),
            issuedAt: now
        )
    }

    /// The transport gave up on the in-flight call. The next tick may start another.
    /// A reply that arrives later for this id is dropped.
    public mutating func abandonInFlightCall() {
        guard let pendingModelCall else { return }
        staleCallIDs.insert(pendingModelCall.id)
        self.pendingModelCall = nil
    }

    private mutating func retireStaleInFlight(now: Date) {
        guard let pendingModelCall else { return }
        guard now.timeIntervalSince(pendingModelCall.issuedAt) >= EngineTuning.inFlightStaleSeconds else {
            return
        }
        staleCallIDs.insert(pendingModelCall.id)
        self.pendingModelCall = nil
    }

    // MARK: - Verdicts

    private mutating func sanitize(_ assessment: SceneAssessment) -> SceneAssessment {
        var assessment = assessment
        if let needID = assessment.needID, catalog.need(id: needID) == nil {
            assessment.needID = nil
            record(.assessmentDropped, needID: needID, detail: "unknown-need")
        }
        if let resolution = assessment.resolution, !Resolution.recognized.contains(resolution) {
            assessment.resolution = nil
            record(.assessmentDropped, needID: assessment.needID, detail: "unknown-resolution")
        }
        return assessment
    }

    private mutating func applyAssessment(_ needID: String, verdict: ModelVerdict, now: Date) {
        let assessment = verdict.assessment
        guard var need = catalog.need(id: needID) else { return }

        if assessment.resolution == .resolvedByPartner {
            guard indexOfOpen(needID) != nil else { return }
            close(needID, now: now, cooldown: true)
            record(.resolvedByPartner, needID: needID, detail: verdict.tool.rawValue)
            return
        }

        guard let index = indexOfOpen(needID) else { return }

        if assessment.sustainedAcrossStrip == true {
            tracked[index].evidenceAt = now
        }
        if let occupied = assessment.wearerHandsOccupied {
            tracked[index].handsBusy = occupied
            if !occupied {
                tracked[index].didLogBusyDefer = false
            }
        }

        let hadPending = tracked[index].pendingWearerAction != nil
        let pendingAction = tracked[index].pendingWearerAction
        // `caught_himself` while the strip still shows the need is not a clear.
        let cleared = assessment.sustainedAcrossStrip == false
            || (assessment.resolution == .caughtHimself && assessment.sustainedAcrossStrip != true)
        let wearerAction = MasteryMath.isWearerAction(assessment.actionCode, selfNoticeSignal: need.selfNoticeSignal)

        if hadPending && cleared {
            let before = need.mastery
            need.mastery = MasteryMath.applySelfNotice(need.mastery)
            let becameRetired = before.phase != .retired && need.mastery.phase == .retired
            catalog.update(need)
            close(needID, now: now, cooldown: true)
            record(.caughtHimself, needID: needID, detail: pendingAction)
            if becameRetired {
                record(.masteryRetired, needID: needID, detail: nil)
            }
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
        } else if assessment.resolution == .caughtHimself {
            record(.actionRejected, needID: needID, detail: "unconfirmed")
        }
    }

    private mutating func tryLatch(_ assessment: SceneAssessment, now: Date) {
        guard let needID = assessment.needID else { return }
        guard catalog.need(id: needID) != nil else { return }
        if visitorUploadPaused {
            record(.latchRejected, needID: needID, detail: "visitor-paused")
            return
        }
        if sessionIsOver(now) {
            record(.latchRejected, needID: needID, detail: "session-ended")
            return
        }
        if assessment.sustainedAcrossStrip != true {
            record(.latchRejected, needID: needID, detail: "not-sustained")
            return
        }
        if indexOfOpen(needID) != nil {
            record(.latchRejected, needID: needID, detail: "already-open")
            return
        }
        if let closed = closedAt[needID],
           now.timeIntervalSince(closed) < SessionLimits.relatchCooldownSeconds {
            record(.latchRejected, needID: needID, detail: "cooldown")
            return
        }
        if let lastSuccessfulLatchAt,
           now.timeIntervalSince(lastSuccessfulLatchAt) < SessionLimits.latchMinIntervalSeconds {
            record(.latchRejected, needID: needID, detail: "latch-interval")
            return
        }
        let strip = buffer.modelStrip(now: now)
        if strip.count < SessionLimits.latchMinKeyframes {
            record(.latchRejected, needID: needID, detail: "strip-too-thin")
            return
        }
        if tracked.count >= SessionLimits.maxOpenNeeds {
            guard let worst = worstOpenIndex() else { return }
            let candidatePriority = catalog.priority(of: needID)
            let worstPriority = catalog.priority(of: tracked[worst].needID)
            if candidatePriority < worstPriority {
                let displaced = tracked[worst].needID
                close(displaced, now: now, cooldown: false)
                record(.closedUnknown, needID: displaced, detail: "preempted")
            } else {
                record(.latchRejected, needID: needID, detail: "max-open")
                return
            }
        }
        open(needID, now: now)
    }

    private mutating func open(_ needID: String, now: Date) {
        guard let need = catalog.need(id: needID) else { return }
        let headStart = MasteryMath.headStartSeconds(for: need)
        let choreID = freshChoreID(now: now)
        tracked.append(
            TrackedNeed(
                needID: needID,
                latchedAt: now,
                cueDeadline: now.addingTimeInterval(headStart),
                hardCapAt: now.addingTimeInterval(SessionLimits.headStartCapSeconds),
                evidenceAt: now,
                handsBusy: false,
                awaitingRecheck: false,
                recheckUsed: false,
                inconclusiveHold: false,
                pendingCueKind: nil,
                choreID: choreID,
                pendingWearerAction: nil,
                didLogBusyDefer: false,
                didLogRateLimit: false,
                cueDelivered: false
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
        tracked.removeAll { $0.needID == id }
        if cooldown {
            closedAt[id] = now
        }
    }

    private mutating func record(_ kind: EngineEventKind, needID: String?, detail: String?) {
        events.append(EngineEvent(kind: kind, needID: needID, at: clock.now(), detail: detail))
    }
}
