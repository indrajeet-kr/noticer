import NoticerCore
import SwiftUI

/// Mom's List: her saved needs render immediately as cards — no message
/// needed. Tapping a card opens the detail sheet; "+ Add a need" opens the
/// Add sheet with the same natural-language conversation as before.
struct MomsListView: View {
    @Bindable var model: PhoneSessionModel
    var onWins: () -> Void = {}

    @State private var path = NavigationPath()
    @State private var selected: SheetNeed?
    @State private var showingAdd = false
    @State private var addPrefill = ""
    @State private var savedPulse = 0

    private var service: NeedsIntentService {
        model.intentService
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s16) {
                    header
                    if model.needs.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: Theme.Space.cardGap) {
                            ForEach(model.needs, id: \.uiID) { need in
                                Button {
                                    selected = SheetNeed(need: need)
                                } label: {
                                    NeedCard(need: need, isPaused: model.isPaused(need.id))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    pauseButton(for: need)
                                    Button("Change in words") {
                                        openAdd(prefill: changePrefill(for: need))
                                    }
                                    Button("Remove", role: .destructive) {
                                        service.removeSavedNeed(id: need.id, model: model)
                                    }
                                }
                            }
                        }
                    }
                    Button("+ Add a need") {
                        openAdd(prefill: "")
                    }
                    .buttonStyle(.primaryCapsule)
                }
                .screenMargins()
                .padding(.top, Theme.Space.s16)
                .padding(.bottom, Theme.Space.s32)
            }
            .contentMargins(.bottom, 96, for: .scrollContent)
            .ambientScreen()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    TabTopMenu(onWins: onWins) { destination in
                        path.append(destination)
                    }
                }
            }
            .tabMenuDestinations(model: model)
            .task { service.seedIfNeeded(from: model) }
            .overlay(alignment: .top) { toast }
            .sensoryFeedback(.success, trigger: savedPulse)
            .sheet(item: $selected) { sheet in
                NeedDetailView(model: model, need: sheet.need)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingAdd) {
                AddNeedSheet(model: model, initialText: addPrefill) {
                    showingAdd = false
                    savedPulse += 1
                }
            }
        }
    }

    // MARK: - Header and states

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text("Her list")
                .font(Theme.Font.display)
            Text(ListHeader.title(count: model.needs.count))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        GlassCard {
            Text("Tell us one thing that would help her.")
                .font(Theme.Font.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func pauseButton(for need: Need) -> some View {
        Button(model.isPaused(need.id) ? "Resume" : "Pause tonight") {
            model.setPaused(need.id, paused: !model.isPaused(need.id))
        }
    }

    private func changePrefill(for need: Need) -> String {
        let words = need.authorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "About “\(words.isEmpty ? need.id : words)”: "
    }

    private func openAdd(prefill: String) {
        addPrefill = prefill
        showingAdd = true
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
                    .foregroundStyle(Theme.sageStrong)
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
}

private struct SheetNeed: Identifiable {
    var need: Need
    var id: UUID { need.uiID }
}

#Preview("Her list") {
    MomsListView(model: PhoneSessionModel())
}

#Preview("Her list (night, AX)") {
    MomsListView(model: PhoneSessionModel())
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}
