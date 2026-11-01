import NoticerCore
import SwiftUI

/// Need detail: her words large, what he'll hear, timing in words, the
/// priority word, and Pause / Change / Remove. Opens from a card tap.
struct NeedDetailView: View {
    @Bindable var model: PhoneSessionModel
    var need: Need
    @Environment(\.dismiss) private var dismiss
    @State private var showingChange = false

    private var service: NeedsIntentService {
        model.intentService
    }

    private var paused: Bool {
        model.isPaused(need.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    Text(displayWords)
                        .font(Theme.Font.title)
                    Text("He'll hear: “\(cueWords)”")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .padding(.top, Theme.Space.s16)

                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text(timing.main)
                        .font(Theme.Font.body)
                    if let detail = timing.detail {
                        Text(detail)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Button {
                        model.sessionLog.appendActivity("UI", "priority tapped id=\(liveNeed.id)")
                        model.setUrgent(liveNeed.id, urgent: !liveNeed.isUrgent)
                    } label: {
                        PriorityChip(
                            priority: NeedsIntentPriority.word(forNeedPriority: liveNeed.priority),
                            urgent: liveNeed.isUrgent
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        liveNeed.isUrgent
                            ? "Priority Urgent. Tap to change priority."
                            : "Priority \(priorityWord). Tap to change priority."
                    )
                    Text("Tap to change priority")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                VStack(spacing: Theme.Space.s12) {
                    Button(paused ? "Resume" : "Pause tonight") {
                        model.sessionLog.appendActivity("UI", "\(!paused ? "pause" : "resume") tapped id=\(need.id)")
                        model.setPaused(need.id, paused: !paused)
                    }
                    .buttonStyle(.primaryCapsule)

                    Button("Change in words") {
                        model.sessionLog.appendActivity("UI", "change-in-words tapped id=\(need.id)")
                        showingChange = true
                    }
                    .buttonStyle(.ghostCapsule)

                    Button("Remove", role: .destructive) {
                        model.sessionLog.appendActivity("UI", "remove tapped id=\(need.id)")
                        service.removeSavedNeed(id: need.id, model: model)
                        dismiss()
                    }
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
                }
                .padding(.top, Theme.Space.s8)
            }
            .screenMargins()
            .padding(.bottom, Theme.Space.s32)
        }
        .ambientScreen()
        .sheet(isPresented: $showingChange) {
            AddNeedSheet(model: model, initialText: "About “\(displayWords)”: ") {
                showingChange = false
                dismiss()
            }
        }
    }

    private var displayWords: String {
        let words = need.authorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? need.id : words
    }

    private var cueWords: String {
        let spoken = SpokenCueForm.line(cueWording: need.cueWording, authorText: need.authorText)
        return spoken.isEmpty ? displayWords : spoken
    }

    private var timing: (main: String, detail: String?) {
        TimingWords.headStartSentence(seconds: model.displayHeadStart(for: liveNeed))
    }

    /// The saved row, so the pill and timing follow the toggle. Falls back
    /// to the passed need if the row is gone.
    private var liveNeed: Need {
        model.needs.first { $0.id == need.id } ?? need
    }

    private var priorityWord: String {
        switch NeedsIntentPriority.word(forNeedPriority: liveNeed.priority) {
        case .gentle: return "Gentle"
        case .normal: return "Normal"
        case .important: return "Important"
        }
    }
}

#Preview("Need detail") {
    NeedDetailView(
        model: PhoneSessionModel(),
        need: Need(
            id: "refill-water",
            authorText: "nursing, no water",
            cueWording: "Her water's empty.",
            priority: 1
        )
    )
}

#Preview("Need detail (night, AX)") {
    NeedDetailView(
        model: PhoneSessionModel(),
        need: Need(
            id: "take-baby",
            authorText: "eating one-handed, take the baby",
            cueWording: "Her plate's getting cold, maybe take the baby?",
            priority: 0
        )
    )
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
