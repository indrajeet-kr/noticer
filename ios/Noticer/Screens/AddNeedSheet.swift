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

            NaturalLanguageComposer(
                text: $draft,
                focused: $composerFocused,
                placeholder: "Tell me in your own words…",
                isSending: service.thinking
            ) {
                send()
            }
            .padding(.horizontal, Theme.Space.s12)
            .padding(.vertical, Theme.Space.s8)
        }
        .ambientScreen()
        .task { service.seedIfNeeded(from: model) }
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
        case .readBack(let id, let drafts, let readBack, let changed, let accepted):
            readBackView(
                id: id,
                drafts: drafts,
                readBack: readBack,
                changed: changed,
                accepted: accepted,
                seeded: service.seededEntryID == id
            )
        case .question(_, let text, let suggestions):
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                SparkBubble(text: text)
                if !suggestions.isEmpty {
                    FlowLayout {
                        ForEach(suggestions, id: \.self) { suggestion in
                            SuggestionChip(text: suggestion) {
                                draft = suggestion
                                send()
                            }
                        }
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
        seeded: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            SparkBubble(text: seeded ? "Your list tonight:" : (accepted ? "Saved:" : "Got it:"))
            if !readBack.isEmpty, !accepted {
                Text(readBack)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
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
            } else if !drafts.isEmpty {
                Button("Looks right") {
                    composerFocused = false
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
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Send

    private func remove(entryID: UUID, draftID: String) {
        composerFocused = false
        withAnimation(Theme.spring) {
            service.removeDraft(entryID: entryID, draftID: draftID, model: model)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }
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
