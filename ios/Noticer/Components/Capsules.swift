import SwiftUI

/// Small glass status pill: an icon plus a word. Used for the glasses
/// battery, thermal, and link strip, the Replay banner, and similar.
struct StatusCapsule: View {
    var systemImage: String
    var text: String
    var tint: Color?

    var body: some View {
        HStack(spacing: Theme.Space.s4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(Theme.Font.footnote)
        .foregroundStyle(tint ?? Theme.textSecondary)
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, 6)
        .glassBackground(cornerRadius: 999)
        .accessibilityElement(children: .combine)
    }
}

/// The one primary action on a screen: a full-width apricot capsule.
struct PrimaryCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.headline)
            .foregroundStyle(Theme.onAccentFill)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.s16)
            .background(Theme.accentFill)
            .clipShape(Capsule())
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryCapsuleButtonStyle {
    static var primaryCapsule: PrimaryCapsuleButtonStyle { PrimaryCapsuleButtonStyle() }
}

/// Secondary action: a full-width glass capsule.
struct GhostCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.headline)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.s16)
            .glassBackground(cornerRadius: 999)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GhostCapsuleButtonStyle {
    static var ghostCapsule: GhostCapsuleButtonStyle { GhostCapsuleButtonStyle() }
}

#Preview("Capsules + buttons") {
    VStack(spacing: Theme.Space.s16) {
        HStack {
            StatusCapsule(systemImage: "battery.75", text: "Glasses 82%")
            StatusCapsule(systemImage: "thermometer.medium", text: "Normal")
            StatusCapsule(systemImage: "wifi", text: "Connected")
        }
        Button("Start") {}.buttonStyle(.primaryCapsule)
        Button("Not now") {}.buttonStyle(.ghostCapsule)
        Button("Continue") {}.buttonStyle(.primaryCapsule).disabled(true)
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Capsules + buttons (light, AX)") {
    VStack(spacing: Theme.Space.s16) {
        HStack {
            StatusCapsule(systemImage: "battery.75", text: "Glasses 82%")
            StatusCapsule(systemImage: "wifi", text: "Connected")
        }
        Button("Start") {}.buttonStyle(.primaryCapsule)
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility5)
}
