import SwiftUI

/// One onboarding page: a soft glowing orb, one headline, one line of body.
/// The privacy page shows a shield instead of a bare orb.
struct OnboardingPage: View {
    var tint: Color
    var title: String
    var bodyText: String
    var systemImage: String?

    var body: some View {
        VStack(spacing: Theme.Space.s16) {
            Spacer()
            ZStack {
                StatusOrb(color: tint, size: 200)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .padding(.bottom, Theme.Space.s16)
            Text(title)
                .font(Theme.Font.statusWord)
                .multilineTextAlignment(.center)
            Text(bodyText)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Onboarding pages") {
    TabView {
        OnboardingPage(
            tint: Theme.accentWarm,
            title: "A quiet teammate.",
            bodyText: "Noticer helps you catch the little things she needs before she has to ask."
        )
        OnboardingPage(
            tint: Theme.gotIt,
            title: "Private by design.",
            bodyText: "Frames stay in memory for a moment and are never saved. The light on the glasses shows when they're looking.",
            systemImage: "lock.shield"
        )
    }
    .tabViewStyle(.page)
    .ambientScreen()
}

#Preview("Onboarding (light, AX)") {
    OnboardingPage(
        tint: Theme.headstart,
        title: "Her list, her words.",
        bodyText: "She just says what helps. You get a head start to notice first; a whisper comes only if you need it."
    )
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility5)
}
