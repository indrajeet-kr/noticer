import NoticerCore
import SwiftUI

/// Add a need: a bottom sheet with a single free-text input, docked
/// Oura-Advisor style. Spark's parsed result reads back as cards above the
/// input; "Looks right" saves and closes. No form fields, ever.
struct AddNeedSheet: View {
    @Bindable var model: PhoneSessionModel
    var initialText: String = ""
    var onAccept: () -> Void

    @State private var draft: String
    @FocusState private var composerFocused: Bool
    @Namespace private var cards
    @State private var showingKey = false
    @State private var dictation = DictationService()

    private var service: NeedsIntentService {
        model.intentService
    }

    init(model: PhoneSessionModel, initialText: String = "", onAccept: @escaping () -> Void) {
        self.model = model
        self.initialText = initialText
        self.onAccept = onAccept
        _draft = State(initialValue: initialText)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add a need")
                .font(Theme.Font.headline)
                .padding(.top, Theme.Space.s12)
                .padding(.bottom, Theme.Space.s8)
                .accessibilityAddTraits(.isHeader)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s16) {
                        if service.entries.isEmpty, !service.thinking {
                            SparkBubble(text: "Say what would help, in your own words. We'll read it back before saving.")
                        }
                        ForEach(service.entries) { entry in
                            entryView(entry)
                        }
                        if service.thinking {
                            thinkingBubble
                        }
                        if service.offline {
                            offlineSection
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .screenMargins()
                    .padding(.vertical, Theme.Space.s16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: scrollToken) { _, _ in
                    withAnimation(Theme.gentle) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            if let notice = dictation.notice {
                Text(notice)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.s16)
            }
            NaturalLanguageComposer(
                text: $draft,
                focused: $composerFocused,
                placeholder: "Tell me in your own words…",
                isSending: service.thinking,
                dictation: dictation
            ) {
                send()
            }
            .padding(.horizontal, Theme.Space.s12)
            .padding(.vertical, Theme.Space.s8)
        }
        .ambientScreen()
        .task { service.refreshSheetList(from: model) }
        .onAppear {
            dictation.sessionRunning = model.isRunning
            dictation.noteHandler = { [model] notice in
                model.sessionLog.appendActivity("ERROR", "speech \(notice)")
            }
            dictation.logHandler = { [model] tag, message in
                model.sessionLog.appendActivity(tag, message)
            }
            model.sessionLog.appendActivity("UI", "add-sheet opened")
        }
        .onDisappear {
            dictation.stop()
            model.sessionLog.appendActivity("UI", "add-sheet closed")
        }
        .onChange(of: model.isRunning) { _, running in
            dictation.sessionRunning = running
        }
        .onChange(of: dictation.transcript) { _, transcript in
            if !transcript.isEmpty {
                draft = transcript
            }
        }
        .sheet(isPresented: $showingKey) {
            NavigationStack {
                APIKeyStep(model: model) {
                    showingKey = false
                }
                .screenMargins()
                .padding(.bottom, Theme.Space.s24)
                .ambientScreen()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showingKey = false }
                    }
                }
            }
        }
    }

    // MARK: - States

    private var thinkingBubble: some View {
        HStack(spacing: Theme.Space.s8) {
            ThinkingDots()
                .padding(Theme.Space.s12)
                .background(Theme.bgSubtle)
                .clipShape(Theme.Radius.rect(Theme.Radius.row))
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var offlineSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            OfflineBanner {
                service.retry(model: model)
            }
            if let detail = service.failureDetail {
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if service.needsKey {
                Button("Add your Meta API key") {
                    showingKey = true
                }
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.sageStrong)
            }
        }
    }

    private var scrollToken: String {
        "\(service.entries.count)-\(service.thinking)-\(service.offline)"
    }

    // MARK: - Entries

    @ViewBuilder
    private func entryView(_ entry: NeedsIntentService.Entry) -> some View {
        switch entry {
        case .her(_, let text):
            HStack {
                Spacer()
                Text(text)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.onSage)
                    .padding(Theme.Space.s12)
                    .background(Theme.sage)
                    .clipShape(Theme.Radius.rect(Theme.Radius.row))
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case .readBack(let id, let drafts, let readBack, let changed, let accepted, let superseded):
            readBackView(
                id: id,
                drafts: drafts,
                readBack: readBack,
                changed: changed,
                accepted: accepted,
                superseded: superseded,
                seeded: service.seededEntryID == id
            )
        case .question(_, let text, let suggestions):
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                SparkBubble(text: text)
                if !suggestions.isEmpty {
                    FlowLayout {
                        ForEach(suggestions, id: \.self) { suggestion in
                            SuggestionChip(text: suggestion) {
                                model.sessionLog.appendActivity("CONV", "chip tapped \"\(suggestion)\"")
                                draft = suggestion
                                send(forceSource: .chip)
                            }
                        }
                    }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case .swapQuestion(_, let text, _, let candidates):
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                SparkBubble(text: text)
                FlowLayout {
                    ForEach(candidates, id: \.id) { candidate in
                        SuggestionChip(text: candidate.shortName) {
                            service.noteSendSource(.chip)
                            service.chooseSwap(candidateID: candidate.id, model: model)
                        }
                    }
                    SuggestionChip(text: NeedListEdit.keepAllChip()) {
                        service.noteSendSource(.chip)
                        service.keepAll(model: model)
                    }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func readBackView(
        id: UUID,
        drafts: [NeedsIntentDraft],
        readBack: String,
        changed: Set<String>,
        accepted: Bool,
        superseded: Bool,
        seeded: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            SparkBubble(text: seeded ? "Your list tonight:" : (accepted ? "Saved:" : "Got it:"))
            if !readBack.isEmpty, !accepted {
                Text(readBack)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !accepted, !superseded {
                ForEach(removals(from: drafts), id: \.id) { need in
                    Text("Removing: \(removalWords(for: need))")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.terracottaText)
                }
            }
            if drafts.isEmpty {
                Text("Your list is empty.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(drafts.enumerated()), id: \.element.id) { number, draft in
                    let card = NeedReadBackCard(number: number + 1, draft: draft, changed: changed.contains(draft.id))
                        .matchedGeometryEffect(id: "\(id.uuidString)-\(draft.id)", in: cards)
                    if service.canRemove(entryID: id) {
                        card
                            .contextMenu {
                                Button("Remove", role: .destructive) {
                                    remove(entryID: id, draftID: draft.id)
                                }
                            }
                            .accessibilityAction(named: "Remove") {
                                remove(entryID: id, draftID: draft.id)
                            }
                    } else {
                        card
                    }
                }
            }
            if accepted {
                HStack(spacing: Theme.Space.s4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.sage)
                    Text(seeded ? "Tonight's list" : "Saved")
                        .font(Theme.Font.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, Theme.Space.s4)
            } else if superseded {
                Text("This list changed — send again to update.")
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.Space.s4)
            } else if !drafts.isEmpty {
                Button("Looks right") {
                    composerFocused = false
                    model.sessionLog.appendActivity("UI", "looks-right tapped")
                    service.accept(entryID: id, model: model)
                    onAccept()
                }
                .buttonStyle(.primaryCapsule)
                .padding(.top, Theme.Space.s8)
                Text("Want to change something? Just say it — “make water higher priority”, “remove the water one”.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .opacity(superseded && !accepted ? 0.55 : 1)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Send

    /// Saved needs the pending list drops: exactly what Looks right will
    /// remove. Blocked removals stay in the drafts, so they never show here.
    private func removals(from drafts: [NeedsIntentDraft]) -> [Need] {
        NeedListEdit.removedNeeds(current: model.needs, mergedIDs: Set(drafts.map(\.id)))
    }

    private func removalWords(for need: Need) -> String {
        let words = need.authorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? need.id : words
    }

    private func remove(entryID: UUID, draftID: String) {
        composerFocused = false
        withAnimation(Theme.spring) {
            service.removeDraft(entryID: entryID, draftID: draftID, model: model)
        }
    }

    private func send(forceSource: ListEditSource? = nil) {
        dictation.stop()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }
        let dictated = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        service.noteSendSource(forceSource ?? ((!dictated.isEmpty && text == dictated) ? .voice : .typed))
        draft = ""
        withAnimation(Theme.spring) {
            service.send(text, model: model)
        }
    }
}

#Preview("Add need") {
    AddNeedSheet(model: PhoneSessionModel()) {}
}

#Preview("Add need (night, AX)") {
    AddNeedSheet(model: PhoneSessionModel()) {}
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}
