import SwiftUI

/// A fading ring: fill shows mastery `m`, labeled from "Coaching" (full
/// color) to "Quiet" (desaturated, small moon). Fading support, not scoring.
struct MasteryRing: View {
    /// 0...1.
    var score: Double
    var quiet: Bool
    var size: CGFloat = 84
    /// Full VoiceOver text, e.g. "Water: mostly quiet, 80 percent".
    var accessibilityText: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.textPrimary.opacity(0.12), lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0, min(1, score)))
                .stroke(
                    Theme.accentWarm,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .saturation(quiet ? 0.1 : 1)
            if quiet {
                Image(systemName: "moon.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("\(Int((max(0, min(1, score)) * 100).rounded()))%")
                    .font(Theme.Font.headline)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }
}

#Preview("Mastery rings") {
    HStack(spacing: Theme.Space.s24) {
        VStack {
            MasteryRing(score: 0.25, quiet: false, accessibilityText: "Water: coaching, 25 percent")
            Text("Coaching").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        VStack {
            MasteryRing(score: 0.68, quiet: false, accessibilityText: "Baby: getting quieter, 68 percent")
            Text("Getting quieter").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        VStack {
            MasteryRing(score: 0.95, quiet: true, accessibilityText: "Plates: quiet, 95 percent")
            Text("Quiet").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Mastery rings (light, AX)") {
    HStack(spacing: Theme.Space.s24) {
        MasteryRing(score: 0.68, quiet: false, accessibilityText: "Baby: getting quieter, 68 percent")
        MasteryRing(score: 0.95, quiet: true, accessibilityText: "Plates: quiet, 95 percent")
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility5)
}
