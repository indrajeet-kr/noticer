import SwiftUI

/// Team Wins Tonight, for mom: a warm hero line, tonight's wins with times,
/// and a shareable summary card. Self-notices are highlighted; cued moments
/// read "With a little nudge".
struct TeamWinsView: View {
    @Bindable var model: PhoneSessionModel
    @State private var shareImage: Image?

    private var wins: [SessionMoment] {
        model.moments.sorted { $0.at < $1.at }
    }

    private var selfNoticeCount: Int {
        wins.filter { $0.kind == .selfNotice }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                Text(dayLine)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.Space.s16)
                Text("Team Wins Tonight")
                    .font(Theme.Font.statusWord)
                    .accessibilityAddTraits(.isHeader)

                GlassCard(padding: Theme.Space.s24) {
                    VStack(spacing: Theme.Space.s8) {
                        Text("🤝")
                            .font(.system(size: 40))
                        Text(headline)
                            .font(Theme.Font.title)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }

                if !wins.isEmpty {
                    GlassCard(padding: Theme.Space.card) {
                        VStack(spacing: 0) {
                            ForEach(wins) { win in
                                WinRow(moment: win)
                                if win.id != wins.last?.id {
                                    Divider().background(Theme.textPrimary.opacity(0.08))
                                }
                            }
                        }
                    }
                }

                Text("Thanks for writing the list. It's working.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, Theme.Space.s8)

                if let shareImage {
                    ShareLink(item: shareImage, preview: SharePreview("Team Wins Tonight", image: shareImage)) {
                        Text("Share")
                            .font(Theme.Font.headline)
                            .foregroundStyle(Theme.onAccentFill)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.s16)
                            .background(Theme.accentFill)
                            .clipShape(Capsule())
                    }
                    .disabled(wins.isEmpty)
                } else {
                    Button("Share") {}
                        .buttonStyle(.primaryCapsule)
                        .disabled(true)
                }
            }
            .screenMargins()
            .padding(.bottom, Theme.Space.s32)
        }
        .ambientScreen()
        .onAppear {
            renderShareCard()
        }
        .onChange(of: model.moments) { _, _ in
            renderShareCard()
        }
    }

    private var headline: String {
        switch selfNoticeCount {
        case 0:
            return wins.isEmpty
                ? "Tonight is young — wins will land here."
                : "Every nudge is teamwork too."
        case 1:
            return "He caught 1 thing on his own tonight."
        default:
            return "He caught \(selfNoticeCount) things on his own tonight."
        }
    }

    private var dayLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return "\(formatter.string(from: Date())) evening"
    }

    @MainActor
    private func renderShareCard() {
        guard !wins.isEmpty else {
            shareImage = nil
            return
        }
        let renderer = ImageRenderer(content: ShareSummaryCard(headline: headline, wins: wins))
        renderer.scale = 3
        if let uiImage = renderer.uiImage {
            shareImage = Image(uiImage: uiImage)
        }
    }
}

#Preview("Wins") {
    TeamWinsView(model: PhoneSessionModel())
}

#Preview("Wins (light, AX)") {
    TeamWinsView(model: PhoneSessionModel())
        .preferredColorScheme(.light)
        .dynamicTypeSize(.accessibility5)
}
