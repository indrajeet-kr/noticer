import SwiftUI

/// A fading ring: fill shows mastery `m`, sage once the score reaches 0.5,
/// terracotta while still learning. Retired needs read as a sage filled
/// circle with a checkmark. Fading support, not scoring — the word beside
/// the ring always leads.
struct MasteryRing: View {
    /// 0...1.
    var score: Double
    var quiet: Bool
    /// Retired: sage filled circle with a checkmark.
    var retired: Bool = false
    var size: CGFloat = 84
    /// Full VoiceOver text, e.g. "Water: getting there, caught 3 times yourself".
    var accessibilityText: String

    var body: some View {
        ZStack {
            if retired {
                Circle()
                    .fill(Theme.sage)
                Image(systemName: "checkmark")
                    .fontWeight(.light)
                    .foregroundStyle(Theme.onSage)
            } else {
                Circle()
                    .stroke(Theme.textPrimary.opacity(0.12), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0, min(1, score)))
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .saturation(quiet ? 0.1 : 1)
                if quiet {
                    Image(systemName: "moon.fill")
                        .font(.title3)
                        .fontWeight(.light)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("\(Int((max(0, min(1, score)) * 100).rounded()))%")
                        .font(Theme.Font.headline)
                        .contentTransition(.numericText())
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var ringColor: Color {
        score >= 0.5 ? Theme.sage : Theme.terracotta
    }
}

#Preview("Mastery rings") {
    HStack(spacing: Theme.Space.s24) {
        VStack {
            MasteryRing(score: 0.25, quiet: false, accessibilityText: "Water: learning, 25 percent")
            Text("Learning").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        VStack {
            MasteryRing(score: 0.68, quiet: false, accessibilityText: "Baby: getting there, 68 percent")
            Text("Getting there").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        VStack {
            MasteryRing(score: 0.95, quiet: true, retired: true, accessibilityText: "Plates: you've got this")
            Text("You've got this").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Mastery rings (night, AX)") {
    HStack(spacing: Theme.Space.s24) {
        MasteryRing(score: 0.68, quiet: false, accessibilityText: "Baby: getting there, 68 percent")
        MasteryRing(score: 0.95, quiet: true, retired: true, accessibilityText: "Plates: you've got this")
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
