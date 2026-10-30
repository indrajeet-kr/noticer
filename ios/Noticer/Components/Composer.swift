import SwiftUI

/// The one chat-like composer in the app, pinned to the bottom: multiline
/// text, a mic button for system dictation, and a send arrow.
/// No forms anywhere else; this plus the API-key field are the only inputs.
struct NaturalLanguageComposer: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var placeholder: String
    var isSending: Bool = false
    var onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s8) {
            Button {
                focused.wrappedValue = true
            } label: {
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 46, height: 46)
            }
            .glassBackground(cornerRadius: 999)
            .accessibilityLabel("Dictate. Uses the keyboard microphone.")

            TextField(placeholder, text: $text, axis: .vertical)
                .focused(focused)
                .lineLimit(1...4)
                .font(Theme.Font.body)
                .padding(.horizontal, Theme.Space.s16)
                .padding(.vertical, Theme.Space.s12)
                .frame(minHeight: 46)
                .glassBackground(cornerRadius: 23)
                .accessibilityLabel("Message")

            Button {
                focused.wrappedValue = false
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(Theme.onAccentFill)
                    .frame(width: 46, height: 46)
                    .background(canSend ? Theme.accentFill : Theme.textPrimary.opacity(0.18))
                    .clipShape(Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    private var canSend: Bool {
        !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Offline banner: the last saved list stays visible and active underneath.
struct OfflineBanner: View {
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s12) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Theme.noticed)
            Text("Couldn't reach Spark right now. Your last saved list is still active.")
                .font(Theme.Font.footnote)
                .foregroundStyle(Theme.textSecondary)
            Button("Retry", action: onRetry)
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.accentWarm)
        }
        .padding(Theme.Space.s12)
        .glassBackground(cornerRadius: Theme.Radius.row)
        .accessibilityElement(children: .combine)
    }
}

/// Three breathing dots while Spark reads her list.
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        HStack(spacing: Theme.Space.s4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Theme.textSecondary)
                    .frame(width: 7, height: 7)
                    .opacity(reduceMotion ? 1 : (phase ? 0.35 : 1))
                    .animation(
                        reduceMotion ? nil : Theme.gentle.delay(Double(index) * 0.2).repeatForever(autoreverses: true),
                        value: phase
                    )
            }
            Text("Listening to your list…")
                .font(Theme.Font.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, Theme.Space.s4)
        }
        .onAppear { phase = true }
        .accessibilityLabel("Listening to your list")
    }
}

struct ComposerPreview: View {
    @State private var text: String
    @FocusState private var focused: Bool
    var placeholder: String

    init(text: String, placeholder: String) {
        _text = State(initialValue: text)
        self.placeholder = placeholder
    }

    var body: some View {
        NaturalLanguageComposer(text: $text, focused: $focused, placeholder: placeholder) {}
    }
}

#Preview("Composer + banner") {
    VStack(spacing: Theme.Space.s16) {
        OfflineBanner {}
        ThinkingDots()
        ComposerPreview(
            text: "When I'm eating with the baby…",
            placeholder: "e.g. When I'm eating with the baby in one arm, take her so I can eat…"
        )
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Composer (light, AX)") {
    VStack(spacing: Theme.Space.s16) {
        OfflineBanner {}
        ComposerPreview(text: "", placeholder: "Say what helps…")
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility5)
}
