import SwiftUI

/// Help, from the tab menu: how the three tabs work, in words.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text("Help")
                        .font(Theme.Font.display)
                    Text("A quiet teammate for tonight.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, Theme.Space.s16)
                .accessibilityElement(children: .combine)

                ForEach(HelpView.sections) { section in
                    GlassCard {
                        VStack(alignment: .leading, spacing: Theme.Space.s8) {
                            HStack(spacing: Theme.Space.s8) {
                                Image(systemName: section.symbol)
                                    .fontWeight(.light)
                                    .foregroundStyle(Theme.sage)
                                Text(section.title)
                                    .font(Theme.Font.headline)
                            }
                            Text(section.body)
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .screenMargins()
            .padding(.bottom, Theme.Space.s32)
        }
        .ambientScreen()
    }

    private struct Section: Identifiable {
        var id: String { title }
        var symbol: String
        var title: String
        var body: String
    }

    private static let sections: [Section] = [
        Section(
            symbol: "circle.circle",
            title: "Tonight",
            body: "Tap the circle to start noticing. You get a head start to catch things yourself; a whisper comes only if you need it. Tap Stop when the evening winds down."
        ),
        Section(
            symbol: "list.bullet",
            title: "Her list",
            body: "Her needs in her own words. Tap a card to pause it for tonight, change it in words, or remove it. Add a need any time by just saying what would help."
        ),
        Section(
            symbol: "leaf",
            title: "Learning",
            body: "When you notice on your own, we whisper less. After a few catches in a row, that need goes quiet. The rings show how each need is fading."
        ),
        Section(
            symbol: "lock.shield",
            title: "Private by design",
            body: "Frames stay in memory for a moment and are never saved. The light on the glasses shows when they're looking."
        ),
    ]
}

#Preview("Help") {
    NavigationStack {
        HelpView()
    }
}

#Preview("Help (night, AX)") {
    NavigationStack {
        HelpView()
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility5)
}
