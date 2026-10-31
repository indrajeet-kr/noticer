import SwiftUI

/// The one chat-like composer in the app, docked at the bottom: multiline
/// text, a mic button for dictation, and a send arrow.
/// No forms anywhere else; this plus the API-key field are the only inputs.
struct NaturalLanguageComposer: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var placeholder: String
    var isSending: Bool = false
    /// On-device dictation. When nil, the mic focuses the keyboard as before.
    var dictation: DictationService?
    var onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s8) {
            if let dictation {
                DictationMicButton(dictation: dictation, focused: focused)
            } else {
                Button {
                    focused.wrappedValue = true
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                        .fontWeight(.light)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 46, height: 46)
                        .background(Theme.bgCard, in: Circle())
                        .overlay(Circle().stroke(Theme.Shadow.hairline, lineWidth: 1))
                }
                .accessibilityLabel("Dictate. Uses the keyboard microphone.")
            }

            HStack(spacing: Theme.Space.s8) {
                Image(systemName: "sparkles")
                    .fontWeight(.light)
                    .foregroundStyle(Theme.sage)
                    .accessibilityHidden(true)
                TextField(placeholder, text: $text, axis: .vertical)
                    .focused(focused)
                    .lineLimit(1...4)
                    .font(Theme.Font.body)
                    .frame(minHeight: 46)
                    .accessibilityLabel("Message")
            }
            .padding(.horizontal, Theme.Space.s16)
            .padding(.vertical, Theme.Space.s4)
            .background(Theme.bgCard, in: Theme.Radius.rect(23))
            .overlay(Theme.Radius.rect(23).stroke(Theme.Shadow.hairline, lineWidth: 1))
            .shadow(color: Theme.Shadow.color, radius: Theme.Shadow.radius, y: Theme.Shadow.y)

            Button {
                focused.wrappedValue = false
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(Theme.onSage)
                    .frame(width: 46, height: 46)
                    .background(canSend ? Theme.sage : Theme.textPrimary.opacity(0.18))
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

/// The mic button with on-device dictation: toggles recording, shows a stop
/// glyph while listening, and falls back to the keyboard when dictation
/// declines (a session is running, permissions denied, unavailable).
private struct DictationMicButton: View {
    var dictation: DictationService
    var focused: FocusState<Bool>.Binding

    var body: some View {
        Button {
            Task {
                guard await dictation.toggle() == false else {
                    return
                }
                focused.wrappedValue = true
            }
        } label: {
            Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                .font(.title3)
                .fontWeight(.light)
                .foregroundStyle(dictation.isRecording ? Theme.terracotta : Theme.textPrimary)
                .frame(width: 46, height: 46)
                .background(Theme.bgCard, in: Circle())
                .overlay(Circle().stroke(Theme.Shadow.hairline, lineWidth: 1))
        }
        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate by voice")
    }
}

/// Offline banner: the last saved list stays visible and active underneath.
/// Copy unchanged from the dark UI.
struct OfflineBanner: View {
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s12) {
            Image(systemName: "wifi.exclamationmark")
                .fontWeight(.light)
                .foregroundStyle(Theme.terracottaText)
            Text("Couldn't reach Spark right now. Your last saved list is still active.")
                .font(Theme.Font.footnote)
                .foregroundStyle(Theme.terracottaText)
            Button("Retry", action: onRetry)
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.terracottaText)
        }
        .padding(Theme.Space.s12)
        .background(Theme.terracottaTile, in: Theme.Radius.rect(Theme.Radius.row))
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
            placeholder: "Tell me in your own words…"
        )
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Composer (night, AX)") {
    VStack(spacing: Theme.Space.s16) {
        OfflineBanner {}
        ComposerPreview(text: "", placeholder: "Tell me in your own words…")
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
