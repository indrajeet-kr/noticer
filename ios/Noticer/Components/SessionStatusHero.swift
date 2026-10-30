import SwiftUI

/// The focal point of Live and Replay: the status orb with its countdown
/// ring, the one status word in display type, and a one-line explanation.
/// VoiceOver reads the full state; state changes announce once and pair a
/// word plus a symbol with the color. Haptics stay quiet: success on
/// "You got it", a light tap on a whispered cue.
struct SessionStatusHero: View {
    var status: SessionStatus
    var orbSize: CGFloat = 220

    var body: some View {
        VStack(spacing: Theme.Space.s16) {
            ZStack {
                StatusOrb(
                    color: status.tint,
                    stateKey: status.animationKey,
                    size: orbSize,
                    breathing: status.breathing
                )
                if let fraction = status.headStartFraction {
                    CountdownRing(fraction: fraction, color: status.tint)
                        .frame(width: orbSize + 30, height: orbSize + 30)
                }
            }
            .padding(.top, Theme.Space.s8)

            VStack(spacing: Theme.Space.s8) {
                HStack(spacing: Theme.Space.s8) {
                    Image(systemName: status.symbol)
                        .font(.title2)
                        .foregroundStyle(status.tint)
                        .symbolEffect(.pulse, options: .repeating, value: status.animationKey)
                    Text(status.word)
                        .font(Theme.Font.statusWord)
                        .contentTransition(.opacity)
                }
                Text(status.line)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
        }
        .animation(Theme.gentle, value: status.animationKey)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.voiceOver)
        .sensoryFeedback(.success, trigger: status.animationKey) { _, new in
            new.hasPrefix("gotit-")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: status.animationKey) { _, new in
            new.hasPrefix("cue-")
        }
        .onChange(of: status.animationKey) { _, _ in
            AccessibilityNotification.Announcement(status.voiceOver).post()
        }
    }
}

#Preview("Hero states") {
    VStack(spacing: Theme.Space.s32) {
        SessionStatusHero(status: .listening(checking: false), orbSize: 140)
        SessionStatusHero(status: .listening(checking: true), orbSize: 140)
        SessionStatusHero(
            status: .headStart(needName: "Her water bottle", fraction: 0.6, secondsLeft: 12),
            orbSize: 140
        )
        SessionStatusHero(status: .gotIt(needName: "Her water bottle"), orbSize: 140)
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Hero (light, AX)") {
    SessionStatusHero(status: .cue(whisper: "Her water's low."))
        .screenMargins()
        .ambientScreen()
        .preferredColorScheme(.light)
        .dynamicTypeSize(.accessibility5)
}
