import NoticerCore
import SwiftUI

/// Words under the Tonight circle, one per state. The state is always in
/// words; the circle never stands alone.
enum SessionCircleWords {
    static func text(for status: SessionStatus) -> String {
        switch status {
        case .idle:
            return "Tap to start. You get a head start first."
        case .listening:
            return DemoStripMapper.listeningStatus
        case .noticed(let name):
            return "Noticed: \(name)"
        case .headStart(let name, _, let secondsLeft):
            return "Noticed: \(name) · about \(secondsLeft) s for you"
        case .cue(let whisper):
            return "We gave you a nudge: \(whisper)"
        case .gotIt(_, let shared):
            return shared ? "You finished it. Nice teamwork." : "You got it. Nice catch."
        }
    }
}

/// The Tonight Start control: one big sage circle driven by `sessionStatus`.
/// Idle invites a tap; while running the circle is display-only and a calm
/// Stop button sits under the words. Reduce Motion gets a static ring with
/// crossfades instead of the breathing pulse.
struct SessionCircle: View {
    var status: SessionStatus
    var size: CGFloat = 240
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breath = false
    @ScaledMetric private var heroSize: CGFloat = 34

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(circleFill)
                if let ring = ringFraction {
                    Circle()
                        .trim(from: 0, to: ring)
                        .stroke(
                            Theme.terracotta,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .padding(8)
                }
                circleInner
            }
            .frame(width: size, height: size)
            .scaleEffect(breathingActive && breath ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? Theme.crossfade : Theme.gentle, value: status.animationKey)
        .onAppear {
            guard breathingActive, !reduceMotion else { return }
            withAnimation(Theme.breathe) { breath = true }
        }
        .onChange(of: breathingActive) { _, active in
            guard active, !reduceMotion else { return }
            withAnimation(Theme.breathe) { breath = true }
        }
        .accessibilityLabel(SessionCircleWords.text(for: status))
        .accessibilityHint(status == .idle ? "Double-tap to start" : "")
        .sensoryFeedback(.success, trigger: status.animationKey) { _, new in
            new.hasPrefix("gotit-")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: status.animationKey) { _, new in
            new.hasPrefix("cue-")
        }
        .onChange(of: status.animationKey) { _, _ in
            AccessibilityNotification.Announcement(SessionCircleWords.text(for: status)).post()
        }
    }

    private var breathingActive: Bool {
        if case .listening = status {
            return true
        }
        return false
    }

    private var circleFill: Color {
        if case .gotIt = status {
            return Theme.sage
        }
        return Theme.sagePale
    }

    private var ringFraction: Double? {
        switch status {
        case .noticed:
            return 1
        case .headStart(_, let fraction, _):
            return fraction
        case .cue:
            return 1
        default:
            return nil
        }
    }

    @ViewBuilder
    private var circleInner: some View {
        switch status {
        case .idle:
            VStack(spacing: Theme.Space.s8) {
                Text("Start noticing")
                    .font(.system(size: heroSize, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Image(systemName: "heart.fill")
                    .fontWeight(.light)
                    .foregroundStyle(Theme.terracotta)
            }
            .padding(Theme.Space.s24)
        case .listening:
            Image(systemName: "ear")
                .font(.system(size: 56))
                .fontWeight(.light)
                .foregroundStyle(Theme.sageStrong)
        case .noticed:
            Image(systemName: "eye")
                .font(.system(size: 56))
                .fontWeight(.light)
                .foregroundStyle(Theme.terracotta)
        case .headStart(_, _, let secondsLeft):
            VStack(spacing: Theme.Space.s4) {
                Text("\(secondsLeft)")
                    .font(.system(size: heroSize * 1.4, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text("seconds for you")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .cue:
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 56))
                .fontWeight(.light)
                .foregroundStyle(Theme.terracotta)
        case .gotIt:
            Image(systemName: "checkmark")
                .font(.system(size: 56))
                .fontWeight(.light)
                .foregroundStyle(Theme.onSage)
        }
    }
}

#Preview("Circle states") {
    VStack(spacing: Theme.Space.s24) {
        SessionCircle(status: .idle, size: 200) {}
        SessionCircle(status: .headStart(needName: "nursing, no water", fraction: 0.6, secondsLeft: 40), size: 140) {}
        SessionCircle(status: .gotIt(needName: "nursing, no water"), size: 140) {}
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Circle (night, AX)") {
    SessionCircle(status: .cue(whisper: "Her water's empty."), size: 200) {}
        .screenMargins()
        .ambientScreen()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}
