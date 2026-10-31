import SwiftUI

/// Every color, spacing, radius, font, and motion value in the app.
/// Views take values from here; no magic numbers in views.
///
/// Warm cream Light look with a warm-dim Night look. Each token is an Asset
/// Catalog color with a Light value and a Night value in the Dark slot; Night
/// is applied with `.preferredColorScheme(night ? .dark : .light)`, never by
/// following the system appearance. Night is brown-charcoal, never pure black.
///
/// One accent per state: sage is calm/listening/learned, terracotta needs
/// attention. White on `sage` #7F9177 is ~3.4:1, so button labels stay
/// semibold 17pt+ (large text, AA at 3:1); `sageStrong` #667A5F (~4.6:1)
/// covers smaller text.
enum Theme {
    // MARK: Surfaces

    static let bgBase = Color("bgBase", bundle: .main)
    static let bgCard = Color("bgCard", bundle: .main)
    static let bgSubtle = Color("bgSubtle", bundle: .main)

    /// Back-compat alias: elevated surfaces are cards now.
    static var bgElevated: Color { bgCard }

    /// Unused since the gradient was removed; kept so old call sites compile.
    static var ambient1: Color { bgSubtle }
    static var ambient2: Color { bgSubtle }

    // MARK: Text

    static let textPrimary = Color("textPrimary", bundle: .main)
    static let textSecondary = Color("textSecondary", bundle: .main)
    static var textTertiary: Color { textPrimary.opacity(0.45) }

    // MARK: Accents

    /// Sage: calm, listening, learned. Primary buttons, toggles, rings.
    static let sage = Color("sage", bundle: .main)
    /// Darker sage for small text on light surfaces.
    static let sageStrong = Color("sageStrong", bundle: .main)
    static let sageRing = Color("sageRing", bundle: .main)
    /// Pale sage: session circle, chart bars.
    static let sagePale = Color("sagePale", bundle: .main)
    static let sageTile = Color("sageTile", bundle: .main)

    /// Terracotta: needs attention, cue, countdown.
    static let terracotta = Color("terracotta", bundle: .main)
    static let terracottaText = Color("terracottaText", bundle: .main)
    static let terracottaTile = Color("terracottaTile", bundle: .main)

    static let onSage = Color("onSage", bundle: .main)
    static let danger = Color("danger", bundle: .main)

    // MARK: Back-compat state aliases (one accent per state)

    static var accentWarm: Color { sage }
    static var accentFill: Color { sage }
    static var onAccentFill: Color { onSage }
    static var listening: Color { sage }
    static var noticed: Color { terracotta }
    static var headstart: Color { terracotta }
    static var cue: Color { terracotta }
    static var gotIt: Color { sage }

    // MARK: Spacing (4-pt grid)

    enum Space {
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        static let s48: CGFloat = 48

        static let screenMargin: CGFloat = 20
        static let card: CGFloat = 16
        static let cardRoomy: CGFloat = 20
        static let cardGap: CGFloat = 12
        static let sectionGap: CGFloat = 28
    }

    // MARK: Radii (.continuous everywhere)

    enum Radius {
        static let chip: CGFloat = 8
        static let row: CGFloat = 16
        static let tile: CGFloat = 16
        static let button: CGFloat = 18
        static let card: CGFloat = 20
        static let hero: CGFloat = 32

        static func rect(_ radius: CGFloat) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
        }
    }

    // MARK: Type (serif display, SF Pro body, Dynamic Type)

    enum Font {
        /// Screen titles in New York serif: "Her list", "Tonight", "You're learning".
        static var display: SwiftUI.Font {
            .system(.largeTitle, design: .serif)
        }

        /// The one status word on a screen. Same serif display face.
        static var statusWord: SwiftUI.Font { display }

        /// Big in-circle hero line. Views scale it with `@ScaledMetric`.
        static var hero: SwiftUI.Font {
            .system(size: 34, design: .serif)
        }

        static var title: SwiftUI.Font { .title2.weight(.semibold) }
        static var headline: SwiftUI.Font { .headline }
        static var body: SwiftUI.Font { .body }
        static var footnote: SwiftUI.Font { .footnote }
        static var caption: SwiftUI.Font { .caption }

        /// Developer panel and other fixed-width telemetry.
        static var monoCaption: SwiftUI.Font { .caption.monospaced() }
    }

    // MARK: Elevation (one very soft shadow plus a hairline on cream)

    enum Shadow {
        static let color = Color.black.opacity(0.06)
        static let radius: CGFloat = 12
        static let y: CGFloat = 4
        static let hairline = Color.black.opacity(0.04)
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
    /// Calm screen scaffold: a plain warm-cream fill.
    func ambientScreen() -> some View {
        modifier(AmbientScreenModifier())
    }

    /// Standard screen padding.
    func screenMargins() -> some View {
        padding(.horizontal, Theme.Space.screenMargin)
    }

    /// The one card elevation: soft shadow plus a hairline.
    func cardShadow(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        self
            .shadow(color: Theme.Shadow.color, radius: Theme.Shadow.radius, y: Theme.Shadow.y)
            .overlay(
                Theme.Radius.rect(cornerRadius)
                    .stroke(Theme.Shadow.hairline, lineWidth: 1)
            )
    }
}

private struct AmbientScreenModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                Theme.bgBase.ignoresSafeArea()
            }
            .foregroundStyle(Theme.textPrimary)
    }
}
