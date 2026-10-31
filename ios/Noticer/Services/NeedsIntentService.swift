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

        var id: UUID {
            switch self {
            case .her(let id, _), .readBack(let id, _, _, _, _, _), .question(let id, _, _):
                return id
            }
        }
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

    private var lastMessage: String?
    private var removed: (need: Need, index: Int)?

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
        entries.append(.her(id: UUID(), text: message))
        lastMessage = message
        offline = false
        needsKey = false
        failureDetail = nil
        thinking = true
        Task {
            await interpret(message: message, model: model)
        }
    }

    func retry(model: PhoneSessionModel) {
        guard let lastMessage, !thinking else {
            return
        }
        offline = false
        needsKey = false
        failureDetail = nil
        thinking = true
        Task {
            await interpret(message: lastMessage, model: model)
        }
    }

    private func interpret(message: String, model: PhoneSessionModel) async {
        let client = NeedsIntentClient(apiKey: ModelKeyStore.currentKey())
        do {
            let result = try await client.interpret(currentList: model.needs, message: message)
            thinking = false
            lastMessage = nil
            switch result {
            case .needs(let drafts, let readBack):
                let changed = ChangedDrafts.between(drafts: drafts, current: model.needs)
                entries.append(.readBack(
                    id: UUID(),
                    drafts: drafts,
                    readBack: readBack,
                    changed: changed,
                    accepted: false,
                    superseded: false
                ))
            case .question(let question, let suggestions):
                entries.append(.question(id: UUID(), text: question, suggestions: suggestions))
            }
        } catch let error as NeedsIntentError {
            thinking = false
            if case .missingAPIKey = error {
                needsKey = true
            }
            failureDetail = error.description
            offline = true
        } catch is CancellationError {
            thinking = false
        } catch {
            thinking = false
            failureDetail = nil
            offline = true
        }
    }

    // MARK: - Accept

    func accept(entryID: UUID, model: PhoneSessionModel) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return
        }
        guard case .readBack(_, let drafts, _, let changed, false, false) = entries[index] else {
            return
        }
        model.needs = NeedsIntentConversion.toNeeds(drafts, current: model.needs)
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
            removed = (model.needs.remove(at: savedIndex), savedIndex)
            model.commitNeeds()
            markPendingSuperseded()
        } else {
            removed = nil
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
        let need = model.needs.remove(at: savedIndex)
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
        model.needs.insert(removed.need, at: index)
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
