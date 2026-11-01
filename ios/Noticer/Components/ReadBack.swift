import NoticerCore
import SwiftUI

/// One numbered read-back of a need in her words: the need, the whisper
/// he'll hear, the priority word, and the check-in note when allowed.
struct NeedReadBackCard: View {
    var number: Int
    var draft: NeedsIntentDraft
    var changed: Bool = false

    private var heard: String {
        let spoken = SpokenCueForm.line(cueWording: draft.whisper, authorText: draft.authorText)
        return spoken.isEmpty ? draft.whisper : spoken
    }

    var body: some View {
        GlassCard(padding: Theme.Space.card) {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s4) {
                    Text("\(number). \(draft.authorText)")
                        .font(Theme.Font.headline)
                    if changed {
                        Text("Updated")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.sageStrong)
                    }
                }
                Text("He'll hear: “\(heard)”")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: Theme.Space.s8) {
                    PriorityChip(priority: draft.priority)
                    if draft.allowsCheckIn {
                        Text("May check in with you")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A calm Spark bubble: read-back header, suggestion chips, or plain text.
struct SparkBubble: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.body)
            .padding(Theme.Space.s12)
            .background(Theme.bgSubtle)
            .clipShape(Theme.Radius.rect(Theme.Radius.row))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tappable suggestion that answers by sending that text.
struct SuggestionChip: View {
    var text: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Theme.Font.footnote)
                .padding(.horizontal, Theme.Space.s12)
                .padding(.vertical, Theme.Space.s8)
                .frame(minHeight: 44)
                .background(Theme.bgCard, in: Capsule())
                .overlay(
                    Capsule().stroke(Theme.textPrimary.opacity(0.16), lineWidth: 1)
                )
        }
        .foregroundStyle(Theme.textPrimary)
    }
}

#Preview("Read-back") {
    VStack(spacing: Theme.Space.s12) {
        SparkBubble(text: "Got it:")
        NeedReadBackCard(
            number: 1,
            draft: NeedsIntentDraft(
                id: "take-baby",
                authorText: "Take the baby when you're eating one-handed",
                whisper: "She could use a hand.",
                priority: .normal,
                allowsCheckIn: false,
                visualCue: "adult eating while holding an infant in one arm"
            )
        )
        NeedReadBackCard(
            number: 2,
            draft: NeedsIntentDraft(
                id: "refill-water",
                authorText: "Keep your water bottle full, especially at night",
                whisper: "Her water's low.",
                priority: .important,
                allowsCheckIn: true,
                visualCue: "adult in bed at night with no water bottle in reach"
            ),
            changed: true
        )
        HStack {
            SuggestionChip(text: "While I'm eating") {}
            SuggestionChip(text: "At bedtime") {}
        }
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Read-back (night, AX)") {
    VStack(spacing: Theme.Space.s12) {
        NeedReadBackCard(
            number: 1,
            draft: NeedsIntentDraft(
                id: "take-baby",
                authorText: "Take the baby when you're eating one-handed",
                whisper: "She could use a hand.",
                priority: .normal,
                allowsCheckIn: false,
                visualCue: "adult eating while holding an infant in one arm"
            )
        )
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
