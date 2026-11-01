import NoticerCore
import SwiftUI

/// One need on Her list: a white card with a leading icon tile, her words,
/// and nothing else. No timing jargon, no toggle — tap opens the detail
/// sheet. Paused cards dim and read "Paused tonight".
struct NeedCard: View {
    var need: Need
    var isPaused: Bool = false

    var body: some View {
        HStack(spacing: Theme.Space.s16) {
            Image(systemName: NeedIcon.symbol(for: need))
                .font(.title2)
                .fontWeight(.light)
                .foregroundStyle(glyphColor)
                .saturation(isPaused ? 0 : 1)
                .frame(width: 56, height: 56)
                .background(tileColor, in: Theme.Radius.rect(Theme.Radius.tile))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                Text(displayWords)
                    .font(Theme.Font.body)
                    .lineLimit(3)
                Text("Her words")
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if need.isUrgent {
                    Text("Urgent")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.terracottaText)
                }
                if isPaused {
                    Text("Paused tonight")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBackground()
        .opacity(isPaused ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var displayWords: String {
        let words = need.authorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? need.id : words
    }

    private var accessibilityText: String {
        var text = displayWords
        if need.isUrgent {
            text += ". Urgent."
        }
        if isPaused {
            text += ". Paused tonight."
        }
        return text
    }

    /// Important or urgent needs get the terracotta tile; the rest get sage.
    private var tileColor: Color {
        needsAttention ? Theme.terracottaTile : Theme.sageTile
    }

    private var glyphColor: Color {
        needsAttention ? Theme.terracotta : Theme.sage
    }

    private var needsAttention: Bool {
        need.isUrgent || need.priority <= 0
    }
}

#Preview("Need cards") {
    VStack(spacing: Theme.Space.cardGap) {
        NeedCard(need: MVPNeedListPreview.takeBaby)
        NeedCard(need: MVPNeedListPreview.refillWater, isPaused: true)
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Need cards (night, AX)") {
    VStack(spacing: Theme.Space.cardGap) {
        NeedCard(need: MVPNeedListPreview.takeBaby)
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}

#if DEBUG
/// Preview-only needs mirroring the default list's words.
private enum MVPNeedListPreview {
    static let takeBaby = Need(
        id: "take-baby",
        authorText: "eating one-handed, take the baby",
        cueWording: "Her plate's getting cold, maybe take the baby?",
        priority: 0
    )
    static let refillWater = Need(
        id: "refill-water",
        authorText: "nursing, no water",
        cueWording: "Her water's empty.",
        priority: 1
    )
}
#endif
