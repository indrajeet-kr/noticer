import SwiftUI

/// Mom's List: natural language, no forms. She types or dictates freely in
/// the one composer; Spark's read-back cards appear above it. Refinements go
/// back through the same composer. The only shortcut is long-press Remove on
/// a card (plus an accessibility action), with an undo toast.
struct MomsListView: View {
    @Bindable var model: PhoneSessionModel
    @State private var service = NeedsIntentService()
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @Namespace private var cards
    @State private var savedPulse = 0
    @State private var showingKey = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s16) {
                        header
                        if model.needs.isEmpty, !service.hasConversation, !service.thinking {
                            emptyState
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
                    .padding(.top, Theme.Space.s16)
                    .padding(.bottom, Theme.Space.s16)
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
                placeholder: "e.g. When I'm eating with the baby in one arm, take her so I can eat…",
                isSending: service.thinking
            ) {
                send()
            }
            .padding(.horizontal, Theme.Space.s12)
            .padding(.vertical, Theme.Space.s8)
        }
        .ambientScreen()
        .task { service.seedIfNeeded(from: model) }
        .overlay(alignment: .top) { toast }
        .sensoryFeedback(.success, trigger: savedPulse)
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

    // MARK: - Header and states

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text("Her list")
                .font(Theme.Font.statusWord)
            Text("Just tell us what helps you. In your own words.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        GlassCard {
            VStack(spacing: Theme.Space.s12) {
                StatusOrb(color: Theme.accentWarm, size: 90)
                Text("What would help you tonight?")
                    .font(Theme.Font.headline)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var thinkingBubble: some View {
        HStack(spacing: Theme.Space.s8) {
            ThinkingDots()
                .padding(Theme.Space.s12)
                .background(Theme.bgElevated)
                .clipShape(Theme.Radius.rect(Theme.Radius.row))
            Text("Listening to your list…")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
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
                .foregroundStyle(Theme.accentWarm)
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
                    .foregroundStyle(Theme.onAccentFill)
                    .padding(Theme.Space.s12)
                    .background(Theme.accentFill)
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
                        // Scoped by entry: the same need id can appear in
                        // several read-backs as she refines the list.
                        .matchedGeometryEffect(id: "\(id.uuidString)-\(draft.id)", in: cards)
                    // ScrollView rows can't swipe; long-press plus an
                    // accessibility action instead. Stale cards offer neither.
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
            if accepted, !seeded {
                HStack(spacing: Theme.Space.s4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.gotIt)
                    Text("Saved")
                        .font(Theme.Font.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, Theme.Space.s4)
            } else if !drafts.isEmpty {
                Button("Looks right") {
                    composerFocused = false
                    service.accept(entryID: id, model: model)
                    savedPulse += 1
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

    // MARK: - Toast

    @ViewBuilder
    private var toast: some View {
        if let notice = service.notice {
            HStack(spacing: Theme.Space.s8) {
                Text(notice)
                    .font(Theme.Font.footnote)
                    .lineLimit(2)
                if service.noticeHasUndo {
                    Button("Undo") {
                        service.undoRemove(model: model)
                    }
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.accentWarm)
                }
            }
            .padding(.horizontal, Theme.Space.s16)
            .padding(.vertical, Theme.Space.s12)
            .glassBackground(cornerRadius: 999)
            .padding(.horizontal, Theme.Space.screenMargin)
            .padding(.top, Theme.Space.s8)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .task(id: service.noticeID) {
                try? await Task.sleep(for: .seconds(3))
                service.dismissNotice()
            }
        }
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

#Preview("Her list") {
    MomsListView(model: PhoneSessionModel())
}

#Preview("Her list (light, AX)") {
    MomsListView(model: PhoneSessionModel())
        .preferredColorScheme(.light)
        .dynamicTypeSize(.accessibility5)
}
