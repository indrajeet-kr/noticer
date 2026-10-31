import SwiftUI

/// One team win: time plus the need, in her words. Self-notices are
/// highlighted; cued moments read "With a little nudge".
struct WinRow: View {
    var moment: SessionMoment
    /// One wording per need: callers pass the model's current words.
    var wordsForMoment: (SessionMoment) -> String = { $0.text }

    var body: some View {
        HStack(spacing: Theme.Space.s12) {
            Text(Self.time(moment.at))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 64, alignment: .leading)
            Text(wordsForMoment(moment))
                .font(Theme.Font.body)
            Spacer()
            if moment.sharedWithPartner == true {
                Text("You finished it")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.gotIt)
            } else if moment.kind == .selfNotice {
                Text("On his own")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.gotIt)
            } else {
                Text("With a little nudge")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, Theme.Space.s12)
        .accessibilityElement(children: .combine)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static func time(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

/// Clean summary card for sharing: rendered to an image via ImageRenderer.
struct ShareSummaryCard: View {
    var headline: String
    var wins: [SessionMoment]
    /// One wording per need: callers pass the model's current words.
    var wordsForMoment: (SessionMoment) -> String = { $0.text }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            Text("Team Wins Tonight")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(headline)
                .font(Theme.Font.title)
            ForEach(wins.prefix(6)) { win in
                HStack {
                    Text(wordsForMoment(win))
                        .font(Theme.Font.body)
                    Spacer()
                    Text(win.sharedWithPartner == true ? "You finished it" : (win.kind == .selfNotice ? "On his own" : "With a little nudge"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text("Noticer · a quiet teammate")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.s32)
        .frame(width: 340, alignment: .leading)
        .background(Theme.bgElevated)
        .clipShape(Theme.Radius.rect(Theme.Radius.hero))
    }
}

#Preview("Wins") {
    VStack(spacing: 0) {
        WinRow(moment: SessionMoment(
            at: Date().addingTimeInterval(-3600),
            needID: "take-baby",
            kind: .selfNotice,
            text: "Took the baby so you could eat"
        ))
        Divider().background(Theme.textPrimary.opacity(0.08))
        WinRow(moment: SessionMoment(
            at: Date().addingTimeInterval(-1800),
            needID: "refill-water",
            kind: .cued,
            text: "Refilled your water"
        ))
    }
    .padding(.horizontal, Theme.Space.card)
    .glassBackground()
    .screenMargins()
    .ambientScreen()
}

#Preview("Share card (light, AX)") {
    ShareSummaryCard(
        headline: "He caught 4 things on his own tonight.",
        wins: [
            SessionMoment(at: Date(), needID: "take-baby", kind: .selfNotice, text: "Took the baby so you could eat"),
            SessionMoment(at: Date(), needID: "refill-water", kind: .cued, text: "Refilled your water"),
        ]
    )
    .ambientScreen()
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility5)
}
