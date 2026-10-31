import SwiftUI

/// Cards as solid white surfaces on cream: one soft shadow plus a hairline.
/// The `GlassCard` name stays so call sites don't churn; the frosted glass
/// and gradient are gone.
struct GlassBackgroundModifier: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .background {
                Theme.Radius.rect(cornerRadius).fill(Theme.bgCard)
            }
            .clipShape(Theme.Radius.rect(cornerRadius))
            .shadow(color: Theme.Shadow.color, radius: Theme.Shadow.radius, y: Theme.Shadow.y)
            .overlay(
                Theme.Radius.rect(cornerRadius)
                    .stroke(Theme.Shadow.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func glassBackground(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        modifier(GlassBackgroundModifier(cornerRadius: cornerRadius))
    }
}

/// A floating card with roomy padding.
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
            .background(Theme.bgCard)
            .clipShape(Theme.Radius.rect(Theme.Radius.card))
            .shadow(color: Theme.Shadow.color, radius: Theme.Shadow.radius, y: Theme.Shadow.y)
            .overlay(
                Theme.Radius.rect(Theme.Radius.card)
                    .stroke(Theme.Shadow.hairline, lineWidth: 1)
            )
    }
}

#Preview("Glass + solid") {
    VStack(spacing: Theme.Space.s16) {
        GlassCard {
            Text("Cards float on cream.")
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

#Preview("Glass + solid (night, AX)") {
    VStack(spacing: Theme.Space.s16) {
        GlassCard {
            Text("Cards float on cream.")
                .font(Theme.Font.headline)
        }
        SolidCard {
            Text("Content sits on solid.")
                .font(Theme.Font.headline)
        }
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
