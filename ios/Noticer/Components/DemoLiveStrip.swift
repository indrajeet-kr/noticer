import NoticerCore
import SwiftUI

/// Demo mode's live strip: each pipeline step in big plain words for screen
/// recordings. Rows run oldest at top, newest at the bottom.
struct DemoLiveStrip: View {
    var items: [DemoStripItem]
    var chip: String?
    var relative: (DemoStripItem) -> String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var rowSize: CGFloat = 20

    var body: some View {
        GlassCard(padding: Theme.Space.cardRoomy) {
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                header
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    if items.isEmpty {
                        row(DemoStripItem(id: -1, at: Date(), text: DemoStripMapper.listening, style: .neutral), newest: true)
                    } else {
                        ForEach(items) { item in
                            row(item, newest: item.id == items.last?.id)
                        }
                    }
                }
                .animation(reduceMotion ? nil : Theme.gentle, value: items.map(\.id))
            }
        }
        .cardShadow()
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Live steps")
                .font(Theme.Font.hero)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let chip {
                Text(chip)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.Space.s12)
                    .padding(.vertical, Theme.Space.s4)
                    .background(Theme.bgSubtle, in: Capsule())
                    .accessibilityLabel("Last reply \(chip)")
            }
        }
    }

    private func row(_ item: DemoStripItem, newest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s12) {
            Circle()
                .fill(newest ? accent(for: item.style) : Color.clear)
                .frame(width: 8, height: 8)
            Text(relative(item))
                .font(Theme.Font.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 64, alignment: .leading)
            rowText(item)
        }
        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func rowText(_ item: DemoStripItem) -> some View {
        if item.style == .headStart, let endsAt = item.countdownEndsAt {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let remaining = max(0, endsAt.timeIntervalSince(context.date))
                Text("Head start: \(Int(ceil(remaining)))s for you")
                    .font(.system(size: rowSize, weight: .semibold))
                    .foregroundStyle(Theme.terracottaText)
            }
        } else if item.style == .whisper {
            Text(item.text)
                .font(.system(size: rowSize, design: .serif).italic())
                .foregroundStyle(Theme.terracottaText)
        } else {
            Text(item.text)
                .font(.system(size: rowSize, weight: .semibold))
                .foregroundStyle(textColor(for: item.style))
        }
    }

    private func textColor(for style: DemoStripItem.Style) -> Color {
        switch style {
        case .noticed, .outcomeWin: Theme.sageStrong
        case .headStart, .whisper: Theme.terracottaText
        case .outcomeOther, .neutral, .chip: Theme.textSecondary
        }
    }

    private func accent(for style: DemoStripItem.Style) -> Color {
        switch style {
        case .noticed, .outcomeWin: Theme.sage
        case .headStart, .whisper: Theme.terracotta
        case .outcomeOther, .neutral, .chip: Theme.textSecondary
        }
    }
}

#Preview("Demo strip (6-event sequence)") {
    let start = Date()
    DemoLiveStrip(
        items: [
            DemoStripItem(id: 0, at: start, text: DemoStripMapper.firstFrame, style: .neutral),
            DemoStripItem(id: 1, at: start.addingTimeInterval(4), text: "Noticed: Her water is empty", style: .noticed),
            DemoStripItem(
                id: 2,
                at: start.addingTimeInterval(4),
                text: "Head start: 10s for you",
                style: .headStart,
                countdownEndsAt: Date().addingTimeInterval(7)
            ),
            DemoStripItem(id: 3, at: start.addingTimeInterval(14), text: "Whispered: “Her water's empty.”", style: .whisper),
            DemoStripItem(id: 4, at: start.addingTimeInterval(22), text: "You got it", style: .outcomeWin),
            DemoStripItem(id: 5, at: start.addingTimeInterval(30), text: "Noticed: Toys on the floor", style: .noticed),
        ],
        chip: "Muse Spark · 2.6s",
        relative: { item in
            let delta = max(0, item.at.timeIntervalSince(start))
            return String(format: "+%.1fs", delta)
        }
    )
    .padding(.horizontal, Theme.Space.screenMargin)
    .ambientScreen()
}

#Preview("Demo strip (empty)") {
    DemoLiveStrip(items: [], chip: nil, relative: { _ in "+0.0s" })
        .padding(.horizontal, Theme.Space.screenMargin)
        .ambientScreen()
}

#Preview("Demo strip (largest type)") {
    let start = Date()
    DemoLiveStrip(
        items: [
            DemoStripItem(id: 0, at: start, text: "Noticed: Her water is empty", style: .noticed),
            DemoStripItem(id: 1, at: start.addingTimeInterval(8), text: "You finished it. Nice teamwork.", style: .outcomeWin),
        ],
        chip: "Muse Spark · 2.6s",
        relative: { _ in "+8.0s" }
    )
    .padding(.horizontal, Theme.Space.screenMargin)
    .ambientScreen()
    .dynamicTypeSize(.accessibility5)
}

#Preview("Demo strip (Night)") {
    let start = Date()
    DemoLiveStrip(
        items: [
            DemoStripItem(id: 0, at: start, text: "Noticed: Her water is empty", style: .noticed),
            DemoStripItem(id: 1, at: start.addingTimeInterval(8), text: "You finished it. Nice teamwork.", style: .outcomeWin),
        ],
        chip: "Muse Spark · 2.6s",
        relative: { _ in "+8.0s" }
    )
    .padding(.horizontal, Theme.Space.screenMargin)
    .ambientScreen()
    .preferredColorScheme(.dark)
}
