import Foundation
import NoticerCore
import Synchronization

/// Codes the engine can branch on. Messages are for logs and the phone.
public enum ToolRejectionCode {
    public static let callBudget = "call_budget"
    public static let missingNeed = "missing_need"
    public static let notOnList = "not_on_list"
    public static let notSustained = "not_sustained"
    public static let keyframeCount = "keyframe_count"
    public static let keyframeSpacing = "keyframe_spacing"
    public static let alreadyOpen = "already_open"
    public static let maxOpenNeeds = "max_open_needs"
    public static let latchInterval = "latch_interval"
    public static let relatchCooldown = "relatch_cooldown"
    public static let handsNotOccupied = "hands_not_occupied"
    public static let noOpenHeadStart = "no_open_head_start"
    public static let hardCapFiresCue = "hard_cap_fires_cue"
    public static let notWearerAction = "not_wearer_action"
    public static let extensionStepNotConfigured = "extension_step_not_configured"
    public static let missingExtensionReason = "missing_extension_reason"
    public static let headStartCap = "head_start_cap"
}

public struct ToolRejection: Equatable, Sendable {
    public var tool: ToolName
    public var code: String
    public var message: String

    public init(tool: ToolName, code: String, message: String) {
        self.tool = tool
        self.code = code
        self.message = message
    }
}

public enum AcceptedToolAction: Equatable, Sendable {
    case latch(needID: String)
    case deferCue(needID: String, hardCapAt: Date)
    /// `hardCapAt` is when a defer stops mattering and the cue still fires.
    case wearerIntervention(needID: String, actionCode: String)
    case headStartExtension(needID: String, grantedSeconds: TimeInterval, resultingHeadStartSeconds: TimeInterval)
    case noTransition
}

public enum ToolOutcome: Equatable, Sendable {
    case accepted(AcceptedToolAction)
    case rejected(ToolRejection)
}

/// The verdict is the model's request, unchanged. `outcome` is what the caps allow.
/// `resolved_by_partner` stays on `verdict` whichever tool carried it. This type does not edit mastery.
public struct ToolHandlerResult: Equatable, Sendable {
    public var verdict: ModelVerdict
    public var outcome: ToolOutcome

    public init(verdict: ModelVerdict, outcome: ToolOutcome) {
        self.verdict = verdict
        self.outcome = outcome
    }
}

/// An open head start. `hardCapAt` is the start plus `SessionLimits.headStartCapSeconds`.
public struct HeadStartWindow: Equatable, Sendable {
    public var startedAt: Date
    public var endsAt: Date

    public init(startedAt: Date, endsAt: Date) {
        self.startedAt = startedAt
        self.endsAt = endsAt
    }

    public var hardCapAt: Date {
        startedAt.addingTimeInterval(SessionLimits.headStartCapSeconds)
    }
}

/// Facts the caps need. The engine fills this. `callsCompletedBeforeThis` does not include the verdict being judged.
public struct CapSession: Equatable, Sendable {
    public var now: Date
    public var authoredNeedIDs: Set<String>
    public var openNeedIDs: [String]
    public var callsCompletedBeforeThis: Int
    public var lastLatchAt: Date?
    public var relatchNotBefore: [String: Date]
    public var headStarts: [String: HeadStartWindow]
    public var lastCueAt: Date?

    public init(
        now: Date,
        authoredNeedIDs: Set<String> = [],
        openNeedIDs: [String] = [],
        callsCompletedBeforeThis: Int = 0,
        lastLatchAt: Date? = nil,
        relatchNotBefore: [String: Date] = [:],
        headStarts: [String: HeadStartWindow] = [:],
        lastCueAt: Date? = nil
    ) {
        self.now = now
        self.authoredNeedIDs = authoredNeedIDs
        self.openNeedIDs = openNeedIDs
        self.callsCompletedBeforeThis = callsCompletedBeforeThis
        self.lastLatchAt = lastLatchAt
        self.relatchNotBefore = relatchNotBefore
        self.headStarts = headStarts
        self.lastCueAt = lastCueAt
    }
}

/// `action_code` is an open string. A wearer action is a non-empty value with the `wearer_` prefix.
/// `water_glass_present` does not have that prefix and is not a wearer action.
public enum WearerActionRule {
    public static let prefix = "wearer_"

    public static func isWearerAction(_ code: String?) -> Bool {
        guard let code else {
            return false
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix), trimmed.count > prefix.count else {
            return false
        }
        return trimmed != ActionCodeExamples.waterGlassPresent
    }
}

/// Applies the five tool requests against the PRD caps.
///
/// The head-start extension step is not chosen here. Pass one in, or extensions are refused.
/// Cue speech is not performed here. Call `isCueRateLimited` before a whisper.
/// Visitor counts and mastery math stay on the core track.
public struct HardCapGate: Equatable, Sendable {
    public var extensionStepSeconds: TimeInterval?
    public var timing: TimingProfile

    public init(extensionStepSeconds: TimeInterval? = nil, timing: TimingProfile = .standard) {
        self.extensionStepSeconds = extensionStepSeconds
        self.timing = timing
    }

    public static func isCueRateLimited(
        lastCueAt: Date?,
        now: Date,
        timing: TimingProfile = .standard
    ) -> Bool {
        guard let lastCueAt else {
            return false
        }
        return now.timeIntervalSince(lastCueAt) < timing.cueRateLimitSeconds
    }

    public func decide(
        verdict: ModelVerdict,
        session: CapSession,
        keyframes: [Keyframe] = []
    ) -> ToolHandlerResult {
        if session.callsCompletedBeforeThis >= SessionLimits.maxModelCallsPerSession {
            return reject(
                verdict,
                code: ToolRejectionCode.callBudget,
                message: "This session already made \(SessionLimits.maxModelCallsPerSession) model calls."
            )
        }
        switch verdict.tool {
        case .latchNeedHypothesis:
            return latch(verdict, session: session, keyframes: keyframes)
        case .deferCueWearerBusy:
            return deferCue(verdict, session: session)
        case .logWearerIntervention:
            return wearer(verdict, session: session)
        case .requestHeadStartExtension:
            return extend(verdict, session: session)
        case .reportNoTransition:
            return accept(verdict, .noTransition)
        }
    }

    private func latch(
        _ verdict: ModelVerdict,
        session: CapSession,
        keyframes: [Keyframe]
    ) -> ToolHandlerResult {
        guard let needID = need(verdict, session: session) else {
            return rejectedNeed(verdict)
        }
        guard verdict.assessment.sustainedAcrossStrip == true else {
            return reject(
                verdict,
                code: ToolRejectionCode.notSustained,
                message: "A latch needs sustained_across_strip to be true. Confidence is not a gate."
            )
        }
        guard keyframes.count >= timing.latchMinKeyframes else {
            return reject(
                verdict,
                code: ToolRejectionCode.keyframeCount,
                message: "A latch needs at least \(timing.latchMinKeyframes) keyframes."
            )
        }
        let ages = keyframes.map(\.ageSeconds)
        let span = (ages.max() ?? 0) - (ages.min() ?? 0)
        guard span >= timing.latchMinKeyframeSpacingSeconds else {
            return reject(
                verdict,
                code: ToolRejectionCode.keyframeSpacing,
                message: "A latch needs keyframes at least \(Int(timing.latchMinKeyframeSpacingSeconds)) seconds apart."
            )
        }
        if session.openNeedIDs.contains(needID) {
            return reject(
                verdict,
                code: ToolRejectionCode.alreadyOpen,
                message: "Need \(needID) is already open."
            )
        }
        if session.openNeedIDs.count >= SessionLimits.maxOpenNeeds {
            return reject(
                verdict,
                code: ToolRejectionCode.maxOpenNeeds,
                message: "Only \(SessionLimits.maxOpenNeeds) needs may be open at once."
            )
        }
        if let lastLatchAt = session.lastLatchAt,
           session.now.timeIntervalSince(lastLatchAt) < timing.latchMinIntervalSeconds {
            return reject(
                verdict,
                code: ToolRejectionCode.latchInterval,
                message: "Latch calls are at least \(Int(timing.latchMinIntervalSeconds)) seconds apart."
            )
        }
        if let notBefore = session.relatchNotBefore[needID], session.now < notBefore {
            return reject(
                verdict,
                code: ToolRejectionCode.relatchCooldown,
                message: "Need \(needID) is inside its re-latch cooldown."
            )
        }
        return accept(verdict, .latch(needID: needID))
    }

    private func deferCue(_ verdict: ModelVerdict, session: CapSession) -> ToolHandlerResult {
        guard let needID = need(verdict, session: session) else {
            return rejectedNeed(verdict)
        }
        guard verdict.assessment.wearerHandsOccupied == true else {
            return reject(
                verdict,
                code: ToolRejectionCode.handsNotOccupied,
                message: "A defer is only accepted when wearer_hands_occupied is true."
            )
        }
        guard let window = session.headStarts[needID] else {
            return reject(
                verdict,
                code: ToolRejectionCode.noOpenHeadStart,
                message: "There is no open head start to defer."
            )
        }
        let hardCapAt = window.startedAt.addingTimeInterval(timing.headStartCapSeconds)
        if session.now >= hardCapAt {
            return reject(
                verdict,
                code: ToolRejectionCode.hardCapFiresCue,
                message: "The \(Int(timing.headStartCapSeconds))s head-start cap has been reached, so the cue still fires."
            )
        }
        return accept(verdict, .deferCue(needID: needID, hardCapAt: hardCapAt))
    }

    private func wearer(_ verdict: ModelVerdict, session: CapSession) -> ToolHandlerResult {
        guard let needID = need(verdict, session: session) else {
            return rejectedNeed(verdict)
        }
        if verdict.assessment.actionCode == ActionCodeExamples.waterGlassPresent {
            return reject(
                verdict,
                code: ToolRejectionCode.notWearerAction,
                message: "water_glass_present is a passive scene detail, not a wearer action."
            )
        }
        guard let code = verdict.assessment.actionCode, WearerActionRule.isWearerAction(code) else {
            return reject(
                verdict,
                code: ToolRejectionCode.notWearerAction,
                message: "action_code is an open string, and a wearer action starts with \(WearerActionRule.prefix)."
            )
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return accept(verdict, .wearerIntervention(needID: needID, actionCode: trimmed))
    }

    private func extend(_ verdict: ModelVerdict, session: CapSession) -> ToolHandlerResult {
        guard let needID = need(verdict, session: session) else {
            return rejectedNeed(verdict)
        }
        guard let step = extensionStepSeconds, step > 0 else {
            return reject(
                verdict,
                code: ToolRejectionCode.extensionStepNotConfigured,
                message: "No head-start extension step is configured. The step size is not a shared constant; the caller passes one. The cap stays \(Int(timing.headStartCapSeconds)) seconds."
            )
        }
        guard let reason = verdict.extensionReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else {
            return reject(
                verdict,
                code: ToolRejectionCode.missingExtensionReason,
                message: "request_head_start_extension needs extension_reason."
            )
        }
        guard let window = session.headStarts[needID] else {
            return reject(
                verdict,
                code: ToolRejectionCode.noOpenHeadStart,
                message: "There is no open head start to extend."
            )
        }
        let current = max(0, window.endsAt.timeIntervalSince(window.startedAt))
        let room = timing.headStartCapSeconds - current
        if room <= 0 {
            return reject(
                verdict,
                code: ToolRejectionCode.headStartCap,
                message: "The head start is already at the \(Int(timing.headStartCapSeconds))s cap."
            )
        }
        let granted = min(step, room)
        return accept(
            verdict,
            .headStartExtension(
                needID: needID,
                grantedSeconds: granted,
                resultingHeadStartSeconds: current + granted
            )
        )
    }

    private func need(_ verdict: ModelVerdict, session: CapSession) -> String? {
        guard let needID = verdict.assessment.needID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !needID.isEmpty,
              session.authoredNeedIDs.contains(needID) else {
            return nil
        }
        return needID
    }

    private func rejectedNeed(_ verdict: ModelVerdict) -> ToolHandlerResult {
        guard let needID = verdict.assessment.needID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !needID.isEmpty else {
            return reject(
                verdict,
                code: ToolRejectionCode.missingNeed,
                message: "The tool call had no need_id."
            )
        }
        return reject(
            verdict,
            code: ToolRejectionCode.notOnList,
            message: "need_id \(needID) is not on mom's list."
        )
    }

    private func reject(_ verdict: ModelVerdict, code: String, message: String) -> ToolHandlerResult {
        ToolHandlerResult(
            verdict: verdict,
            outcome: .rejected(ToolRejection(tool: verdict.tool, code: code, message: message))
        )
    }

    private func accept(_ verdict: ModelVerdict, _ action: AcceptedToolAction) -> ToolHandlerResult {
        ToolHandlerResult(verdict: verdict, outcome: .accepted(action))
    }
}

/// Shared counter for a live client. The 301st reservation throws and no request is sent.
public final class SessionCallBudget: Sendable {
    public let limit: Int
    private let made: Mutex<Int>

    public init(limit: Int = SessionLimits.maxModelCallsPerSession, alreadyMade: Int = 0) {
        self.limit = limit
        made = Mutex(max(0, alreadyMade))
    }

    public var callsCompleted: Int {
        made.withLock { $0 }
    }

    public func reserve() throws {
        try made.withLock { count in
            if count >= limit {
                throw ModelClientError.callBudgetExhausted(limit: limit)
            }
            count += 1
        }
    }
}
