import SwiftUI

/// Settings without a settings form: one Ask composer, the same component
/// as Mom's List. She or he says what should change ("use shorter head
/// starts tonight", "pause check-ins"); the app reads back one calm card
/// with an Accept button. Anything unmappable gets one clarifying question.
struct AskSettingsView: View {
    @Bindable var model: PhoneSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var readBack: AskReadBack?
    @State private var question: String?
    @State private var acceptedPulse = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s16) {
                        VStack(alignment: .leading, spacing: Theme.Space.s4) {
                            Text("Ask")
                                .font(Theme.Font.statusWord)
                            Text("Say what should change tonight. In your own words.")
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.top, Theme.Space.s16)

                        if let readBack {
                            readBackCard(readBack)
                        } else if let question {
                            SparkBubble(text: question)
                        } else {
                            GlassCard {
                                Text("Try “use shorter head starts tonight” or “pause check-ins”.")
                                    .font(Theme.Font.body)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .screenMargins()
                    .padding(.bottom, Theme.Space.s16)
                }
                .scrollDismissesKeyboard(.interactively)

                NaturalLanguageComposer(
                    text: $draft,
                    focused: $composerFocused,
                    placeholder: "e.g. Use shorter head starts tonight…"
                ) {
                    send()
                }
                .padding(.horizontal, Theme.Space.s12)
                .padding(.vertical, Theme.Space.s8)
            }
            .ambientScreen()
            .sensoryFeedback(.success, trigger: acceptedPulse)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func readBackCard(_ readBack: AskReadBack) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            GlassCard {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    Text("Got it:")
                        .font(Theme.Font.headline)
                    Text(readBack.text)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if readBack.accepted {
                HStack(spacing: Theme.Space.s4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.gotIt)
                    Text("On it.")
                        .font(Theme.Font.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Button("Accept") {
                    accept(readBack)
                }
                .buttonStyle(.primaryCapsule)
                .padding(.top, Theme.Space.s8)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }
        draft = ""
        let lower = text.lowercased()
        if asks(lower, anyOf: ["pause", "stop", "turn off"], allOf: ["check-in", "check in", "checkin", "ask me"]) {
            readBack = AskReadBack(
                text: "He won't check in with you for the rest of tonight. Whispers keep working.",
                change: .checkIns(false)
            )
        } else if asks(lower, anyOf: ["resume", "allow", "turn on", "keep"], allOf: ["check-in", "check in", "checkin"]) {
            readBack = AskReadBack(
                text: "He may check in with you again when a re-check is inconclusive.",
                change: .checkIns(true)
            )
        } else if asks(lower, anyOf: ["shorter", "quick", "faster", "less wait"], allOf: ["head start", "headstart", "timing", "wait"]) {
            readBack = AskReadBack(
                text: "We'll use shorter head starts tonight. Good for trying things out.",
                change: .quickTiming(true)
            )
        } else if asks(lower, anyOf: ["standard", "normal", "longer", "regular", "usual"], allOf: ["head start", "headstart", "timing", "wait"]) {
            readBack = AskReadBack(
                text: "We'll use the standard head starts tonight.",
                change: .quickTiming(false)
            )
        } else {
            readBack = nil
            question = "Do you want shorter head starts, or a change to check-ins?"
        }
        if readBack != nil {
            question = nil
        }
    }

    private func asks(_ text: String, anyOf triggers: [String], allOf topics: [String]) -> Bool {
        triggers.contains(where: text.contains) && topics.contains(where: text.contains)
    }

    private func accept(_ readBack: AskReadBack) {
        switch readBack.change {
        case .quickTiming(let enabled):
            model.setQuickTiming(enabled)
        case .checkIns(let allowed):
            for index in model.needs.indices {
                model.needs[index].allowsCheckIn = allowed
            }
            model.saveNeeds()
        }
        self.readBack = AskReadBack(text: readBack.text, change: readBack.change, accepted: true)
        acceptedPulse += 1
    }
}

private struct AskReadBack: Equatable {
    enum Change: Equatable {
        case quickTiming(Bool)
        case checkIns(Bool)
    }

    var text: String
    var change: Change
    var accepted = false
}

#Preview("Ask") {
    AskSettingsView(model: PhoneSessionModel())
}

#Preview("Ask (light, AX)") {
    AskSettingsView(model: PhoneSessionModel())
        .preferredColorScheme(.light)
        .dynamicTypeSize(.accessibility5)
}
