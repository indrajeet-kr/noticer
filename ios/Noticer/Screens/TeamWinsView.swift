import SwiftUI

/// Team Wins Tonight, for mom: a warm serif headline, win circles, tonight's
/// wins in her words, a sentence summary, and one soft share action. No
/// points, streaks, or badges — the circles and sentences are the payoff.
struct TeamWinsView: View {
    @Bindable var model: PhoneSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var shareImage: Image?

    private var wins: [SessionMoment] {
        model.tonightMoments.sorted { $0.at < $1.at }
    }

    private var selfNoticeCount: Int {
        wins.filter(\.kind.isUnprompted).count
    }

    private var cueCount: Int {
        wins.filter { !$0.kind.isUnprompted }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                Text(dayLine)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.Space.s16)
                Text("Team Wins Tonight")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)

                VStack(spacing: Theme.Space.s12) {
                    HStack(spacing: Theme.Space.s12) {
                        Image(systemName: "heart")
                            .font(.system(size: 32))
                            .fontWeight(.light)
                            .foregroundStyle(Theme.terracotta)
                        Image(systemName: "hands.clap")
                            .font(.system(size: 32))
                            .fontWeight(.light)
                            .foregroundStyle(Theme.sage)
                    }
                    .accessibilityHidden(true)
                    Text(headline)
                        .font(Theme.Font.display)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)

                if !wins.isEmpty {
                    winCircles
                    GlassCard(padding: Theme.Space.card) {
                        VStack(spacing: 0) {
                            ForEach(wins) { win in
                                WinRow(moment: win, wordsForMoment: { model.momentWords(for: $0) })
                                if win.id != wins.last?.id {
                                    Divider().background(Theme.textPrimary.opacity(0.08))
                                }
                            }
                        }
                    }
                }

                Text(summary)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, Theme.Space.s8)

                if let shareImage {
                    ShareLink(item: shareImage, preview: SharePreview("Team Wins Tonight", image: shareImage)) {
                        Text("Share with her")
                            .font(Theme.Font.headline)
                            .foregroundStyle(Theme.onSage)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 52)
                            .background(Theme.sage, in: Theme.Radius.rect(Theme.Radius.button))
                    }
                    .disabled(wins.isEmpty)
                } else {
                    Button("Share with her") {}
                        .buttonStyle(.primaryCapsule)
                        .disabled(true)
                }

                Button("Done") {
                    dismiss()
                }
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
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
        WinsSummary.headline(selfNotices: selfNoticeCount, hasWins: !wins.isEmpty)
    }

    private var summary: String {
        let prior = CueHistoryStore.mostRecentPriorDay(before: model.tonightSessionDay, in: model.cueHistory)?.count
        return WinsSummary.sentence(selfNotices: selfNoticeCount, cues: cueCount, priorCues: prior)
    }

    private var winCircles: some View {
        HStack(spacing: Theme.Space.s8) {
            ForEach(wins) { win in
                Circle()
                    .fill(win.kind.isUnprompted ? Theme.sage : Theme.terracotta)
                    .frame(width: 20, height: 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(selfNoticeCount) caught on his own, \(cueCount) with a nudge")
    }

    private var dayLine: String {
        DayPart.line(for: model.latestSessionStart)
    }

    @MainActor
    private func renderShareCard() {
        guard !wins.isEmpty else {
            shareImage = nil
            return
        }
        let renderer = ImageRenderer(content: ShareSummaryCard(
            headline: headline,
            wins: wins,
            wordsForMoment: { model.momentWords(for: $0) }
        ))
        renderer.scale = 3
        if let uiImage = renderer.uiImage {
            shareImage = Image(uiImage: uiImage)
        }
    }
}

#Preview("Wins") {
    TeamWinsView(model: PhoneSessionModel())
}

#Preview("Wins with samples") {
    WinsSamplePreview()
}

#Preview("Wins (night, AX)") {
    TeamWinsView(model: PhoneSessionModel())
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}

#if DEBUG
/// Preview-only sample wins so screenshots show the payoff state.
private struct WinsSamplePreview: View {
    @State private var model = PhoneSessionModel()

    var body: some View {
        TeamWinsView(model: model)
            .onAppear {
                model.moments = [
                    SessionMoment(at: Date().addingTimeInterval(-3600), needID: "take-baby", kind: .selfNotice, text: "Took the baby so you could eat"),
                    SessionMoment(at: Date().addingTimeInterval(-2400), needID: "refill-water", kind: .selfNotice, text: "Refilled your water"),
                    SessionMoment(at: Date().addingTimeInterval(-1200), needID: "take-baby", kind: .cued, text: "Took the baby so you could eat"),
                ]
            }
    }
}
#endif
