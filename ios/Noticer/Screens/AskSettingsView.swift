import NoticerCore
import SwiftUI

/// Settings: Night look, quick timing, API key, and the session log — plus
/// the same natural-language Ask flow as before for "use shorter head
/// starts tonight" style changes. Pushed from the tab menu.
struct AskSettingsView: View {
    @Bindable var model: PhoneSessionModel
    @AppStorage("noticer.appearance.night") private var night = false
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var readBack: AskReadBack?
    @State private var question: String?
    @State private var acceptedPulse = 0
    @State private var showingKey = false
    @State private var showingLog = false
    @State private var confirmingIntro = false
    @State private var confirmingReset = false
    @State private var resetStash: [String: MasteryState]?
    @State private var resetToastID = UUID()
    @State private var dictation = DictationService()
    @AppStorage("noticer.onboarding.done") private var onboardingDone = false
    @AppStorage("noticer.demo.mode") private var demoMode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text("Settings")
                        .font(Theme.Font.display)
                    Text("Say what should change tonight. In your own words.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, Theme.Space.s16)
                .accessibilityElement(children: .combine)

                askSection
                appearanceSection
                sessionSection
                keySection
                logSection
                resetSection
                introSection
            }
            .screenMargins()
            .padding(.bottom, Theme.Space.s32)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            composerFocused = false
            dictation.sessionRunning = model.isRunning
            dictation.noteHandler = { [model] notice in
                model.sessionLog.appendActivity("ERROR", "speech \(notice)")
            }
        }
        .onDisappear { dictation.stop() }
        .onChange(of: night) { old, new in
            model.sessionLog.appendActivity("SETTINGS", "night-look \(old) -> \(new)")
        }
        .onChange(of: demoMode) { old, new in
            model.sessionLog.appendActivity("SETTINGS", "demo-mode \(old) -> \(new)")
        }
        .onChange(of: showingKey) { _, shown in
            model.sessionLog.appendActivity("UI", shown ? "key-sheet opened" : "key-sheet closed")
        }
        .onChange(of: showingLog) { _, shown in
            model.sessionLog.appendActivity("UI", shown ? "log opened" : "log closed")
        }
        .onChange(of: model.isRunning) { _, running in
            dictation.sessionRunning = running
        }
        .onChange(of: dictation.transcript) { _, transcript in
            if !transcript.isEmpty {
                draft = transcript
            }
        }
        .ambientScreen()
        .overlay(alignment: .top) { resetToast }
        .sensoryFeedback(.success, trigger: acceptedPulse)
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
        .sheet(isPresented: $showingLog) {
            SessionLogView(log: model.sessionLog)
        }
        .confirmationDialog(
            "See the introduction again?",
            isPresented: $confirmingIntro,
            titleVisibility: .visible
        ) {
            Button("Start over") {
                restartIntroduction()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Her list and the saved key stay. You'll begin again at the first screen.")
        }
        .confirmationDialog(
            "Reset learning progress?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                resetLearning()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sets every need back to Learning. Tonight's wins stay.")
        }
    }

    private var resetSection: some View {
        GlassCard(padding: Theme.Space.card) {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                Text("Developer")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Reset learning progress", role: .destructive) {
                    confirmingReset = true
                }
                .font(Theme.Font.headline)
                .disabled(model.isRunning)
                Text("Sets every need back to Learning. Tonight's wins stay.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                Toggle("Demo mode", isOn: $demoMode)
                    .font(Theme.Font.headline)
                    .disabled(model.isRunning)
                Text("Shows each step on screen in big type, for screen recordings.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resetLearning() {
        guard let stash = model.resetLearningProgress() else {
            return
        }
        resetStash = stash
        resetToastID = UUID()
    }

    private func undoReset() {
        if let stash = resetStash {
            model.restoreMastery(stash)
        }
        resetStash = nil
    }

    @ViewBuilder
    private var resetToast: some View {
        if resetStash != nil {
            HStack(spacing: Theme.Space.s8) {
                Text("Learning reset.")
                    .font(Theme.Font.footnote)
                Button("Undo") {
                    undoReset()
                }
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.sageStrong)
            }
            .padding(.horizontal, Theme.Space.s16)
            .padding(.vertical, Theme.Space.s12)
            .glassBackground(cornerRadius: 999)
            .padding(.horizontal, Theme.Space.screenMargin)
            .padding(.top, Theme.Space.s8)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .task(id: resetToastID) {
                try? await Task.sleep(for: .seconds(3))
                resetStash = nil
            }
        }
    }

    private var introSection: some View {
        Button {
            confirmingIntro = true
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                Text("See the introduction again")
                    .font(Theme.Font.headline)
                Text("Start over from the first screen. Her list and the key stay.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textPrimary)
        .padding(.top, Theme.Space.s8)
    }

    private func restartIntroduction() {
        if model.isRunning {
            model.stop()
        }
        model.sessionLog.appendActivity("UI", "introduction restarted")
        onboardingDone = false
    }

    // MARK: - Ask

    private var askSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text("Ask")
                .font(Theme.Font.headline)
                .accessibilityAddTraits(.isHeader)
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
            if let notice = dictation.notice {
                Text(notice)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            NaturalLanguageComposer(
                text: $draft,
                focused: $composerFocused,
                placeholder: "e.g. Use shorter head starts tonight…",
                dictation: dictation
            ) {
                send()
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
                        .foregroundStyle(Theme.sage)
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

    // MARK: - Toggles and rows

    private var appearanceSection: some View {
        GlassCard(padding: Theme.Space.card) {
            Toggle(isOn: $night) {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text("Night look")
                        .font(Theme.Font.headline)
                    Text("Warm dim colors after dark")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.sage)
        }
        .sensoryFeedback(.selection, trigger: night)
    }

    private var sessionSection: some View {
        GlassCard(padding: Theme.Space.card) {
            Toggle(isOn: Binding(
                get: { model.quickTiming },
                set: { model.setQuickTiming($0) }
            )) {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text("Quick timing")
                        .font(Theme.Font.headline)
                    Text("Shorter head start for testing and demos")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.sage)
            .disabled(model.isRunning)
        }
        .sensoryFeedback(.selection, trigger: model.quickTiming)
    }

    private var keySection: some View {
        GlassCard(padding: Theme.Space.card) {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                Text("Meta API key")
                    .font(Theme.Font.headline)
                Text(model.keyStatus)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Update key") {
                    showingKey = true
                }
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.sageStrong)
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            GlassCard(padding: Theme.Space.card) {
                Button {
                    showingLog = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Theme.Space.s4) {
                            Text("Session log")
                                .font(Theme.Font.headline)
                            Text("Developer transcript of the last run")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .fontWeight(.light)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .foregroundStyle(Theme.textPrimary)
            }
            DevPanel(lines: devLines, log: model.sessionLog)
        }
    }

    private var devLines: [String] {
        var lines = [
            "frames seen \(model.framesSeen) · passed \(model.framesPassed)",
            "model calls \(model.modelCalls)",
            "meta: \(model.toolLine)",
            "gate: \(model.gateLine)",
            "cue: \(model.cueLine)",
            "mastery: \(model.masteryLine)",
            "headstart: \(model.headStartLine)",
            "last latch: \(model.liveLastLatchedNeedID ?? "—")\(SessionTelemetry.timeSuffix(model.liveLastLatchedAt))",
            SessionTelemetry.droppedLine(model.liveDroppedNeedIDs),
            model.timingLine,
        ]
        if model.liveEventTimeline.isEmpty {
            lines.append("events: —")
        } else {
            lines.append("events (oldest first):")
            lines.append(contentsOf: model.liveEventTimeline.suffix(8))
        }
        return lines
    }

    // MARK: - Ask intents (unchanged)

    private func send() {
        dictation.stop()
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
        if let readBack {
            question = nil
            model.sessionLog.appendActivity("SETTINGS", "ask \"\(text)\" -> \(Self.describe(readBack.change))")
        } else {
            model.sessionLog.appendActivity("SETTINGS", "ask \"\(text)\" -> question")
        }
    }

    private static func describe(_ change: AskReadBack.Change) -> String {
        switch change {
        case .quickTiming(let enabled):
            return "quick-timing(\(enabled))"
        case .checkIns(let allowed):
            return "check-ins(\(allowed))"
        }
    }

    private func asks(_ text: String, anyOf triggers: [String], allOf topics: [String]) -> Bool {
        triggers.contains(where: text.contains) && topics.contains(where: text.contains)
    }

    private func accept(_ readBack: AskReadBack) {
        switch readBack.change {
        case .quickTiming(let enabled):
            model.sessionLog.appendActivity("SETTINGS", "ask accepted quick-timing -> \(enabled)")
            model.setQuickTiming(enabled)
        case .checkIns(let allowed):
            model.sessionLog.appendActivity("SETTINGS", "ask accepted check-ins -> \(allowed)")
            model.setAllCheckIns(allowed)
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

#Preview("Settings") {
    NavigationStack {
        AskSettingsView(model: PhoneSessionModel())
    }
}

#Preview("Settings (night, AX)") {
    NavigationStack {
        AskSettingsView(model: PhoneSessionModel())
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
