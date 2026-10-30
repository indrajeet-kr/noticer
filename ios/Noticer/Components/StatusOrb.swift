import SwiftUI

/// The one focal element of the live screens: a soft glowing orb tinted by
/// state. Color cross-fades on state change; listening breathes slowly.
/// Status is never color alone — the word and symbol next to the orb carry it.
struct StatusOrb: View {
    var color: Color
    /// Changes when the state changes, so the tint cross-fades.
    var stateKey: String = "steady"
    var size: CGFloat = 220
    var breathing: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breath = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        .white.opacity(0.55),
                        color.opacity(0.85),
                        color.opacity(0.25),
                        .clear,
                    ],
                    center: .center,
                    startRadius: size * 0.08,
                    endRadius: size * 0.52
                )
            )
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.55), radius: 34)
            .scaleEffect(breathing && !reduceMotion && breath ? 1.03 : 1.0)
            .animation(reduceMotion ? Theme.crossfade : Theme.gentle, value: stateKey)
            .onAppear {
                guard breathing, !reduceMotion else { return }
                withAnimation(Theme.breathe) { breath = true }
            }
            .onChange(of: reduceMotion) { _, reduced in
                breath = !reduced && breathing ? breath : false
            }
            .accessibilityHidden(true)
    }
}

/// A countdown ring that drains gently around the orb during the head start.
/// Numbers stay out of sight; VoiceOver reads the seconds that are left.
struct CountdownRing: View {
    /// 1 is full, 0 is spent.
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat = 6

    var body: some View {
        Circle()
            .trim(from: 0, to: max(0, min(1, fraction)))
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .animation(Theme.gentle, value: fraction)
            .accessibilityHidden(true)
    }
}

#Preview("Orb states") {
    VStack(spacing: Theme.Space.s24) {
        StatusOrb(color: Theme.listening, size: 160)
        HStack(spacing: Theme.Space.s16) {
            StatusOrb(color: Theme.noticed, size: 72, breathing: false)
            StatusOrb(color: Theme.headstart, size: 72, breathing: false)
            StatusOrb(color: Theme.cue, size: 72, breathing: false)
            StatusOrb(color: Theme.gotIt, size: 72, breathing: false)
        }
        ZStack {
            StatusOrb(color: Theme.headstart, size: 160, breathing: false)
            CountdownRing(fraction: 0.62, color: Theme.headstart)
                .frame(width: 190, height: 190)
        }
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Orb (light, AX)") {
    VStack(spacing: Theme.Space.s24) {
        ZStack {
            StatusOrb(color: Theme.headstart, size: 160, breathing: false)
            CountdownRing(fraction: 0.62, color: Theme.headstart)
                .frame(width: 190, height: 190)
        }
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility5)
}
