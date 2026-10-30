import SwiftUI

/// Glass as a layer, not decoration: floating controls and cards over the
/// ambient wash. Content stays on solid, readable surfaces.
///
/// iOS 26+ renders Liquid Glass. iOS 18–25 falls back to ultra-thin
/// material with a faint stroke. Reduce Transparency uses solid elevated.
struct GlassBackgroundModifier: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.card

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Theme.Radius.rect(cornerRadius).fill(Theme.bgElevated)
                } else if #available(iOS 26, *) {
                    Theme.Radius.rect(cornerRadius)
                        .fill(.clear)
                        .glassEffect(.regular, in: Theme.Radius.rect(cornerRadius))
                } else {
                    Theme.Radius.rect(cornerRadius)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Theme.Radius.rect(cornerRadius)
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        )
                }
            }
            .clipShape(Theme.Radius.rect(cornerRadius))
    }
}

extension View {
    func glassBackground(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        modifier(GlassBackgroundModifier(cornerRadius: cornerRadius))
    }
}

/// A floating card with roomy padding on the glass layer.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = Theme.Space.cardRoomy
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassBackground()
    }
}

/// Solid content card for readable surfaces.
struct SolidCard<Content: View>: View {
    var padding: CGFloat = Theme.Space.cardRoomy
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgElevated)
            .clipShape(Theme.Radius.rect(Theme.Radius.card))
    }
}

#Preview("Glass + solid") {
    VStack(spacing: Theme.Space.s16) {
        GlassCard {
            Text("Glass floats over the wash.")
                .font(Theme.Font.headline)
        }
        SolidCard {
            Text("Content sits on solid.")
                .font(Theme.Font.headline)
        }
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Glass + solid (light, AX)") {
    VStack(spacing: Theme.Space.s16) {
        GlassCard {
            Text("Glass floats over the wash.")
                .font(Theme.Font.headline)
        }
        SolidCard {
            Text("Content sits on solid.")
                .font(Theme.Font.headline)
        }
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility5)
}
