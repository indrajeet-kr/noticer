import SwiftUI

/// Every color, spacing, radius, font, and motion value in the app.
/// Views take values from here; no magic numbers in views.
///
/// Colors live in `Assets.xcassets` with light and dark variants. The dark
/// values are the spec's hexes. Light variants of the state colors are
/// deepened for WCAG AA on the light surfaces; the dark/light pair is the
/// token, so views still name one token.
enum Theme {
    // MARK: Surfaces

    static let bgBase = Color("bgBase", bundle: .main)
    static let bgElevated = Color("bgElevated", bundle: .main)
    static let ambient1 = Color("ambient1", bundle: .main)
    static let ambient2 = Color("ambient2", bundle: .main)

    // MARK: Text

    static let textPrimary = Color("textPrimary", bundle: .main)
    static var textSecondary: Color { textPrimary.opacity(0.7) }
    static var textTertiary: Color { textPrimary.opacity(0.45) }

    // MARK: Accent and state

    /// Apricot. Adaptive for tints and text.
    static let accentWarm = Color("accentWarm", bundle: .main)
    /// Fixed apricot + ink for the primary capsule, identical in both modes
    /// so the button keeps one identity on either surface.
    static let accentFill = Color(red: 0xF2 / 255, green: 0xA6 / 255, blue: 0x5A / 255)
    static let onAccentFill = Color(red: 0x1B / 255, green: 0x12 / 255, blue: 0x06 / 255)
    static let listening = Color("stateListening", bundle: .main)
    static let noticed = Color("stateNoticed", bundle: .main)
    static let headstart = Color("stateHeadstart", bundle: .main)
    static let cue = Color("stateCue", bundle: .main)
    static let gotIt = Color("stateGotIt", bundle: .main)
    static let danger = Color("danger", bundle: .main)

    // MARK: Spacing (4-pt grid)

    enum Space {
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        static let s48: CGFloat = 48

        static let screenMargin: CGFloat = 20
        static let card: CGFloat = 16
        static let cardRoomy: CGFloat = 20
        static let sectionGap: CGFloat = 32
    }

    // MARK: Radii (.continuous everywhere)

    enum Radius {
        static let chip: CGFloat = 8
        static let row: CGFloat = 16
        static let card: CGFloat = 24
        static let hero: CGFloat = 32

        static func rect(_ radius: CGFloat) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
        }
    }

    // MARK: Type (SF Pro, Dynamic Type; rounded for display)

    enum Font {
        /// The one status word on a screen.
        static var statusWord: SwiftUI.Font {
            .system(.largeTitle, design: .rounded).weight(.semibold)
        }

        static var title: SwiftUI.Font { .title2.weight(.semibold) }
        static var headline: SwiftUI.Font { .headline }
        static var body: SwiftUI.Font { .body }
        static var footnote: SwiftUI.Font { .footnote }
        static var caption: SwiftUI.Font { .caption }

        /// Developer panel and other fixed-width telemetry.
        static var monoCaption: SwiftUI.Font { .caption.monospaced() }
    }

    // MARK: Elevation (hero only)

    enum Shadow {
        static let color = Color.black.opacity(0.25)
        static let radius: CGFloat = 24
        static let y: CGFloat = 8
    }

    // MARK: Motion

    static let spring = Animation.spring(duration: 0.45, bounce: 0.15)
    static let gentle = Animation.smooth(duration: 0.8)
    static let crossfade = Animation.easeInOut(duration: 0.2)
    /// Listening breath, 4 s loop. Off under Reduce Motion.
    static let breathe = Animation.easeInOut(duration: 4).repeatForever(autoreverses: true)
}

// MARK: - Shared environment helpers

extension View {
    /// Calm screen scaffold: ambient wash over the base surface.
    func ambientScreen() -> some View {
        modifier(AmbientScreenModifier())
    }

    /// Standard screen padding.
    func screenMargins() -> some View {
        padding(.horizontal, Theme.Space.screenMargin)
    }
}

private struct AmbientScreenModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                Theme.bgBase.ignoresSafeArea()
                AmbientWash().ignoresSafeArea()
            }
            .foregroundStyle(Theme.textPrimary)
    }
}

/// Soft two-stop wash at low saturation. Decorative only.
struct AmbientWash: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Theme.bgBase
                RadialGradient(
                    colors: [Theme.ambient1.opacity(0.55), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.85
                )
                RadialGradient(
                    colors: [Theme.ambient2.opacity(0.5), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.8
                )
            }
            .saturation(0.7)
        }
        .accessibilityHidden(true)
    }
}
