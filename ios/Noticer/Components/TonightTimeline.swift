import NoticerCore
import SwiftUI

/// Tonight's timeline: tonight's cues and catches, latest on top. A filled
/// sage dot means he caught it himself, terracotta means a nudge helped, and
/// a hollow dot marks now while listening.
struct TonightTimeline: View {
    var moments: [SessionMoment]
    var isRunning: Bool
    /// One wording per need: callers pass the model's current words so a
    /// reword doesn't leave old and new phrasing side by side.
    var wordsForMoment: (SessionMoment) -> String = { $0.text }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text("Tonight")
                .font(Theme.Font.headline)
                .accessibilityAddTraits(.isHeader)
            if isRunning || !moments.isEmpty {
                VStack(spacing: 0) {
                    if isRunning {
                        timelineRow(dot: .now, words: DemoStripMapper.listening, time: Date(), detail: "Now")
                        Divider().background(Theme.textPrimary.opacity(0.08))
                    }
                    ForEach(sortedMoments) { moment in
                        timelineRow(
                            dot: moment.kind == .selfNotice ? .caught : .nudged,
                            words: wordsForMoment(moment),
                            time: moment.at,
                            detail: moment.sharedWithPartner == true ? "You finished it" : (moment.kind == .selfNotice ? "You got it" : "With a nudge")
                        )
                        if moment.id != sortedMoments.last?.id {
                            Divider().background(Theme.textPrimary.opacity(0.08))
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.card)
                .padding(.vertical, Theme.Space.s8)
                .glassBackground()
            } else {
                Text("Nothing yet tonight.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var sortedMoments: [SessionMoment] {
        moments.sorted { $0.at > $1.at }
    }

    private func timelineRow(dot: TimelineDot, words: String, time: Date, detail: String) -> some View {
        HStack(spacing: Theme.Space.s12) {
            dot.view
            VStack(alignment: .leading, spacing: 2) {
                Text(words)
                    .font(Theme.Font.body)
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text(time, style: .time)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, Theme.Space.s12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(words), \(Self.timeWords(time)), \(detail.lowercased())")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static func timeWords(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

private enum TimelineDot {
    case caught
    case nudged
    case now

    @ViewBuilder
    var view: some View {
        switch self {
        case .caught:
            Circle().fill(Theme.sage).frame(width: 12, height: 12)
        case .nudged:
            Circle().fill(Theme.terracotta).frame(width: 12, height: 12)
        case .now:
            Circle().stroke(Theme.textSecondary, lineWidth: 2).frame(width: 12, height: 12)
        }
    }
}

#Preview("Timeline") {
    TonightTimeline(
        moments: [
            SessionMoment(at: Date().addingTimeInterval(-3600), needID: "take-baby", kind: .selfNotice, text: "eating one-handed, take the baby"),
            SessionMoment(at: Date().addingTimeInterval(-1800), needID: "refill-water", kind: .cued, text: "nursing, no water"),
        ],
        isRunning: true
    )
    .screenMargins()
    .ambientScreen()
}

#Preview("Timeline empty (night, AX)") {
    TonightTimeline(moments: [], isRunning: false)
        .screenMargins()
        .ambientScreen()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}
