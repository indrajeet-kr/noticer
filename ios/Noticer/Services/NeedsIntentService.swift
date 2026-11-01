import Foundation
import NoticerCore

/// Mom's-list conversation state. Sends her words through `NeedsIntentClient`,
/// shows Spark's read-back cards or one clarifying question, and writes the
/// accepted list into the existing model's `needs`. Engine logic untouched:
/// this only replaces the authored list, like the old editor did.
@MainActor
@Observable
final class NeedsIntentService {
    enum Entry: Identifiable {
        case her(id: UUID, text: String)
        case readBack(
            id: UUID,
            drafts: [NeedsIntentDraft],
            readBack: String,
            changed: Set<String>,
            accepted: Bool,
            superseded: Bool
        )
        case question(id: UUID, text: String, suggestions: [String])
        /// App-owned full-list question. Chips carry need ids (plus Keep);
        /// nothing is added until she picks.
        case swapQuestion(id: UUID, text: String, newText: String, candidates: [NeedListEdit.SwapCandidate])

        var id: UUID {
            switch self {
            case .her(let id, _), .readBack(let id, _, _, _, _, _),
                 .question(let id, _, _), .swapQuestion(let id, _, _, _):
                return id
            }
        }
    }

    /// Where a turn goes. Pure so tests pin it without networking.
    enum Route: Equatable {
        case swapAnswer
        case swapQuestion
        case model
    }

    static func route(
        message: String,
        needsCount: Int,
        pendingSwap: Bool,
        lastEntryIsOpenQuestion: Bool
    ) -> Route {
        if pendingSwap {
            return .swapAnswer
        }
        if needsCount >= SessionLimits.maxAuthoredNeeds,
           !NeedListEdit.isEditMessage(message),
           !lastEntryIsOpenQuestion {
            return .swapQuestion
        }
        return .model
    }

    /// What a model `.needs` turn becomes: a guarded read-back, or the
    /// app-owned swap question when the model tried to add past a full list.
    enum NeedsEntryAction: Equatable {
        case readBack([NeedsIntentDraft])
        case swap(String)
    }

    static func needsEntryAction(
        drafts: [NeedsIntentDraft],
        message: String,
        current: [Need],
        explicit: Set<String>
    ) -> NeedsEntryAction {
        let merged = NeedListEdit.merge(
            current: current,
            drafts: drafts,
            message: message,
            explicitRemovals: explicit
        )
        if NeedListEdit.isFull(current) {
            let currentIDs = Set(current.map(\.id))
            let mergedIDs = Set(merged.map(\.id))
            let ids = current.map(\.id)
            for draft in drafts {
                let id = NeedsIntentSlug.repair(draft.id, against: ids)
                if !currentIDs.contains(id), !mergedIDs.contains(id) {
                    return .swap(draft.authorText)
                }
            }
        }
        return .readBack(NeedsIntentConversion.fromNeeds(merged))
    }

    var entries: [Entry] = []
    var thinking = false
    /// Non-nil while the offline banner shows.
    var offline = false
    /// True when the failure is a missing key, so the banner can say so.
    var needsKey = false
    /// Why the last turn failed, when Spark answered with an error instead of a list.
    var failureDetail: String?
    /// Toast text, e.g. after save or remove-with-undo.
    var notice: String?
    /// True when the toast carries an Undo action.
    var noticeHasUndo = false
    /// Fresh id per toast: two identical texts in a row still restart the timer.
    var noticeID = UUID()
    /// The seeded "Your list tonight" entry, while it is still the live list.
    /// Cleared when she accepts a newer list.
    var seededEntryID: UUID?

    private enum LastAction: Equatable {
        case modelTurn(String)
        case structureSwap(newText: String, pickID: String)
    }

    private var lastAction: LastAction?
    private var removed: (need: Need, index: Int)?
    /// Her new-need text while the app-owned swap question is open.
    private(set) var pendingSwapText: String?
    /// Swap picks: the only ids a merge may drop without her naming them.
    private(set) var pendingExplicitRemovals: Set<String> = []
    /// Test seam: when set, turns call this instead of the live client.
    var interpretHook: (([Need], String) async throws -> NeedsIntentResult)?

    var hasConversation: Bool {
        !entries.isEmpty
    }

    // MARK: - Seed

    /// Shows the saved or default list on open. One accepted card, no send
    /// needed; later turns supersede it but never rewrite it.
    func seedIfNeeded(from model: PhoneSessionModel) {
        guard entries.isEmpty, !model.needs.isEmpty else { return }
        let id = UUID()
        seededEntryID = id
        entries = [.readBack(
            id: id,
            drafts: NeedsIntentConversion.fromNeeds(model.needs),
            readBack: "",
            changed: [],
            accepted: true,
            superseded: false
        )]
    }

    /// Rebuilds the seeded "current list" entry from the screen's list, so a
    /// removal outside the sheet never leaves the sheet showing a stale list.
    /// Called each time the sheet opens. When a newer accepted list already
    /// superseded the seed, there is nothing to rebuild.
    func refreshSheetList(from model: PhoneSessionModel) {
        if entries.isEmpty {
            seedIfNeeded(from: model)
            return
        }
        guard let seed = seededEntryID,
              let index = entries.firstIndex(where: { $0.id == seed }),
              case .readBack = entries[index]
        else {
            return
        }
        entries[index] = .readBack(
            id: seed,
            drafts: NeedsIntentConversion.fromNeeds(model.needs),
            readBack: "",
            changed: [],
            accepted: true,
            superseded: false
        )
    }

    /// Marks every pending (unaccepted) read-back as superseded: the list
    /// changed outside the chat, so those drafts no longer apply. Called on
    /// remove, undo, pause, and after an accept lands a different entry.
    func markPendingSuperseded(except keepID: UUID? = nil) {
        for (index, entry) in entries.enumerated() {
            guard case .readBack(let id, let drafts, let readBack, let changed, false, _) = entry,
                  id != keepID
            else {
                continue
            }
            entries[index] = .readBack(
                id: id,
                drafts: drafts,
                readBack: readBack,
                changed: changed,
                accepted: false,
                superseded: true
            )
        }
    }

    /// Remove is offered only on the live list: the seeded card, or the
    /// latest read-back. Older accepted cards are history; touching them
    /// must not mutate `model.needs`.
    func canRemove(entryID: UUID) -> Bool {
        if entryID == seededEntryID {
            return true
        }
        let latest = entries.compactMap { entry -> UUID? in
            if case .readBack(let id, _, _, _, _, _) = entry {
                return id
            }
            return nil
        }.last
        return entryID == latest
    }

    private func postNotice(_ text: String, undo: Bool) {
        notice = text
        noticeHasUndo = undo
        noticeID = UUID()
    }

    // MARK: - Send

    func send(_ text: String, model: PhoneSessionModel) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !thinking else {
            return
        }
        let route = Self.route(
            message: message,
            needsCount: model.needs.count,
            pendingSwap: pendingSwapText != nil,
            lastEntryIsOpenQuestion: isOpenQuestion(entries.last)
        )
        entries.append(.her(id: UUID(), text: message))
        model.sessionLog.appendActivity(
            "CONV",
            ActivityConversation.herLine(text: message, source: lastSource.rawValue)
        )
        offline = false
        needsKey = false
        failureDetail = nil
        switch route {
        case .swapAnswer:
            lastAction = nil
            handleSwapAnswer(message, model: model)
        case .swapQuestion:
            lastAction = nil
            showSwapQuestion(newText: message, model: model)
        case .model:
            lastAction = .modelTurn(message)
            thinking = true
            Task {
                await interpret(message: message, model: model)
            }
        }
    }

    /// An unanswered model question with chips: her next text answers it,
    /// so it goes to the model, never the swap flow.
    private func isOpenQuestion(_ entry: Entry?) -> Bool {
        guard case .question(_, _, let suggestions) = entry else {
            return false
        }
        return !suggestions.isEmpty
    }

    func retry(model: PhoneSessionModel) {
        guard !thinking else {
            return
        }
        switch lastAction {
        case .modelTurn(let message):
            offline = false
            needsKey = false
            failureDetail = nil
            thinking = true
            Task {
                await interpret(message: message, model: model)
            }
        case .structureSwap(let newText, let pickID):
            offline = false
            needsKey = false
            failureDetail = nil
            thinking = true
            Task {
                await structureNewNeed(newText: newText, pickID: pickID, model: model)
            }
        case nil:
            return
        }
    }

    func interpret(message: String, model: PhoneSessionModel) async {
        do {
            let result: NeedsIntentResult
            if let hook = interpretHook {
                result = try await hook(model.needs, message)
            } else {
                result = try await NeedsIntentClient(apiKey: ModelKeyStore.currentKey())
                    .interpret(currentList: model.needs, message: message)
            }
            thinking = false
            lastAction = nil
            switch result {
            case .needs(let drafts, let readBack):
                model.sessionLog.appendActivity(
                    "CONV",
                    ActivityConversation.replyNeedsLine(count: drafts.count, readBack: readBack)
                )
                let currentIDs = model.needs.map(\.id)
                let modelIDs = Set(drafts.map { NeedsIntentSlug.repair($0.id, against: currentIDs) })
                for blocked in NeedListEdit.blockedRemovals(
                    current: model.needs,
                    modelIDs: modelIDs,
                    message: message,
                    explicitRemovals: pendingExplicitRemovals
                ) {
                    model.sessionLog.appendActivity("CONV", "removal-blocked id=\(blocked.id) reason=no-edit-intent")
                }
                switch Self.needsEntryAction(
                    drafts: drafts,
                    message: message,
                    current: model.needs,
                    explicit: pendingExplicitRemovals
                ) {
                case .readBack(let guarded):
                    let changed = ChangedDrafts.between(drafts: guarded, current: model.needs)
                    entries.append(.readBack(
                        id: UUID(),
                        drafts: guarded,
                        readBack: readBack,
                        changed: changed,
                        accepted: false,
                        superseded: false
                    ))
                case .swap(let newText):
                    showSwapQuestion(newText: newText, model: model)
                }
                pendingExplicitRemovals = []
            case .question(let question, let suggestions):
                model.sessionLog.appendActivity(
                    "CONV",
                    ActivityConversation.replyQuestionLine(question: question, chips: suggestions)
                )
                pendingExplicitRemovals = []
                entries.append(.question(id: UUID(), text: question, suggestions: suggestions))
            }
        } catch {
            failInterpret(error, model: model)
        }
    }

    private func failInterpret(_ error: Error, model: PhoneSessionModel) {
        thinking = false
        if let error = error as? NeedsIntentError {
            if case .missingAPIKey = error {
                needsKey = true
            }
            failureDetail = error.description
            offline = true
            model.sessionLog.appendActivity("CONV", "turn failed: \(error.description)")
        } else if error is CancellationError {
            return
        } else {
            failureDetail = nil
            offline = true
            model.sessionLog.appendActivity("CONV", "turn failed: request failed (\(error.localizedDescription))")
        }
    }

    // MARK: - Swap flow (full list)

    /// App-owned full-list question. Nothing is added until she picks.
    func showSwapQuestion(newText: String, model: PhoneSessionModel) {
        pendingSwapText = newText
        model.sessionLog.appendActivity("CONV", "limit hit, swap offered for \"\(newText)\"")
        entries.append(.swapQuestion(
            id: UUID(),
            text: NeedListEdit.swapQuestion(newText: newText),
            newText: newText,
            candidates: NeedListEdit.swapCandidates(for: model.needs)
        ))
    }

    /// Her typed answer while a swap is pending: keep-all backs out, a
    /// named need confirms the swap, anything else re-asks with fresh chips.
    /// No model call: the answer resolves locally or not at all.
    func handleSwapAnswer(_ message: String, model: PhoneSessionModel) {
        guard let newText = pendingSwapText else {
            return
        }
        if NeedListEdit.isKeepAllAnswer(message) {
            appendKeepAllConfirmation(model: model)
            return
        }
        if let pick = NeedListEdit.resolveNamedNeed(message: message, in: model.needs) {
            confirmSwap(pickID: pick.id, model: model)
            return
        }
        entries.append(.swapQuestion(
            id: UUID(),
            text: NeedListEdit.swapReaskQuestion(newText: newText),
            newText: newText,
            candidates: NeedListEdit.swapCandidates(for: model.needs)
        ))
    }

    /// Swap chip tap: her explicit pick. Structures the new need with an
    /// empty list (the model never sees the saved six, so it can't rewrite
    /// them), then swaps it into the picked slot.
    func chooseSwap(candidateID: String, model: PhoneSessionModel) {
        guard let newText = pendingSwapText, !thinking else {
            return
        }
        guard let pick = model.needs.first(where: { $0.id == candidateID }) else {
            entries.append(.swapQuestion(
                id: UUID(),
                text: NeedListEdit.swapReaskQuestion(newText: newText),
                newText: newText,
                candidates: NeedListEdit.swapCandidates(for: model.needs)
            ))
            return
        }
        entries.append(.her(id: UUID(), text: "Swap out \(NeedListEdit.shortName(for: pick))"))
        confirmSwap(pickID: candidateID, model: model)
    }

    func confirmSwap(pickID: String, model: PhoneSessionModel) {
        guard let newText = pendingSwapText else {
            return
        }
        model.sessionLog.appendActivity("CONV", "swap chosen pick=\(pickID)")
        pendingExplicitRemovals = [pickID]
        lastAction = .structureSwap(newText: newText, pickID: pickID)
        thinking = true
        Task {
            await structureNewNeed(newText: newText, pickID: pickID, model: model)
        }
    }

    func structureNewNeed(newText: String, pickID: String, model: PhoneSessionModel) async {
        do {
            let result: NeedsIntentResult
            if let hook = interpretHook {
                result = try await hook([], newText)
            } else {
                result = try await NeedsIntentClient(apiKey: ModelKeyStore.currentKey())
                    .interpret(currentList: [], message: newText)
            }
            thinking = false
            lastAction = nil
            switch result {
            case .needs(let drafts, _):
                model.sessionLog.appendActivity("CONV", "structured \(drafts.count) draft(s) for swap")
                applyStructuredSwap(drafts: drafts, pickID: pickID, model: model)
            case .question(let question, let suggestions):
                model.sessionLog.appendActivity(
                    "CONV",
                    ActivityConversation.replyQuestionLine(question: question, chips: suggestions)
                )
                pendingSwapText = nil
                pendingExplicitRemovals = []
                entries.append(.question(id: UUID(), text: question, suggestions: suggestions))
            }
        } catch {
            failInterpret(error, model: model)
        }
    }

    /// Sync seam: swaps the first structured draft into the picked slot and
    /// shows the normal read-back. Empty drafts keep the pending swap and
    /// ask again.
    func applyStructuredSwap(drafts: [NeedsIntentDraft], pickID: String, model: PhoneSessionModel) {
        let converted = NeedsIntentConversion.toNeeds(drafts, current: model.needs)
        guard let first = converted.first, pendingSwapText != nil else {
            entries.append(.question(id: UUID(), text: NeedReplyText.fallbackQuestion, suggestions: []))
            return
        }
        let merged = NeedListEdit.applySwap(current: model.needs, removeID: pickID, newNeed: first)
        let old = model.needs.first { $0.id == pickID }
        let entryDrafts = NeedsIntentConversion.fromNeeds(merged)
        let changed = ChangedDrafts.between(drafts: entryDrafts, current: model.needs)
        entries.append(.readBack(
            id: UUID(),
            drafts: entryDrafts,
            readBack: swapReadBack(old: old, newText: first.authorText),
            changed: changed,
            accepted: false,
            superseded: false
        ))
        pendingSwapText = nil
        pendingExplicitRemovals = []
    }

    private func swapReadBack(old: Need?, newText: String) -> String {
        let oldWords = old.map {
            let words = $0.authorText.trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? $0.id : words
        } ?? "that one"
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Swapped “\(oldWords)” for “\(trimmed.isEmpty ? "the new need" : trimmed)”."
    }

    /// "Keep all 6" chip: discards the new need, leaves the list unchanged.
    func keepAll(model: PhoneSessionModel) {
        guard pendingSwapText != nil, !thinking else {
            return
        }
        entries.append(.her(id: UUID(), text: NeedListEdit.keepAllChip()))
        appendKeepAllConfirmation(model: model)
    }

    private func appendKeepAllConfirmation(model: PhoneSessionModel) {
        model.sessionLog.appendActivity("CONV", "swap declined (keep all)")
        entries.append(.question(id: UUID(), text: NeedListEdit.keepAllConfirmation(), suggestions: []))
        pendingSwapText = nil
        pendingExplicitRemovals = []
    }

    // MARK: - Accept

    func accept(entryID: UUID, model: PhoneSessionModel) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return
        }
        guard case .readBack(_, let drafts, _, let changed, false, false) = entries[index] else {
            return
        }
        let before = model.needs
        let converted = NeedsIntentConversion.toNeeds(drafts, current: model.needs)
        logDiff(old: before, new: converted, cause: "looks-right", source: lastSource, model: model)
        model.sessionLog.appendActivity(
            "CONV",
            "looks-right accepted source=\(lastSource.rawValue) n=\(converted.count)"
        )
        model.needs = converted
        model.commitNeeds()
        entries[index] = .readBack(
            id: entryID,
            drafts: drafts,
            readBack: "",
            changed: changed,
            accepted: true,
            superseded: false
        )
        if seededEntryID != entryID {
            seededEntryID = nil
        }
        markPendingSuperseded(except: entryID)
        postNotice("Saved. He'll get a head start on these.", undo: false)
    }

    // MARK: - Remove with undo (accessibility shortcut; voice is primary)

    func removeDraft(entryID: UUID, draftID: String, model: PhoneSessionModel) {
        guard canRemove(entryID: entryID) else {
            return
        }
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return
        }
        guard case .readBack(_, var drafts, let readBack, var changed, let accepted, let superseded) = entries[index] else {
            return
        }
        guard let draftIndex = drafts.firstIndex(where: { $0.id == draftID }) else {
            return
        }
        let draft = drafts.remove(at: draftIndex)
        changed.remove(draftID)
        entries[index] = .readBack(
            id: entryID,
            drafts: drafts,
            readBack: readBack,
            changed: changed,
            accepted: accepted,
            superseded: superseded
        )
        if accepted, let savedIndex = model.needs.firstIndex(where: { $0.id == draftID }) {
            let before = model.needs
            removed = (model.needs.remove(at: savedIndex), savedIndex)
            logDiff(old: before, new: model.needs, cause: "remove-card", model: model)
            model.commitNeeds()
            markPendingSuperseded()
        } else {
            removed = nil
            model.sessionLog.appendActivity("CONV", ActivityConversation.draftDiscardedLine(id: draftID))
        }
        // Pending read-backs re-derive from her words; nothing to undo.
        postNotice("Removed “\(draft.authorText)”.", undo: accepted)
    }

    /// Removes a saved need straight from the list (the card detail
    /// sheet), keeping any live accepted read-back in sync and offering the
    /// same undo toast as the composer flow.
    func removeSavedNeed(id: String, model: PhoneSessionModel) {
        for (index, entry) in entries.enumerated() {
            guard case .readBack(let entryID, var drafts, let readBack, var changed, true, _) = entry,
                  canRemove(entryID: entryID),
                  let draftIndex = drafts.firstIndex(where: { $0.id == id })
            else {
                continue
            }
            let draft = drafts.remove(at: draftIndex)
            changed.remove(draft.id)
            entries[index] = .readBack(
                id: entryID,
                drafts: drafts,
                readBack: readBack,
                changed: changed,
                accepted: true,
                superseded: false
            )
        }
        guard let savedIndex = model.needs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let before = model.needs
        let need = model.needs.remove(at: savedIndex)
        logDiff(old: before, new: model.needs, cause: "remove", model: model)
        model.commitNeeds()
        markPendingSuperseded()
        removed = (need, savedIndex)
        let words = need.authorText.trimmingCharacters(in: .whitespacesAndNewlines)
        postNotice(words.isEmpty ? "Removed." : "Removed “\(words)”.", undo: true)
    }

    func undoRemove(model: PhoneSessionModel) {
        guard let removed else {
            notice = nil
            noticeHasUndo = false
            return
        }
        let index = min(removed.index, model.needs.count)
        let before = model.needs
        model.needs.insert(removed.need, at: index)
        logDiff(old: before, new: model.needs, cause: "undo", model: model)
        model.commitNeeds()
        markPendingSuperseded()
        self.removed = nil
        notice = nil
        noticeHasUndo = false
    }

    func dismissNotice() {
        notice = nil
        noticeHasUndo = false
    }

    // MARK: - Activity source and list diffs

    /// Where the latest turn came from. The sheet notes it at send time so
    /// Looks-right lines can say typed, voice, or chip tap.
    private(set) var lastSource: ListEditSource = .typed

    func noteSendSource(_ source: ListEditSource) {
        lastSource = source
    }

    private func logDiff(
        old: [Need],
        new: [Need],
        cause: String,
        source: ListEditSource? = nil,
        model: PhoneSessionModel
    ) {
        let rows = { (needs: [Need]) in
            needs.map { NeedListDiff.Row(need: $0, paused: model.isPaused($0.id)) }
        }
        for line in NeedListDiff.lines(old: rows(old), new: rows(new), cause: cause, source: source?.rawValue) {
            model.sessionLog.appendActivity("LIST", line)
        }
    }
}

/// Ids that are new or whose wording changed, for the "Updated" chip.
/// Drafts compare against their repaired match, so a typo'd id that snaps
/// back to its need doesn't flash "Updated" for nothing.
enum ChangedDrafts {
    static func between(drafts: [NeedsIntentDraft], current: [Need]) -> Set<String> {
        let existing = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let currentIDs = current.map(\.id)
        var changed: Set<String> = []
        for draft in drafts {
            let matchID = NeedsIntentSlug.repair(draft.id, against: currentIDs)
            guard let old = existing[matchID] else {
                changed.insert(draft.id)
                continue
            }
            if old.authorText != draft.authorText
                || old.cueWording != draft.whisper
                || old.priority != draft.priority.needPriority
                || old.allowsCheckIn != draft.allowsCheckIn {
                changed.insert(draft.id)
            }
        }
        return changed
    }
}
