import SwiftUI

/// Paged onboarding with no forms: three calm pages, glasses connect, then
/// the one field in the app (the Meta API key). Finishes straight into
/// Mom's List.
struct OnboardingView: View {
    @Bindable var model: PhoneSessionModel
    @Binding var done: Bool

    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0:
                    OnboardingPage(
                        tint: Theme.accentWarm,
                        title: "A quiet teammate.",
                        bodyText: "Noticer helps you catch the little things she needs before she has to ask."
                    )
                case 1:
                    OnboardingPage(
                        tint: Theme.headstart,
                        title: "Her list, her words.",
                        bodyText: "She just says what helps. You get a head start to notice first; a whisper comes only if you need it."
                    )
                case 2:
                    OnboardingPage(
                        tint: Theme.gotIt,
                        title: "Private by design.",
                        bodyText: "Frames stay in memory for a moment and are never saved. The light on the glasses shows when they're looking.",
                        systemImage: "lock.shield"
                    )
                case 3:
                    ConnectStep(model: model) { step = 4 }
                default:
                    APIKeyStep(model: model) { done = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if step < 3 {
                PageDots(count: 3, current: step)
                    .padding(.bottom, Theme.Space.s16)
                Button("Continue") {
                    step += 1
                }
                .buttonStyle(.primaryCapsule)
                if step < 2 {
                    Button("Skip") {
                        step = 3
                    }
                    .buttonStyle(.ghostCapsule)
                    .padding(.top, Theme.Space.s8)
                }
            }
        }
        .screenMargins()
        .padding(.bottom, Theme.Space.s24)
        .ambientScreen()
        .animation(Theme.gentle, value: step)
    }
}

private struct PageDots: View {
    var count: Int
    var current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Theme.accentWarm : Theme.textPrimary.opacity(0.2))
                    .frame(width: index == current ? 20 : 7, height: 7)
                    .animation(Theme.spring, value: current)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

// MARK: - Connect glasses (no inputs; states only)

private struct ConnectStep: View {
    @Bindable var model: PhoneSessionModel
    var next: () -> Void

    private enum Phase: Equatable {
        case waiting
        case connecting
        case connected
        case error
    }

    @State private var phase = Phase.waiting

    var body: some View {
        VStack(spacing: Theme.Space.s16) {
            Spacer()
            ZStack {
                StatusOrb(color: tint, size: 200)
                if phase == .connected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.gotIt)
                        .symbolEffect(.bounce, value: phase == .connected)
                }
            }
            Text(title)
                .font(Theme.Font.statusWord)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            switch phase {
            case .waiting:
                Button("Connect") {
                    connect()
                }
                .buttonStyle(.primaryCapsule)
                Button("Continue without glasses") {
                    next()
                }
                .buttonStyle(.ghostCapsule)
                .padding(.top, Theme.Space.s8)
            case .connecting:
                Button("Connecting…") {}
                    .buttonStyle(.primaryCapsule)
                    .disabled(true)
            case .connected:
                Button("Continue") {
                    next()
                }
                .buttonStyle(.primaryCapsule)
            case .error:
                Button("Retry") {
                    connect()
                }
                .buttonStyle(.primaryCapsule)
                Button("Continue without glasses") {
                    next()
                }
                .buttonStyle(.ghostCapsule)
                .padding(.top, Theme.Space.s8)
            }
        }
        .sensoryFeedback(.success, trigger: phase) { _, new in
            new == .connected
        }
    }

    private var tint: Color {
        switch phase {
        case .waiting, .connecting: Theme.listening
        case .connected: Theme.gotIt
        case .error: Theme.cue
        }
    }

    private var title: String {
        switch phase {
        case .waiting: return "Waiting for your glasses…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error: return "Can't find your glasses"
        }
    }

    private var subtitle: String {
        switch phase {
        case .waiting: return "Put them on and unfold them."
        case .connecting: return "Hold on a moment."
        case .connected: return "Your glasses are ready."
        case .error: return "Put them on and unfold them."
        }
    }

    private func connect() {
        model.configureWearables()
        phase = .connecting
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            switch model.glassesLink {
            case .connected:
                phase = .connected
            case .none, .notConnected, .unknown:
                phase = .error
            }
        }
    }
}

// MARK: - API key (the only field in the app)

struct APIKeyStep: View {
    @Bindable var model: PhoneSessionModel
    var next: () -> Void

    @State private var key = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            Spacer()
            Text("Meta API key")
                .font(Theme.Font.statusWord)
            Text("Saved securely in your iPhone's Keychain.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
            SecureField("Meta API key", text: $key)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(Theme.Font.body)
                .padding(Theme.Space.card)
                .background(Theme.bgCard, in: Theme.Radius.rect(Theme.Radius.row))
                .overlay(Theme.Radius.rect(Theme.Radius.row).stroke(Theme.Shadow.hairline, lineWidth: 1))
            if let message {
                Text(message)
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Continue") {
                save()
            }
            .buttonStyle(.primaryCapsule)
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Skip for now") {
                next()
            }
            .buttonStyle(.ghostCapsule)
            .padding(.top, Theme.Space.s8)
            Text("Replay works without a key. Mom's list needs one to talk to Spark.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, Theme.Space.s8)
        }
        .onAppear {
            focused = true
        }
    }

    private func save() {
        do {
            try ModelKeyStore.save(key)
            model.refreshKeyStatus()
            next()
        } catch {
            message = error.localizedDescription
        }
    }
}

#Preview("Onboarding") {
    OnboardingView(model: PhoneSessionModel(), done: .constant(false))
}

#Preview("Onboarding (night, AX)") {
    OnboardingView(model: PhoneSessionModel(), done: .constant(false))
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}
